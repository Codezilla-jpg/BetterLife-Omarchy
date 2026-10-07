-- BetterLife-Omarchy: Hyprland (Lua config) snippets.
-- Copy what you want into ~/.config/hypr/bindings.lua and looknfeel.lua.

-------------------------------------------------------------------- viewer
-- SUPER+E opens the Mission-Control-style workspace viewer.
o.bind("SUPER + E", "Workspace viewer", "omarchy-shell -q betterlife.workspace-viewer toggle")

--------------------------------------------------------------------- blur
-- Frosted-glass blur behind the dock, the app switcher and the workspace
-- viewer. Only has an effect while decoration blur is enabled, which the
-- dock's settings menu toggles and persists in dock.json.
hl.layer_rule({
  match = { namespace = "^betterlife-(dock|app-switcher|workspace-viewer)$" },
  blur = true,
  blur_popups = true,
  ignore_alpha = 0.02,
})

------------------------------------------------------------- app switcher
-- macOS-style Cmd+Tab app switcher (BetterLife app-switcher module).
--
-- Holding SUPER and tapping TAB opens a centered overlay of the open apps,
-- most recently used first, with the next one already highlighted. Further
-- TAB taps, the arrow keys LEFT/RIGHT and the scroll wheel move the
-- highlight; SHIFT reverses TAB. Releasing SUPER switches to the highlighted
-- app (jumping to its workspace if needed). Escape, or a click next to the
-- overlay, backs out without switching. A left click on an icon switches to
-- that app right away, without waiting for SUPER to come up.
--
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

-- The window list, the highlight and the actual switch all live in the
-- plugin, so there is only one list to keep straight. This side is purely the
-- gesture: it opens the overlay, reports where the highlight should sit, and
-- says when the gesture ended.
--
-- hl.exec_cmd spawns a detached subprocess per call, so two calls can land out
-- of order. Each call therefore carries an absolute step count instead of a
-- "move by one" nudge, plus the generation of the current gesture so the
-- plugin can drop anything arriving late for an already finished one.
local switcher_gen = 0
local switcher_step = 0
local switcher_active = false

local function switcher_send(method, arg)
  local cmd = "omarchy-shell -q betterlife.app-switcher " .. method .. " " .. tostring(switcher_gen)
  if arg ~= nil then cmd = cmd .. " " .. tostring(arg) end
  hl.exec_cmd(cmd)
end

-- Step 0 is the app you came from, 1 the next one down the list, -1 the last.
local function switcher_move(delta)
  if not switcher_active then return end
  switcher_step = switcher_step + delta
  switcher_send("step", switcher_step)
end

local function switcher_begin(delta)
  switcher_gen = switcher_gen + 1
  switcher_step = delta
  switcher_active = true
  switcher_send("step", switcher_step)
  hl.dispatch(hl.dsp.submap("app_switcher"))
end

local function switcher_confirm()
  if not switcher_active then return end
  switcher_active = false
  switcher_send("confirm")
  hl.dispatch(hl.dsp.submap("reset"))
end

local function switcher_cancel()
  if not switcher_active then return end
  switcher_active = false
  switcher_send("cancel")
  hl.dispatch(hl.dsp.submap("reset"))
end

-- With fcitx5 as input method (hl-virtual-keyboard-fcitx5) it grabs the
-- physical keyboard and re-emits keys, and a SUPER release doesn't always come
-- back through Hyprland's bind matcher as a key-up, so the release binds below
-- miss some gestures on their own. Raw key events always arrive, so watch
-- those too — but only while the switcher is open, never during normal typing.
hl.on("input.keyboard.key", function(...)
  if not switcher_active then return end

  if hl.get_current_submap() ~= "app_switcher" then
    -- The overlay ended the gesture itself (a click) and already left the
    -- submap; there is nothing left to confirm on this side.
    switcher_active = false
    return
  end

  -- Payload: keycode (xkb; Super_L = 133, Super_R = 134), timestamp in ms,
  -- state (0 = released, 1 = pressed).
  local args = { ... }
  local keycode, state = args[1], args[3]
  if (keycode == 133 or keycode == 134) and state == 0 then
    switcher_confirm()
  end
end)

hl.define_submap("app_switcher", function()
  local function forward() switcher_move(1) end
  local function backward() switcher_move(-1) end

  hl.bind("Tab", forward)
  hl.bind("SUPER + Tab", forward)
  hl.bind("SHIFT + Tab", backward)
  hl.bind("SUPER + SHIFT + Tab", backward)

  hl.bind("RIGHT", forward)
  hl.bind("SUPER + RIGHT", forward)
  hl.bind("LEFT", backward)
  hl.bind("SUPER + LEFT", backward)

  hl.bind("mouse_down", forward)
  hl.bind("SUPER + mouse_down", forward)
  hl.bind("mouse_up", backward)
  hl.bind("SUPER + mouse_up", backward)

  hl.bind("Escape", switcher_cancel)
  hl.bind("SUPER + Escape", switcher_cancel)

  -- Releasing either physical SUPER key ends the gesture and switches to
  -- whatever is highlighted. At the moment SUPER_L comes up the SUPER
  -- modifier bit is still set (modmask 64), so a bare "Super_L" release bind
  -- (modmask 0) never matches on its own. Register every modifier
  -- combination that can be held at that point.
  for _, mods in ipairs({ "", "SUPER + ", "SHIFT + ", "SUPER + SHIFT + " }) do
    hl.bind(mods .. "Super_L", switcher_confirm, { release = true })
    hl.bind(mods .. "Super_R", switcher_confirm, { release = true })
  end
end)

o.bind("SUPER + TAB", "App switcher: next app", function() switcher_begin(1) end)
o.bind("SUPER + SHIFT + TAB", "App switcher: previous app", function() switcher_begin(-1) end)
