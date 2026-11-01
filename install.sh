#!/bin/bash
# Copy the plugin into Omarchy, where saved files hot-reload, and enable it.
set -e
source="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.config/omarchy/plugins/codesieb.omarchy-player"

mkdir -p "$target"
install -d -m 700 "$HOME/.local/state/omarchy-player"
cp "$source"/manifest.json "$source"/Panel.qml "$source"/visualizer.py "$source"/spotify.py "$target"/
omarchy-shell shell rescanPlugins
sleep 2
omarchy plugin enable codesieb.omarchy-player
