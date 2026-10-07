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
omarchy plugin add https://github.com/Codezilla-jpg/BetterLife-Omarchy.git --enable
```

That clones the plugin to `~/.config/omarchy/plugins/codezilla.betterlife/`
and turns on the dock, the app switcher and the workspace viewer.

### Bar widgets

Omarchy gives a plugin one bar widget, so both bar modules come through the
same widget and a `module` setting picks which one. Add it once per module in
`~/.config/omarchy/shell.json`:

```json
"left":  [ { "id": "omarchy.menu" }, { "id": "codezilla.betterlife", "module": "workspaces" } ],
"right": [ { "id": "codezilla.betterlife", "module": "limits" } ]
```

### Keybindings

The app switcher and the workspace viewer are driven from Hyprland. Copy the
parts you want from [`examples/hyprland.lua`](examples/hyprland.lua):

- **Super+Tab** gesture for the app switcher (hold Super, tap Tab, release)
- **Super+E** for the workspace viewer
- the blur layer rule for the glass surfaces

Then `hyprctl reload`.

## Turning modules off

Everything outside the bar is on by default. To switch a module off, create
`~/.local/state/omarchy/settings/betterlife.json`:

```json
{ "modules": { "dock": false, "appSwitcher": true, "workspaceViewer": true } }
```

Changes apply right away.

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
examples/hyprland.lua
```

Each module is self-contained in its folder; only `shared/` is common.

Note: after editing a module's QML, run `omarchy-restart-shell`. The overlay
part stays loaded, so a hot reload keeps running the old code.

## License

MIT
