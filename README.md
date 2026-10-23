# BetterLife-Omarchy

One [Omarchy](https://omarchy.org/) shell plugin that bundles a handful of
macOS-flavoured quality-of-life additions:

| Module | Where | What it does |
|--------|-------|--------------|
| **Dock** | screen edge | Glass dock of running apps. Click the edge handle (or right-click the dock) for settings: edge, size, autohide, style, blur. |
| **App switcher** | overlay | Cmd+Tab-style Super+Tab switcher, most recently used first. With several monitors every app shows a small badge with its monitor number, and a legend below names each monitor. |
| **Workspace viewer** | overlay | Mission-Control-style overview: a Spaces bar per monitor with live miniatures. Drag desktops to reorder or move them between monitors, drag windows between desktops, drop onto the trash to close. |
| **Workspaces** | bar widget | Workspace indicators that only show workspaces in use and renumber them 1..n. |
| **Limits** | bar widget | Weekly limits and local session tokens for Grok, Claude and Codex. Click opens the panel, middle-click switches agent, right-click launches it. |

Requires Omarchy with the Quickshell-based shell and Hyprland's Lua config.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Codezilla-jpg/BetterLife-Omarchy/main/install.sh)
```

The installer adds the plugin to `~/.config/omarchy/plugins/codezilla.betterlife/`
and then asks two things right in the terminal:

1. **Which modules?** A checklist (Space toggles, Enter confirms):
   - Dock
   - App switcher
   - Workspaces (the workspace viewer and the workspaces bar widget)
   - Limits
2. **Keybindings now or later?** Super+Tab for the app switcher and Super+E
   for the workspace viewer. Only asked when one of those two is picked.

Only what you pick gets switched on. Bar widgets are placed for you: the
workspaces widget takes the place of Omarchy's own, Limits goes next to the
tray.

Already added the plugin with `omarchy plugin add`? Run the setup yourself:

```bash
~/.config/omarchy/plugins/codezilla.betterlife/setup.sh
```

## Changing your choice

Run the setup again; it starts from what is set now.

```bash
~/.config/omarchy/plugins/codezilla.betterlife/setup.sh             # modules + keybindings
~/.config/omarchy/plugins/codezilla.betterlife/setup.sh --keybinds  # keybindings only
```

Without a terminal, e.g. from a dotfiles script:

```bash
setup.sh --modules dock,app-switcher,workspaces,limits --keybinds-on
```

What the setup writes:

| File | What |
|------|------|
| `~/.local/state/omarchy/settings/betterlife.json` | which of dock, app switcher and workspace viewer load |
| `~/.config/omarchy/shell.json` | the bar widgets, and the plugin in `plugins` |
| `~/.config/hypr/betterlife.lua` | loads the chosen snippets from the plugin's `hypr/` folder |
| `~/.config/hypr/hyprland.lua` | one `require_optional` line for the file above |

The keybindings are loaded straight from the plugin, so `omarchy plugin update`
updates them too, and a removed plugin just loads nothing. If you would rather
keep them in your own `bindings.lua`, answer "later" and copy what you want
from [`hypr/`](hypr/); the setup notices bindings you already have and does not
add them twice.

## IPC

| Target | Methods |
|--------|---------|
| `betterlife.dock` | `openSettings`, `toggleSettings`, `toggleVisible`, `setPosition <edge>`, `setScale <percent>`, `setStyle <glass\|tinted\|minimal\|solid>`, `setAutohide <bool>`, `setBlur <bool>` |
| `betterlife.app-switcher` | `step <gen> <n>`, `confirm <gen>`, `cancel <gen>`, `status` |
| `betterlife.workspace-viewer` | `toggle`, `open`, `close`, `dump`, … |
| `betterlife.limits` | `open`, `close`, `toggle`, `refresh`, `next` |

```bash
omarchy-shell betterlife.dock toggleVisible
```

## Layout

```
manifest.json        one plugin: overlay + bar widget
Overlays.qml         hosts dock, app switcher, workspace viewer
BarWidget.qml        loads the bar module picked by "module"
shared/              app icons and glass surface, used by several modules
modules/
  dock/
  app-switcher/
  workspace-viewer/
  workspaces/
  limits/            QML panel + collect.py (reads local agent sessions)
hypr/                Hyprland snippets: keybindings and the blur rule
install.sh           curl installer: adds the plugin, then runs setup.sh
setup.sh             module and keybinding picker
```

Each module is self-contained in its folder; only `shared/` is common.

Note: after editing a module's QML, run `omarchy-restart-shell`. The overlay
part stays loaded, so a hot reload keeps running the old code.

## License

MIT
