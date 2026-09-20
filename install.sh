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
REPO_RELEASE_URL="https://github.com/dineTH2003-dev/uninet/releases/latest/download"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 1. Detect Operating System
OS="$(uname -s)"
case "$OS" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Detected Windows environment."
        echo "For native Windows installation, please open PowerShell as Administrator and run:"
        echo "  irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/install.ps1 | iex"
        exit 0
        ;;
    *)
        echo "Unsupported operating system: $OS" >&2
        exit 1
        ;;
esac

# 2. Dependency Resolution & Auto-Healing (Linux)
if [ "$PLATFORM" = "linux" ]; then
    install_pkg() {
        local pkg="$1"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q "$pkg" >/dev/null 2>&1
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1
        elif command -v zypper &>/dev/null; then
            sudo zypper install -y "$pkg" >/dev/null 2>&1
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
    echo "Error: 'curl' is required to continue." >&2
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
        TEMP_DIR="$(mktemp -d)"
        # Try downloading official release archive first (increments GitHub release download counter)
        if curl -fsSL --connect-timeout 5 --max-time 15 "$REPO_RELEASE_URL/uninet-linux.tar.gz" -o "$TEMP_DIR/uninet-linux.tar.gz" 2>/dev/null && tar -xzf "$TEMP_DIR/uninet-linux.tar.gz" -C "$TEMP_DIR" 2>/dev/null; then
            BIN_SRC="$TEMP_DIR/bin/uninet"
            HOOK_SRC="$TEMP_DIR/scripts/linux/99-uninet.sh"
            if [ -f "$TEMP_DIR/assets/uom_logo.ans" ]; then
                mkdir -p "$HOME/.config/uninet"
                cp "$TEMP_DIR/assets/uom_logo.ans" "$HOME/.config/uninet/uom_logo.ans" 2>/dev/null || true
            fi
        else
            # Graceful fallback to raw repository files
            BIN_SRC="$TEMP_DIR/uninet"
            HOOK_SRC="$TEMP_DIR/99-uninet.sh"
            curl -fsSL "$REPO_RAW_URL/bin/uninet" -o "$BIN_SRC"
            curl -fsSL "$REPO_RAW_URL/scripts/linux/99-uninet.sh" -o "$HOOK_SRC"
        fi
    fi

elif [ "$PLATFORM" = "macos" ]; then
    LOCAL_BIN="$SCRIPT_DIR/bin/uninet-macos"
    LOCAL_PLIST="$SCRIPT_DIR/scripts/macos/com.uninet.autoconnect.plist"
    PLIST_TARGET="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"

    if [ -f "$LOCAL_BIN" ] && [ -f "$LOCAL_PLIST" ]; then
        BIN_SRC="$LOCAL_BIN"
        HOOK_SRC="$LOCAL_PLIST"
    else
        TEMP_DIR="$(mktemp -d)"
        # Try downloading official release archive first (increments GitHub release download counter)
        if curl -fsSL --connect-timeout 5 --max-time 15 "$REPO_RELEASE_URL/uninet-macos.tar.gz" -o "$TEMP_DIR/uninet-macos.tar.gz" 2>/dev/null && tar -xzf "$TEMP_DIR/uninet-macos.tar.gz" -C "$TEMP_DIR" 2>/dev/null; then
            BIN_SRC="$TEMP_DIR/bin/uninet-macos"
            HOOK_SRC="$TEMP_DIR/scripts/macos/com.uninet.autoconnect.plist"
            if [ -f "$TEMP_DIR/assets/uom_logo.ans" ]; then
                mkdir -p "$HOME/.config/uninet"
                cp "$TEMP_DIR/assets/uom_logo.ans" "$HOME/.config/uninet/uom_logo.ans" 2>/dev/null || true
            fi
        else
            # Graceful fallback to raw repository files
            BIN_SRC="$TEMP_DIR/uninet-macos"
            HOOK_SRC="$TEMP_DIR/com.uninet.autoconnect.plist"
            curl -fsSL "$REPO_RAW_URL/bin/uninet-macos" -o "$BIN_SRC"
            curl -fsSL "$REPO_RAW_URL/scripts/macos/com.uninet.autoconnect.plist" -o "$HOOK_SRC"
        fi
    fi
fi

chmod +x "$BIN_SRC"

# 4. Install Executable Binary
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

# Optional: Install Logo Asset if available locally
if [ -f "$SCRIPT_DIR/assets/uom_logo.ans" ]; then
    if [ -w "/usr/local/share" ]; then
        mkdir -p "/usr/local/share/uninet"
        cp "$SCRIPT_DIR/assets/uom_logo.ans" "/usr/local/share/uninet/uom_logo.ans" 2>/dev/null || true
    elif command -v sudo &>/dev/null; then
        sudo mkdir -p "/usr/local/share/uninet" 2>/dev/null || true
        sudo cp "$SCRIPT_DIR/assets/uom_logo.ans" "/usr/local/share/uninet/uom_logo.ans" 2>/dev/null || true
    fi
fi

# 5. Install Background Auto-Connect Hook
if [ "$PLATFORM" = "linux" ]; then
    if [ -d "/etc/NetworkManager/dispatcher.d" ]; then
        if command -v sudo &>/dev/null; then
            sudo cp "$HOOK_SRC" "$DISPATCHER_TARGET" 2>/dev/null || true
            sudo chmod 755 "$DISPATCHER_TARGET" 2>/dev/null || true
        fi
    fi

elif [ "$PLATFORM" = "macos" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$HOOK_SRC" "$PLIST_TARGET"
    launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    launchctl load "$PLIST_TARGET" 2>/dev/null || true
fi

# 6. Interactive Setup
"$TARGET_BIN" setup
