-- BetterLife-Omarchy: blur layer rule for the glass surfaces.
-- Frosted-glass blur behind the dock, the app switcher and the workspace
-- viewer. Only has an effect while decoration blur is enabled, which the
-- dock's settings menu toggles and persists in dock.json.
hl.layer_rule({
  match = { namespace = "^betterlife-(dock|app-switcher|workspace-viewer)$" },
  blur = true,
  blur_popups = true,
  ignore_alpha = 0.02,
})
