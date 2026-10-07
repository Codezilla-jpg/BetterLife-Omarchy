#!/usr/bin/python3
"""Collect Grok, Claude, and Codex usage as JSON for the Omarchy bar."""

from __future__ import annotations

import concurrent.futures
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AUTH_HINTS = {
    "grok": "Run `grok login` to restore usage.",
    "claude": "Run `claude auth login` to restore authoritative usage.",
    "codex": "Run `codex login` to authenticate.",
}
NAMES = {
    "grok": "Grok",
    "claude": "Claude Code",
    "codex": "Codex",
}
WAITING_STATUS = {
    "grok": "Waiting for auth",
    "claude": "Waiting for auth",
    "codex": "Waiting for auth",
}
PRODUCT_TITLES = {
    "GrokBuild": "Build",
    "GrokImagine": "Imagine",
    "GrokChat": "Chat",
    "GrokVoice": "Voice",
    "GrokAPI": "API",
    "GrokPlugins": "Plugins",
}
GROK_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
GROK_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
GROK_SETTINGS_URL = "https://cli-chat-proxy.grok.com/v1/settings"
TOKEN_RE = re.compile(r'"totalTokens"\s*:\s*(\d+)')
TAIL_BYTES = 512_000
COLLECTOR_TIMEOUT = 8
REFRESH_SKEW_SECONDS = 120


def grok_home() -> Path:
    return Path(os.environ.get("GROK_HOME") or (Path.home() / ".grok")).expanduser()


def enrich_path() -> None:
    home = str(Path.home())
    extras = [
        f"{home}/.local/bin",
        f"{home}/.local/share/mise/shims",
        f"{home}/.npm-global/bin",
        "/usr/share/omarchy/bin",
    ]
    path = os.environ.get("PATH", "")
    os.environ["PATH"] = os.pathsep.join(part for part in extras + [path] if part)


def empty_days(today: dt.date) -> list[dict]:
    days = []
    for offset in range(6, -1, -1):
        day = today - dt.timedelta(days=offset)
        days.append(
            {
                "date": day.isoformat(),
                "label": day.strftime("%a"),
                "tokens": 0,
                "today": day == today,
            }
        )
    return days


def agent_record(
    *,
    agent_id: str,
    authenticated: bool,
    auth_hint: str = "",
    plan: str = "",
    email: str = "",
    title: str = "",
    today_tokens: int = 0,
    week_tokens: int = 0,
    session_count: int = 0,
    today_sessions: int = 0,
    days: list[dict] | None = None,
    limits: list[dict] | None = None,
    usage_status_text: str = "",
) -> dict:
    today = dt.date.today()
    name = NAMES[agent_id]
    return {
        "id": agent_id,
        "name": name,
        "title": title or name,
        "authenticated": authenticated,
        "authHint": auth_hint or AUTH_HINTS[agent_id],
        "email": email,
        "plan": plan,
        "todayTokens": today_tokens,
        "weekTokens": week_tokens,
        "sessionCount": session_count,
        "todaySessions": today_sessions,
        "days": days if days is not None else empty_days(today),
        "limits": limits or [],
        "usageStatusText": usage_status_text,
    }


def first_account(raw: object) -> dict | None:
    if isinstance(raw, dict):
        if raw.get("email") or raw.get("refresh_token") or raw.get("key"):
            if "email" in raw or "refresh_token" in raw or "principal_type" in raw:
                return raw
        for value in raw.values():
            found = first_account(value)
            if found:
                return found
    elif isinstance(raw, list):
        for value in raw:
            found = first_account(value)
            if found:
                return found
    return None


def session_date(session_dir: Path) -> dt.date:
    summary = session_dir / "summary.json"
    if summary.is_file():
        try:
            data = json.loads(summary.read_text(encoding="utf-8"))
            raw = data.get("updated_at") or data.get("last_active_at") or data.get("created_at")
            if raw:
                return dt.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).date()
        except Exception:
            pass
    try:
        return dt.date.fromtimestamp(session_dir.stat().st_mtime)
    except Exception:
        return dt.date.today()


def file_tokens(path: Path) -> int:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
                handle.readline()
            text = handle.read().decode("utf-8", "ignore")
        found = TOKEN_RE.findall(text)
        if found:
            return max(int(value) for value in found)
    except Exception:
        return 0
    return 0


def session_tokens(session_dir: Path) -> int:
    best = 0
    for name in ("updates.jsonl", "events.jsonl", "chat_history.jsonl"):
        best = max(best, file_tokens(session_dir / name))
    return best


def collect_grok_sessions(home: Path) -> tuple[list[dict], int, int, int, int]:
    today = dt.date.today()
    week_start = today - dt.timedelta(days=6)
    by_day = {row["date"]: 0 for row in empty_days(today)}
    session_count = 0
    today_sessions = 0
    root = home / "sessions"
    if root.is_dir():
        for summary in root.rglob("summary.json"):
            session_dir = summary.parent
            day = session_date(session_dir)
            if day < week_start:
                continue
            tokens = session_tokens(session_dir)
            key = day.isoformat()
            if key in by_day:
                by_day[key] += tokens
                session_count += 1
                if day == today:
                    today_sessions += 1
    days = empty_days(today)
    for row in days:
        row["tokens"] = by_day.get(row["date"], 0)
    week_tokens = sum(row["tokens"] for row in days)
    today_tokens = next((row["tokens"] for row in days if row["today"]), 0)
    return days, today_tokens, week_tokens, session_count, today_sessions


def parse_expires_at(raw: object) -> dt.datetime | None:
    text = str(raw or "").strip()
    if not text:
        return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except Exception:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def token_needs_refresh(account: dict, skew_seconds: int = REFRESH_SKEW_SECONDS) -> bool:
    expires = parse_expires_at(account.get("expires_at"))
    if expires is None:
        return False
    now = dt.datetime.now(dt.timezone.utc)
    return expires <= now + dt.timedelta(seconds=skew_seconds)


def grok_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": "Bearer " + token,
        "X-XAI-Token-Auth": "xai-grok-cli",
        "Accept": "application/json",
        "User-Agent": "grok-shell/1.0.13",
        "x-grok-client-identifier": "grok-shell",
        "x-grok-client-version": "1.0.13",
    }


def http_json(url: str, headers: dict[str, str], data: bytes | None = None, timeout: int = 10) -> tuple[int, dict | None, str]:
    method = "POST" if data is not None else "GET"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(body) if body else None
            except Exception:
                parsed = None
            return response.status, parsed if isinstance(parsed, dict) else None, body
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body) if body else None
        except Exception:
            parsed = None
        return error.code, parsed if isinstance(parsed, dict) else None, body
    except Exception as exc:
        return 0, None, str(exc)


def lock_auth(lock_path: Path):
    lock_path.touch(exist_ok=True)
    handle = lock_path.open("a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle


def write_auth_file(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def refresh_grok_token(home: Path, account_key: str, account: dict) -> dict:
    refresh_token = str(account.get("refresh_token") or "")
    if not refresh_token:
        return account
    issuer = str(account.get("oidc_issuer") or "https://auth.x.ai").rstrip("/")
    client_id = str(account.get("oidc_client_id") or GROK_CLIENT_ID)
    payload = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": client_id,
        }
    ).encode("utf-8")
    status, body, _raw = http_json(
        issuer + "/oauth2/token",
        {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        data=payload,
        timeout=12,
    )
    if status != 200 or not body:
        return account
    access = str(body.get("access_token") or "")
    if not access:
        return account
    updated = dict(account)
    updated["key"] = access
    if body.get("refresh_token"):
        updated["refresh_token"] = str(body["refresh_token"])
    expires_in = body.get("expires_in")
    try:
        seconds = int(expires_in)
    except Exception:
        seconds = 0
    if seconds > 0:
        updated["expires_at"] = (
            dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)
        ).isoformat().replace("+00:00", "Z")
    path = home / "auth.json"
    lock = lock_auth(home / "auth.json.lock")
    try:
        try:
            on_disk = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            on_disk = {}
        if not isinstance(on_disk, dict):
            on_disk = {}
        current = on_disk.get(account_key)
        # Another process already rotated the grant; keep their copy.
        if isinstance(current, dict) and current.get("refresh_token") not in ("", refresh_token, None):
            if current.get("key"):
                return current
        on_disk[account_key] = updated
        write_auth_file(path, on_disk)
        return updated
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def load_grok_account(home: Path) -> tuple[str, dict] | None:
    path = home / "auth.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    for key, value in data.items():
        if isinstance(value, dict) and (value.get("key") or value.get("refresh_token")):
            return str(key), value
    account = first_account(data)
    if not account:
        return None
    return "", account


def grok_limit_percent(value: object, percent_scale: bool) -> float | None:
    try:
        percent = float(value)
    except Exception:
        return None
    if percent < 0:
        return None
    # Grok reports 39.0 / 1.0 as percents. A payload with any value >= 1 is
    # percent-scaled, so 1.0 is 1%, not 100%.
    if percent_scale:
        return min(1.0, percent / 100.0)
    return min(1.0, percent)


def grok_percent_scale(config: dict) -> bool:
    values = [config.get("creditUsagePercent")]
    products = config.get("productUsage")
    if isinstance(products, list):
        for entry in products:
            if isinstance(entry, dict):
                values.append(entry.get("usagePercent"))
    for value in values:
        try:
            if float(value) >= 1:
                return True
        except Exception:
            continue
    return False


def period_reset(config: dict) -> str:
    period = config.get("currentPeriod")
    if isinstance(period, dict) and period.get("end"):
        return str(period["end"])
    return str(config.get("billingPeriodEnd") or "")


def period_title(config: dict) -> str:
    period = config.get("currentPeriod")
    kind = str(period.get("type") or "") if isinstance(period, dict) else ""
    text = kind.lower()
    if "week" in text:
        return "Weekly"
    if "month" in text:
        return "Monthly"
    reset = period_reset(config)
    if reset:
        try:
            end = dt.datetime.fromisoformat(reset.replace("Z", "+00:00"))
            start = None
            if isinstance(period, dict) and period.get("start"):
                start = dt.datetime.fromisoformat(str(period["start"]).replace("Z", "+00:00"))
            if start is not None:
                span = (end - start).total_seconds()
                if span <= 8 * 24 * 3600:
                    return "Weekly"
                if span >= 20 * 24 * 3600:
                    return "Monthly"
        except Exception:
            pass
    return "Weekly"


def grok_limits_from_billing(payload: dict) -> list[dict]:
    config = payload.get("config")
    if not isinstance(config, dict):
        return []
    limits: list[dict] = []
    reset = period_reset(config)
    title = period_title(config)
    percent_scale = grok_percent_scale(config)
    used = grok_limit_percent(config.get("creditUsagePercent"), percent_scale)
    if used is None:
        cap = ((config.get("onDemandCap") or {}) if isinstance(config.get("onDemandCap"), dict) else {}).get("val")
        spent = ((config.get("onDemandUsed") or {}) if isinstance(config.get("onDemandUsed"), dict) else {}).get("val")
        try:
            cap_n = float(cap or 0)
            spent_n = float(spent or 0)
            if cap_n > 0:
                used = min(1.0, max(0.0, spent_n / cap_n))
        except Exception:
            used = None
    if used is not None:
        limits.append(
            {
                "label": title,
                "title": title,
                "percent": used,
                "resetsAt": reset,
            }
        )
    products = config.get("productUsage")
    if isinstance(products, list):
        for entry in products:
            if not isinstance(entry, dict):
                continue
            product = str(entry.get("product") or "")
            percent = grok_limit_percent(entry.get("usagePercent"), percent_scale)
            if not product or percent is None or percent <= 0:
                continue
            label = PRODUCT_TITLES.get(product, product.replace("Grok", "") or product)
            limits.append(
                {
                    "label": label,
                    "title": label,
                    "percent": percent,
                    "resetsAt": reset,
                }
            )
    return limits


def fetch_grok_plan(token: str) -> str:
    status, body, _raw = http_json(GROK_SETTINGS_URL, grok_headers(token), timeout=6)
    if status != 200 or not body:
        return ""
    return str(body.get("subscription_tier_display") or "").strip()


def fetch_grok_billing(token: str) -> tuple[int, dict | None]:
    status, body, _raw = http_json(GROK_BILLING_URL, grok_headers(token), timeout=10)
    return status, body


def collect_grok() -> dict:
    home = grok_home()
    days, today_tokens, week_tokens, session_count, today_sessions = collect_grok_sessions(home)
    loaded = load_grok_account(home)
    if not loaded:
        return agent_record(
            agent_id="grok",
            authenticated=False,
            usage_status_text=WAITING_STATUS["grok"],
            days=days,
            today_tokens=today_tokens,
            week_tokens=week_tokens,
            session_count=session_count,
            today_sessions=today_sessions,
        )
    account_key, account = loaded
    if token_needs_refresh(account):
        account = refresh_grok_token(home, account_key, account)
    token = str(account.get("key") or "")
    name = " ".join(part for part in (account.get("first_name"), account.get("last_name")) if part)
    email = str(account.get("email") or "")
    plan = str(account.get("principal_type") or account.get("plan") or "")
    if not token:
        return agent_record(
            agent_id="grok",
            authenticated=False,
            email=email,
            plan=plan,
            title=name or email or "Grok",
            usage_status_text="Sign-in expired",
            days=days,
            today_tokens=today_tokens,
            week_tokens=week_tokens,
            session_count=session_count,
            today_sessions=today_sessions,
        )

    status, billing = fetch_grok_billing(token)
    if status in (401, 403) and account.get("refresh_token"):
        account = refresh_grok_token(home, account_key, account)
        token = str(account.get("key") or token)
        status, billing = fetch_grok_billing(token)

    limits: list[dict] = []
    usage_status = ""
    if status == 200 and billing:
        limits = grok_limits_from_billing(billing)
        plan = fetch_grok_plan(token) or plan
    elif status in (401, 403):
        usage_status = "Sign-in expired"
    elif status == 0:
        usage_status = "Couldn't reach Grok usage"
    elif not limits:
        usage_status = ""

    authenticated = bool(limits) or bool(token)
    if usage_status == "Sign-in expired":
        authenticated = bool(limits)
    return agent_record(
        agent_id="grok",
        authenticated=authenticated,
        email=email,
        plan=plan or "SuperGrok",
        title=name or email or "Grok",
        today_tokens=today_tokens,
        week_tokens=week_tokens,
        session_count=session_count,
        today_sessions=today_sessions,
        days=days,
        limits=limits,
        usage_status_text=usage_status,
    )


def days_from_recent(recent: object) -> list[dict]:
    today = dt.date.today()
    by_date = {row["date"]: 0 for row in empty_days(today)}
    if isinstance(recent, list):
        for row in recent:
            if not isinstance(row, dict):
                continue
            date = str(row.get("date") or "")
            if date in by_date:
                try:
                    by_date[date] = int(row.get("messageCount") or 0)
                except Exception:
                    pass
    days = empty_days(today)
    for row in days:
        row["tokens"] = by_date.get(row["date"], 0)
    return days


def number(value: object) -> int:
    try:
        return int(value or 0)
    except Exception:
        return 0


def normalize_limits(raw: object) -> list[dict]:
    out: list[dict] = []
    if not isinstance(raw, list):
        return out
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        try:
            percent = float(entry.get("percent"))
        except Exception:
            continue
        if percent < 0:
            continue
        if percent > 1:
            percent = min(1.0, percent / 100.0)
        label = str(entry.get("label") or "Limit")
        title = str(entry.get("title") or "")
        out.append(
            {
                "label": label,
                "title": title,
                "percent": percent,
                "resetsAt": str(entry.get("resetsAt") or ""),
            }
        )
    return out


def usage_dir() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
    return state / "omarchy" / "agents" / "usage"


def read_usage_record(agent: str) -> dict | None:
    path = usage_dir() / f"{agent}.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def collector_binary(agent: str) -> str | None:
    name = f"omarchy-agent-usage-{agent}"
    found = shutil.which(name)
    if found:
        return found
    omarchy = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy")
    candidate = omarchy / "bin" / name
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def run_omarchy_collector(agent: str) -> dict | None:
    cached = read_usage_record(agent)
    binary = collector_binary(agent)
    if not binary:
        return cached
    try:
        proc = subprocess.run(
            [binary],
            capture_output=True,
            text=True,
            timeout=COLLECTOR_TIMEOUT,
            check=False,
        )
    except Exception:
        return cached
    text = (proc.stdout or "").strip()
    if not text:
        return cached
    try:
        data = json.loads(text)
    except Exception:
        return cached
    return data if isinstance(data, dict) else cached


def from_omarchy(agent: str, raw: dict | None) -> dict:
    if not raw:
        return agent_record(
            agent_id=agent,
            authenticated=False,
            usage_status_text="Collector unavailable",
            auth_hint=AUTH_HINTS[agent],
        )
    days = days_from_recent(raw.get("recentDays"))
    week_tokens = sum(row["tokens"] for row in days)
    today_tokens = number(raw.get("todayTotalTokens"))
    if today_tokens <= 0:
        today_tokens = next((row["tokens"] for row in days if row["today"]), 0)
    status = str(raw.get("usageStatusText") or "")
    auth_hint = str(raw.get("authHelpText") or AUTH_HINTS[agent])
    limits = normalize_limits(raw.get("limits"))
    waiting = status in (
        "Waiting for auth",
        "Sign-in expired",
        "Codex unavailable",
        "Collector unavailable",
    )
    has_usage = bool(limits) or today_tokens > 0 or week_tokens > 0 or number(raw.get("totalSessions")) > 0
    authenticated = bool(limits) or bool(raw.get("tierLabel")) or (not waiting and has_usage)
    if waiting and not limits:
        authenticated = False
        if not status:
            status = WAITING_STATUS[agent]
    if not authenticated and not status:
        status = WAITING_STATUS[agent]
    return agent_record(
        agent_id=agent,
        authenticated=authenticated,
        auth_hint=auth_hint,
        plan=str(raw.get("tierLabel") or ""),
        title=str(raw.get("name") or NAMES[agent]),
        today_tokens=today_tokens,
        week_tokens=week_tokens,
        session_count=number(raw.get("totalSessions")),
        today_sessions=number(raw.get("todaySessions")),
        days=days,
        limits=limits,
        usage_status_text=status,
    )


def main() -> int:
    enrich_path()
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        grok_f = pool.submit(collect_grok)
        claude_f = pool.submit(run_omarchy_collector, "claude")
        codex_f = pool.submit(run_omarchy_collector, "codex")
        grok = grok_f.result()
        claude = from_omarchy("claude", claude_f.result())
        codex = from_omarchy("codex", codex_f.result())
    json.dump({"ok": True, "agents": [grok, claude, codex]}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
