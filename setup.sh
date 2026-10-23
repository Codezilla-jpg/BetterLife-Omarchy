#!/bin/bash

# BetterLife-Omarchy setup: pick the modules you want and, if you like, their
# keybindings. Safe to run again at any time; it starts from what is set now.
#
#   setup.sh                 pick modules, then keybindings
#   setup.sh --keybinds      only the keybinding question
#   setup.sh --modules dock,app-switcher,workspaces,limits [--keybinds-on|--keybinds-off]
#                            no questions, for scripts

set -euo pipefail

ID="codezilla.betterlife"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
SETTINGS_JSON="$HOME/.local/state/omarchy/settings/betterlife.json"
HYPR_DIR="$HOME/.config/hypr"
HYPR_FILE="$HYPR_DIR/betterlife.lua"
HYPR_MAIN="$HYPR_DIR/hyprland.lua"
HYPR_REQUIRE='require("default.hypr.require_optional").module("hypr.betterlife") -- BetterLife-Omarchy'

ALL_MODULES=(dock app-switcher workspaces limits)

fail() {
  echo "betterlife-setup: $*" >&2
  exit 1
}

interactive() {
  [[ -t 0 && -t 1 ]]
}

has() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do [[ $item == "$needle" ]] && return 0; done
  return 1
}

usage() {
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------ current state

# The effective shell config: the user's file, or what the running shell uses
# when there is no file yet.
read_shell_config() {
  if [[ -f $SHELL_JSON ]]; then
    cat "$SHELL_JSON"
  else
    omarchy-shell shell listShellConfig 2>/dev/null || echo '{}'
  fi
}

bar_has_module() {
  read_shell_config | jq -e --arg id "$ID" --arg module "$1" '
    [(.bar.layout // {})[]? | arrays | .[] | objects
      | select(.id == $id and ((.module // "workspaces") == $module))] | length > 0
  ' >/dev/null 2>&1
}

overlay_on() {
  # Anything not switched off in betterlife.json is on, as in Overlays.qml.
  jq -e --arg key "$1" '.modules[$key] != false' "$SETTINGS_JSON" >/dev/null 2>&1
}

current_modules() {
  # First run: offer everything.
  if [[ ! -f $SETTINGS_JSON ]]; then
    printf '%s\n' "${ALL_MODULES[@]}"
    return
  fi
  overlay_on dock && echo dock
  overlay_on appSwitcher && echo app-switcher
  if overlay_on workspaceViewer || bar_has_module workspaces; then echo workspaces; fi
  bar_has_module limits && echo limits
  return 0
}

current_keybinds() {
  [[ ! -f $SETTINGS_JSON ]] && return 0
  grep -qE '^load\("(app-switcher|workspace-viewer)"\)' "$HYPR_FILE" 2>/dev/null
}

# Bindings the user already wrote by hand (e.g. from the old example file).
# Loading ours on top would bind the same keys twice.
own_hypr_files() {
  local file
  for file in "$HYPR_DIR"/*.lua; do
    [[ -f $file && $file != "$HYPR_FILE" ]] && echo "$file"
  done
  return 0
}

hand_written() {
  local file
  while IFS= read -r file; do
    grep -qF "betterlife.$1" "$file" && { echo "$file"; return 0; }
  done < <(own_hypr_files)
  return 0
}

hand_written_blur() {
  local file
  while IFS= read -r file; do
    grep -qF 'betterlife-(dock' "$file" && return 0
  done < <(own_hypr_files)
  return 1
}

# ---------------------------------------------------------------- questions

ask_modules() {
  local selected=()
  local module
  declare -A labels=(
    [dock]="Dock             glass dock of running apps at the screen edge"
    [app-switcher]="App switcher     Super+Tab, most recently used app first"
    [workspaces]="Workspaces       workspace viewer (Super+E) and bar widget with only used workspaces"
    [limits]="Limits           bar widget with Grok/Claude/Codex limits and tokens"
  )
  while IFS= read -r module; do
    [[ -n $module ]] && selected+=("${labels[$module]}")
  done < <(current_modules)

  local options=()
  for module in "${ALL_MODULES[@]}"; do options+=("${labels[$module]}|$module"); done

  local IFS=,
  gum choose --no-limit --label-delimiter='|' \
    --header="Which BetterLife modules do you want? (Space toggles, Enter confirms)" \
    --selected="${selected[*]}" "${options[@]}"
}

ask_keybinds() {
  local keys=()
  has app-switcher "${MODULES[@]}" && keys+=("Super+Tab → app switcher")
  has workspaces "${MODULES[@]}" && keys+=("Super+E → workspace viewer")
  (( ${#keys[@]} )) || return 1

  local yes="Set them up now"
  local no="Later, I'll set them myself"
  local preselect="$yes"
  current_keybinds || preselect="$no"

  local header="Keybindings: ${keys[*]}"
  local answer
  answer=$(gum choose --header="$header" --selected="$preselect" "$yes" "$no") || exit 1
  [[ $answer == "$yes" ]]
}

# -------------------------------------------------------------------- apply

write_settings() {
  local dock=false switcher=false viewer=false
  has dock "${MODULES[@]}" && dock=true
  has app-switcher "${MODULES[@]}" && switcher=true
  has workspaces "${MODULES[@]}" && viewer=true

  mkdir -p "$(dirname "$SETTINGS_JSON")"
  local existing='{}'
  [[ -f $SETTINGS_JSON ]] && existing=$(cat "$SETTINGS_JSON")
  jq -n --argjson base "$existing" \
    --argjson dock "$dock" --argjson switcher "$switcher" --argjson viewer "$viewer" '
      ($base | if type == "object" then . else {} end)
      | .modules = ((.modules // {}) + { dock: $dock, appSwitcher: $switcher, workspaceViewer: $viewer })
    ' >"$SETTINGS_JSON.tmp"
  mv "$SETTINGS_JSON.tmp" "$SETTINGS_JSON"
}

# Puts the bar widgets in or takes them out, and lists the plugin in plugins[]
# while one of the overlay modules (dock, switcher, viewer) is wanted. Our
# workspaces widget takes the place of Omarchy's own and gives it back when it
# is switched off.
write_shell_config() {
  local workspaces=false limits=false overlay=false
  has workspaces "${MODULES[@]}" && workspaces=true
  has limits "${MODULES[@]}" && limits=true
  if has dock "${MODULES[@]}" || has app-switcher "${MODULES[@]}" || has workspaces "${MODULES[@]}"; then
    overlay=true
  fi

  local config
  config=$(read_shell_config)
  mkdir -p "$(dirname "$SHELL_JSON")"
  jq --arg id "$ID" --argjson ws "$workspaces" --argjson lim "$limits" --argjson ov "$overlay" '
    def eid: if type == "object" then .id else . end;
    def ours($m): type == "object" and .id == $id and ((.module // "workspaces") == $m);
    def anywhere(f): [.bar.layout[] | .[] | select(f)] | length > 0;
    def index_of(f): (to_entries | map(select(.value | f)) | first | .key) // null;

    .bar = (.bar // {})
    | .bar.layout = (.bar.layout // {})
    | .bar.layout |= (.left //= [] | .center //= [] | .right //= [])
    | .plugins = (.plugins // [])

    # workspaces
    | if $ws then
        if anywhere(ours("workspaces")) then .
        elif anywhere(eid == "omarchy.workspaces") then
          .bar.layout |= map_values(
            (index_of(eid == "omarchy.workspaces")) as $i
            | if $i == null then . else .[$i] = { id: $id, module: "workspaces" } end)
        else
          .bar.layout.left |= (
            ((index_of(eid == "omarchy.menu")) as $i | if $i == null then 0 else $i + 1 end) as $at
            | .[:$at] + [{ id: $id, module: "workspaces" }] + .[$at:])
        end
      else
        if anywhere(eid == "omarchy.workspaces") then
          .bar.layout |= map_values(map(select(ours("workspaces") | not)))
        else
          .bar.layout |= map_values(map(if ours("workspaces") then { id: "omarchy.workspaces" } else . end))
        end
      end

    # limits
    | if $lim then
        if anywhere(ours("limits")) then .
        else
          .bar.layout.right |= (
            ((index_of(eid == "omarchy.tray")) as $i | if $i == null then 0 else $i + 1 end) as $at
            | .[:$at] + [{ id: $id, module: "limits" }] + .[$at:])
        end
      else
        .bar.layout |= map_values(map(select(ours("limits") | not)))
      end

    # overlays
    | .plugins |= map(select(eid != $id))
    | if $ov then .plugins += [{ id: $id }] else . end
    | if .disabledPlugins then .disabledPlugins |= map(select(. != $id)) else . end
  ' <<<"$config" >"$SHELL_JSON.tmp"
  mv "$SHELL_JSON.tmp" "$SHELL_JSON"

  omarchy-shell shell reloadConfig >/dev/null 2>&1 || true
}

# ~/.config/hypr/betterlife.lua loads the chosen snippets straight from the
# plugin, so a plugin update updates them too, and a removed plugin just loads
# nothing. hyprland.lua pulls it in through require_optional, which stays quiet
# if the file is gone.
write_hypr() {
  local snippets=()
  local skipped=()
  local file

  if has dock "${MODULES[@]}" || has app-switcher "${MODULES[@]}" || has workspaces "${MODULES[@]}"; then
    # Unless the blur rule is already in the user's own config.
    hand_written_blur || snippets+=(blur)
  fi

  if (( KEYBINDS )); then
    if has app-switcher "${MODULES[@]}"; then
      if file=$(hand_written app-switcher) && [[ -n $file ]]; then skipped+=("app switcher (already in ${file/#$HOME/\~})")
      else snippets+=(app-switcher); fi
    fi
    if has workspaces "${MODULES[@]}"; then
      if file=$(hand_written workspace-viewer) && [[ -n $file ]]; then skipped+=("workspace viewer (already in ${file/#$HOME/\~})")
      else snippets+=(workspace-viewer); fi
    fi
  fi

  [[ -d $HYPR_DIR ]] || return 0

  if (( ${#snippets[@]} )); then
    {
      echo "-- Written by BetterLife-Omarchy setup; run it again to change this file:"
      echo "--   $PLUGIN_DIR/setup.sh"
      echo
      echo "local dir = os.getenv(\"HOME\") .. \"/.config/omarchy/plugins/$ID/hypr/\""
      echo
      echo "local function load(name)"
      echo "  local path = dir .. name .. \".lua\""
      echo "  local file = io.open(path, \"r\")"
      echo "  if not file then return end"
      echo "  file:close()"
      echo "  dofile(path)"
      echo "end"
      echo
      for file in "${snippets[@]}"; do echo "load(\"$file\")"; done
    } >"$HYPR_FILE"
    if [[ -f $HYPR_MAIN ]] && ! grep -qF "$HYPR_REQUIRE" "$HYPR_MAIN"; then
      printf '\n%s\n' "$HYPR_REQUIRE" >>"$HYPR_MAIN"
    fi
  else
    # Drop the require first, so Hyprland never looks for a file that is gone.
    if [[ -f $HYPR_MAIN ]] && grep -qF "$HYPR_REQUIRE" "$HYPR_MAIN"; then
      grep -vxF "$HYPR_REQUIRE" "$HYPR_MAIN" >"$HYPR_MAIN.tmp"
      mv "$HYPR_MAIN.tmp" "$HYPR_MAIN"
    fi
    rm -f "$HYPR_FILE"
  fi

  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null; then
    hyprctl reload >/dev/null 2>&1 || true
  fi

  for file in "${skipped[@]}"; do echo "Kept your own keybindings for the $file"; done
}

summary() {
  echo
  if (( ${#MODULES[@]} )); then
    echo "BetterLife modules: ${MODULES[*]}"
  else
    echo "BetterLife: all modules switched off"
  fi
  if has app-switcher "${MODULES[@]}" || has workspaces "${MODULES[@]}"; then
    if (( KEYBINDS )); then
      echo "Keybindings are set up (Super+Tab, Super+E)."
    else
      echo "Keybindings not set. Later: $PLUGIN_DIR/setup.sh --keybinds"
      echo "or copy them from $PLUGIN_DIR/hypr/ into ~/.config/hypr/bindings.lua"
    fi
  fi
  echo "Change your choice any time: $PLUGIN_DIR/setup.sh"
}

# --------------------------------------------------------------------- main

only_keybinds=0
MODULES=()
modules_given=0
KEYBINDS=-1

while (( $# > 0 )); do
  case "$1" in
  --keybinds)
    only_keybinds=1
    shift
    ;;
  --keybinds-on)
    KEYBINDS=1
    shift
    ;;
  --keybinds-off)
    KEYBINDS=0
    shift
    ;;
  --modules)
    [[ $# -ge 2 ]] || fail "--modules needs a list, e.g. dock,limits"
    modules_given=1
    IFS=, read -ra MODULES <<<"$2"
    for module in "${MODULES[@]}"; do
      has "$module" "${ALL_MODULES[@]}" || fail "unknown module '$module' (${ALL_MODULES[*]})"
    done
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    fail "unknown option: $1"
    ;;
  esac
done

command -v jq >/dev/null || fail "jq is required"

if (( modules_given )); then
  :
elif (( only_keybinds )); then
  mapfile -t MODULES < <(current_modules)
else
  interactive || fail "no terminal to ask in; pass --modules (see --help)"
  # Esc or Ctrl+C in the picker changes nothing.
  picked=$(ask_modules) || exit 1
  mapfile -t MODULES <<<"$picked"
fi
# gum prints an empty line when nothing is picked.
MODULES=($(printf '%s\n' "${MODULES[@]}" | grep -v '^$' || true))

if (( KEYBINDS < 0 )); then
  if interactive && ask_keybinds; then
    KEYBINDS=1
  elif ! interactive && current_keybinds; then
    KEYBINDS=1
  else
    KEYBINDS=0
  fi
fi

if (( ! only_keybinds )); then
  write_settings
  write_shell_config
fi
write_hypr
summary
