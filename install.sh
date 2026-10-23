#!/bin/bash

# BetterLife-Omarchy installer:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Codezilla-jpg/BetterLife-Omarchy/main/install.sh)
#
# Adds the plugin with `omarchy plugin add`, then runs setup.sh, which asks
# which modules you want and whether to set up their keybindings.

set -euo pipefail

REPO="https://github.com/Codezilla-jpg/BetterLife-Omarchy.git"
ID="codezilla.betterlife"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$ID"

fail() {
  echo "betterlife-install: $*" >&2
  exit 1
}

command -v omarchy >/dev/null || fail "this needs Omarchy (the omarchy command was not found)"
command -v gum >/dev/null || fail "gum is required"

# Piped into bash (curl … | bash) stdin is the script, not the keyboard.
if [[ ! -t 0 ]]; then
  [[ -r /dev/tty ]] || fail "no terminal to ask in; run it as: bash <(curl -fsSL …/install.sh)"
  exec </dev/tty
fi

if [[ -d $PLUGIN_DIR ]]; then
  echo "BetterLife is already installed in $PLUGIN_DIR"
else
  cat <<WARN

  BetterLife-Omarchy: dock, app switcher, workspace viewer and bar widgets.

  ⚠️  Plugins run as unsandboxed code inside omarchy-shell. Only add repos
      you trust.  $REPO

WARN
  gum confirm "Install BetterLife?" || fail "aborted"
  # --yes: the warning and the question were just above, and enabling is
  # setup.sh's job, so `plugin add` has nothing left to ask.
  omarchy plugin add "$REPO" --yes
  # setup.sh reads the plugin list, so wait until the shell has picked it up.
  for (( attempt = 0; attempt < 40; attempt++ )); do
    omarchy plugin list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null && break
    sleep 0.05
  done
fi

exec "$PLUGIN_DIR/setup.sh"
