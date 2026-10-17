#!/usr/bin/env bash
# Install the vaks Plasma 6 widget for the current user.
set -euo pipefail

WIDGET_ID="zaburt.vaks.plasmoid"
LEGACY_ID="org.kde.vaks"
PLASMOIDS_DIR="$HOME/.local/share/plasma/plasmoids"
DEST="$PLASMOIDS_DIR/$WIDGET_ID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing vaks widget → $DEST"

mkdir -p "$PLASMOIDS_DIR"

# Older releases installed under a different id
rm -rf "$PLASMOIDS_DIR/$LEGACY_ID"

# Icon for the widget picker (referenced as "vaks" in metadata.json)
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$ICON_DIR"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contents/icons/vaks.svg" "$ICON_DIR/vaks.svg"

if [[ -d "$DEST" ]]; then
    echo "Removing existing installation..."
    rm -rf "$DEST"
fi

cp -r "$SCRIPT_DIR" "$DEST"

# Notify plasmashell of the new widget (only if explicitly requested)
if [[ "${RESTART_PLASMA:-0}" == "1" ]] && command -v plasmashell &>/dev/null; then
    plasmashell --replace &>/dev/null &
    echo "Restarting plasmashell..."
fi

echo ""
echo "Done! Right-click your panel or desktop → 'Add Widgets' → search for 'vaks'."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup (on the machine running vaksd)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Add to ~/.config/vaks/config.yml:"
echo "     http_port: 6283"
echo "     # http_token: yourtoken   # optional, recommended on untrusted networks"
echo ""
echo "2. Restart vaksd:"
echo "     systemctl --user restart vaksd"
echo ""
echo "3. Open widget settings and add a source:"
echo "     Name:  desk (or any label)"
echo "     Host:  <machine hostname or IP>"
echo "     Port:  6283"
echo "     Token: <your token if set>"
