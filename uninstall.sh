#!/usr/bin/env bash
# ==============================================================================
# UniNet - Universal Uninstaller (Linux & macOS Auto-Detect)
#
# Usage:
#   ./uninstall.sh
# ==============================================================================

set -eo pipefail

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo "Uninstalling UniNet — removing all files and settings..."
echo ""

OS="$(uname -s)"

# 1. Platform-specific hook removal
if [ "$OS" = "Darwin" ]; then
    PLIST_PATH="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"
    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo -e "  ${GREEN}✔${RESET} LaunchAgent removed"
    fi
    if command -v networksetup &>/dev/null; then
        iface="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}' | head -n 1 || echo 'en0')"
        for ssid in "UoM_Wireless" "UoM.Wireless" "UoM-Wireless"; do
            networksetup -removepreferredwirelessnetwork "$iface" "$ssid" 2>/dev/null && \
                echo -e "  ${GREEN}✔${RESET} Removed preferred network: $ssid" || true
        done
    fi

elif [ "$OS" = "Linux" ]; then
    if command -v sudo &>/dev/null; then
        sudo rm -f /etc/NetworkManager/dispatcher.d/99-uninet.sh 2>/dev/null && \
            echo -e "  ${GREEN}✔${RESET} Dispatcher hook removed" || \
            echo -e "  ${YELLOW}⚠${RESET} Could not remove dispatcher hook (sudo required)"
        sudo rm -rf /etc/uninet 2>/dev/null || true
        sudo rm -rf /usr/local/share/uninet 2>/dev/null || true
        sudo rm -f /var/log/uninet.log 2>/dev/null || true
    fi
    if command -v nmcli &>/dev/null; then
        for ssid in "UoM_Wireless" "UoM.Wireless" "UoM-Wireless"; do
            nmcli connection delete "$ssid" 2>/dev/null && \
                echo -e "  ${GREEN}✔${RESET} Wi-Fi profile removed: $ssid" || true
        done
    fi
fi

# 2. Remove configuration and credentials
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/uninet"
rm -rf "$CONFIG_DIR" 2>/dev/null && \
    echo -e "  ${GREEN}✔${RESET} Credentials and config removed" || true

# 3. Remove binaries
rm -f "$HOME/.local/bin/uninet" 2>/dev/null && \
    echo -e "  ${GREEN}✔${RESET} User binary removed" || true

if [ -w "/usr/local/bin" ]; then
    rm -f /usr/local/bin/uninet 2>/dev/null && \
        echo -e "  ${GREEN}✔${RESET} System binary removed" || true
elif command -v sudo &>/dev/null; then
    sudo rm -f /usr/local/bin/uninet 2>/dev/null && \
        echo -e "  ${GREEN}✔${RESET} System binary removed" || true
fi

echo ""
echo -e "${GREEN}✔ UniNet has been completely uninstalled from this machine.${RESET}"
