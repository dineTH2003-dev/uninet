#!/usr/bin/env bash
# ==============================================================================
# UniNet - Universal Turnkey Installer (Linux & macOS Auto-Detect)
#
# Usage:
#   ./install.sh
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}"
echo "======================================================="
echo "             UniNet Auto-Connect Installer             "
echo "======================================================="
echo -e "${RESET}"

# 1. Detect Operating System
OS="$(uname -s)"
case "$OS" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    CYGWIN*|MINGW*|MSYS*)
        echo -e "${YELLOW}Detected Windows environment.${RESET}"
        echo "For native Windows auto-connect, please open PowerShell as Administrator and run:"
        echo "  Set-ExecutionPolicy Bypass -Scope Process -Force"
        echo "  .\\scripts\\windows\\install.ps1"
        exit 0
        ;;
    *)
        echo -e "${RED}Unsupported operating system: $OS${RESET}" >&2
        exit 1
        ;;
esac

echo -e "Detected Platform: ${BOLD}${PLATFORM^^}${RESET}\n"

# 2. Check prerequisites
if ! command -v curl &>/dev/null; then
    echo -e "${RED}Error: 'curl' is required but not installed.${RESET}" >&2
    exit 1
fi

# 3. Select platform binaries & install paths
GLOBAL_BIN="/usr/local/bin/uninet"
USER_BIN="$HOME/.local/bin/uninet"
TARGET_BIN=""

if [ "$PLATFORM" = "linux" ]; then
    BIN_SRC="$SCRIPT_DIR/bin/uninet"
    DISP_SRC="$SCRIPT_DIR/scripts/linux/99-uninet.sh"
    DISPATCHER_TARGET="/etc/NetworkManager/dispatcher.d/99-uninet.sh"

    if ! command -v nmcli &>/dev/null; then
        echo -e "${YELLOW}Notice: NetworkManager (nmcli) not detected.${RESET}"
    fi

elif [ "$PLATFORM" = "macos" ]; then
    BIN_SRC="$SCRIPT_DIR/bin/uninet-macos"
    PLIST_SRC="$SCRIPT_DIR/scripts/macos/com.uninet.autoconnect.plist"
    PLIST_TARGET="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"
fi

chmod +x "$BIN_SRC"

# 4. Install binary
echo "Installing uninet executable..."
if [ -w "/usr/local/bin" ]; then
    cp "$BIN_SRC" "$GLOBAL_BIN"
    chmod 755 "$GLOBAL_BIN"
    TARGET_BIN="$GLOBAL_BIN"
elif command -v sudo &>/dev/null; then
    sudo cp "$BIN_SRC" "$GLOBAL_BIN"
    sudo chmod 755 "$GLOBAL_BIN"
    TARGET_BIN="$GLOBAL_BIN"
else
    mkdir -p "$HOME/.local/bin"
    cp "$BIN_SRC" "$USER_BIN"
    chmod 755 "$USER_BIN"
    TARGET_BIN="$USER_BIN"
fi

echo -e "${GREEN}✔ Installed uninet to $TARGET_BIN${RESET}"

# 5. Platform Background Auto-Connect Hook Installation
if [ "$PLATFORM" = "linux" ]; then
    if [ -d "/etc/NetworkManager/dispatcher.d" ]; then
        echo "Installing NetworkManager background hook..."
        if command -v sudo &>/dev/null; then
            sudo cp "$DISP_SRC" "$DISPATCHER_TARGET"
            sudo chmod 755 "$DISPATCHER_TARGET"
            echo -e "${GREEN}✔ NetworkManager hook active at $DISPATCHER_TARGET${RESET}"
        else
            echo -e "${YELLOW}To enable background connection, run:${RESET}"
            echo "  sudo cp $DISP_SRC $DISPATCHER_TARGET && sudo chmod 755 $DISPATCHER_TARGET"
        fi
    fi

elif [ "$PLATFORM" = "macos" ]; then
    echo "Installing macOS launchd auto-connect agent..."
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$PLIST_SRC" "$PLIST_TARGET"
    launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    launchctl load "$PLIST_TARGET" 2>/dev/null || true
    echo -e "${GREEN}✔ macOS LaunchAgent active at $PLIST_TARGET${RESET}"
fi

# 6. Interactive Setup
echo ""
"$TARGET_BIN" setup

echo -e "\n${BOLD}${GREEN}======================================================="
echo "🎉 Congratulations! UniNet is fully installed."
echo "Whenever your laptop connects to university Wi-Fi:"
echo "  • UoM_Wireless"
echo "  • UoM.Wireless"
echo "  • UoM-Wireless"
echo "It will automatically authenticate in the background!"
echo -e "=======================================================${RESET}\n"
