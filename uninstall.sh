#!/usr/bin/env bash
# ==============================================================================
# UniNet - Universal Uninstaller (Linux & macOS Auto-Detect)
#
# Usage:
#   ./uninstall.sh
# ==============================================================================

set -eo pipefail

echo "Uninstalling UniNet..."

OS="$(uname -s)"

# 1. Platform-specific hook removal
if [ "$OS" = "Darwin" ]; then
    PLIST_PATH="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"
    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
    fi
    if command -v networksetup &>/dev/null; then
        iface="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}' | head -n 1 || echo 'en0')"
        for ssid in "UoM_Wireless" "UoM.Wireless" "UoM-Wireless"; do
            networksetup -removepreferredwirelessnetwork "$iface" "$ssid" 2>/dev/null || true
        done
    fi
elif [ "$OS" = "Linux" ]; then
    if [ -w "/etc/NetworkManager/dispatcher.d" ] || command -v sudo &>/dev/null; then
        sudo rm -f /etc/NetworkManager/dispatcher.d/99-uninet.sh 2>/dev/null || true
        sudo rm -rf /etc/uninet 2>/dev/null || true
        sudo rm -rf /usr/local/share/uninet 2>/dev/null || true
    fi
    if command -v nmcli &>/dev/null; then
        for ssid in "UoM_Wireless" "UoM.Wireless" "UoM-Wireless"; do
            nmcli connection delete "$ssid" 2>/dev/null || true
        done
    fi
fi

# 2. Remove configuration and binaries
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/uninet"
rm -f "$HOME/.local/bin/uninet"

if [ -w "/usr/local/bin" ]; then
    rm -f /usr/local/bin/uninet
elif command -v sudo &>/dev/null; then
    sudo rm -f /usr/local/bin/uninet 2>/dev/null || true
fi

echo "✔ UniNet has been completely uninstalled from your machine."
