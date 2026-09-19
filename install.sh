#!/usr/bin/env bash
# ==============================================================================
# UniNet - Universal One-Command Web & Local Installer (Linux & macOS)
#
# Web Installation:
#   curl -fsSL https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/install.sh | bash
#
# Local Installation:
#   ./install.sh
# ==============================================================================

set -eo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

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
        echo "For native Windows installation, please open PowerShell as Administrator and run:"
        echo "  irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/install.ps1 | iex"
        exit 0
        ;;
    *)
        echo -e "${RED}Unsupported operating system: $OS${RESET}" >&2
        exit 1
        ;;
esac

echo -e "Detected Platform: ${BOLD}${PLATFORM^^}${RESET}\n"

# 2. Dependency Resolution & Auto-Healing (Linux)
if [ "$PLATFORM" = "linux" ]; then
    install_pkg() {
        local pkg="$1"
        echo -e "${CYAN}Auto-installing required dependency: $pkg...${RESET}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm "$pkg"
        elif command -v zypper &>/dev/null; then
            sudo zypper install -y "$pkg"
        else
            echo -e "${YELLOW}Warning: Could not detect package manager. Please ensure $pkg is installed.${RESET}"
        fi
    }

    if ! command -v curl &>/dev/null; then
        install_pkg "curl"
    fi

    if ! command -v nmcli &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            install_pkg "network-manager"
        else
            install_pkg "NetworkManager"
        fi
    fi
fi

if ! command -v curl &>/dev/null; then
    echo -e "${RED}Error: 'curl' is required to continue.${RESET}" >&2
    exit 1
fi

# 3. Source File Acquisition (Local Repo vs Remote Web Pipe)
TEMP_DIR=""
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

GLOBAL_BIN="/usr/local/bin/uninet"
USER_BIN="$HOME/.local/bin/uninet"
TARGET_BIN=""

if [ "$PLATFORM" = "linux" ]; then
    LOCAL_BIN="$SCRIPT_DIR/bin/uninet"
    LOCAL_HOOK="$SCRIPT_DIR/scripts/linux/99-uninet.sh"
    DISPATCHER_TARGET="/etc/NetworkManager/dispatcher.d/99-uninet.sh"

    if [ -f "$LOCAL_BIN" ] && [ -f "$LOCAL_HOOK" ]; then
        BIN_SRC="$LOCAL_BIN"
        HOOK_SRC="$LOCAL_HOOK"
    else
        echo -e "${CYAN}Fetching latest UniNet files from GitHub...${RESET}"
        TEMP_DIR="$(mktemp -d)"
        BIN_SRC="$TEMP_DIR/uninet"
        HOOK_SRC="$TEMP_DIR/99-uninet.sh"
        curl -fsSL "$REPO_RAW_URL/bin/uninet" -o "$BIN_SRC"
        curl -fsSL "$REPO_RAW_URL/scripts/linux/99-uninet.sh" -o "$HOOK_SRC"
    fi

elif [ "$PLATFORM" = "macos" ]; then
    LOCAL_BIN="$SCRIPT_DIR/bin/uninet-macos"
    LOCAL_PLIST="$SCRIPT_DIR/scripts/macos/com.uninet.autoconnect.plist"
    PLIST_TARGET="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"

    if [ -f "$LOCAL_BIN" ] && [ -f "$LOCAL_PLIST" ]; then
        BIN_SRC="$LOCAL_BIN"
        HOOK_SRC="$LOCAL_PLIST"
    else
        echo -e "${CYAN}Fetching latest UniNet files from GitHub...${RESET}"
        TEMP_DIR="$(mktemp -d)"
        BIN_SRC="$TEMP_DIR/uninet-macos"
        HOOK_SRC="$TEMP_DIR/com.uninet.autoconnect.plist"
        curl -fsSL "$REPO_RAW_URL/bin/uninet-macos" -o "$BIN_SRC"
        curl -fsSL "$REPO_RAW_URL/scripts/macos/com.uninet.autoconnect.plist" -o "$HOOK_SRC"
    fi
fi

chmod +x "$BIN_SRC"

# 4. Install Executable Binary
echo "Installing uninet command..."
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

# 5. Install Background Auto-Connect Hook
if [ "$PLATFORM" = "linux" ]; then
    if [ -d "/etc/NetworkManager/dispatcher.d" ]; then
        echo "Installing NetworkManager background hook..."
        if command -v sudo &>/dev/null; then
            sudo cp "$HOOK_SRC" "$DISPATCHER_TARGET"
            sudo chmod 755 "$DISPATCHER_TARGET"
            echo -e "${GREEN}✔ NetworkManager hook active at $DISPATCHER_TARGET${RESET}"
        else
            echo -e "${YELLOW}To enable background auto-connect, run:${RESET}"
            echo "  sudo cp $HOOK_SRC $DISPATCHER_TARGET && sudo chmod 755 $DISPATCHER_TARGET"
        fi
    fi

elif [ "$PLATFORM" = "macos" ]; then
    echo "Installing macOS launchd auto-connect agent..."
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$HOOK_SRC" "$PLIST_TARGET"
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
