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

step()  { echo -e "${CYAN}[UniNet]${RESET} $*"; }
ok()    { echo -e "         ${GREEN}✔ $*${RESET}"; }
warn()  { echo -e "         ${YELLOW}⚠ $*${RESET}"; }
fail()  { echo -e "         ${RED}✘ $*${RESET}"; }

# ── 1. Detect Operating System ─────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
    Linux*)     PLATFORM="linux" ;;
    Darwin*)    PLATFORM="macos" ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Detected Windows environment."
        echo "For native Windows installation, open PowerShell as Administrator and run:"
        echo "  irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/install.ps1 | iex"
        exit 0
        ;;
    *)
        echo "Unsupported operating system: $OS" >&2
        exit 1
        ;;
esac

# ── 2. Dependency Check ────────────────────────────────────────────────────
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

if [ "$PLATFORM" = "linux" ]; then
    if ! command -v curl &>/dev/null; then
        step "Installing curl (required)..."
        install_pkg "curl"
    fi
    if ! command -v nmcli &>/dev/null; then
        step "Installing NetworkManager (required)..."
        if command -v apt-get &>/dev/null; then
            install_pkg "network-manager"
        else
            install_pkg "NetworkManager"
        fi
    fi
fi

if ! command -v curl &>/dev/null; then
    fail "'curl' is required but could not be installed. Please install it manually."
    exit 1
fi

# ── 3. Source File Acquisition ─────────────────────────────────────────────
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

echo ""
echo -e "${BOLD}${CYAN}========================================================"
echo -e "        UniNet — University Wi-Fi Auto-Connect"
echo -e "========================================================${RESET}"
echo ""

if [ "$PLATFORM" = "linux" ]; then
    LOCAL_BIN="$SCRIPT_DIR/bin/uninet"
    LOCAL_HOOK="$SCRIPT_DIR/scripts/linux/99-uninet.sh"
    DISPATCHER_TARGET="/etc/NetworkManager/dispatcher.d/99-uninet.sh"

    if [ -f "$LOCAL_BIN" ] && [ -f "$LOCAL_HOOK" ]; then
        step "Using local source files..."
        BIN_SRC="$LOCAL_BIN"
        HOOK_SRC="$LOCAL_HOOK"
        ok "Found local repo at $SCRIPT_DIR"
    else
        step "Downloading UniNet from GitHub..."
        TEMP_DIR="$(mktemp -d)"
        if curl -fsSL --connect-timeout 8 --max-time 20 \
            "$REPO_RELEASE_URL/uninet-linux.tar.gz" \
            -o "$TEMP_DIR/uninet-linux.tar.gz" 2>/dev/null \
           && tar -xzf "$TEMP_DIR/uninet-linux.tar.gz" -C "$TEMP_DIR" 2>/dev/null \
           && [ -f "$TEMP_DIR/bin/uninet" ]; then
            BIN_SRC="$TEMP_DIR/bin/uninet"
            HOOK_SRC="$TEMP_DIR/scripts/linux/99-uninet.sh"
            ok "Downloaded release archive"
        else
            BIN_SRC="$TEMP_DIR/uninet"
            HOOK_SRC="$TEMP_DIR/99-uninet.sh"
            curl -fsSL "$REPO_RAW_URL/bin/uninet" -o "$BIN_SRC" \
                && curl -fsSL "$REPO_RAW_URL/scripts/linux/99-uninet.sh" -o "$HOOK_SRC"
            ok "Downloaded from repository (raw)"
        fi
    fi

elif [ "$PLATFORM" = "macos" ]; then
    LOCAL_BIN="$SCRIPT_DIR/bin/uninet-macos"
    LOCAL_PLIST="$SCRIPT_DIR/scripts/macos/com.uninet.autoconnect.plist"
    PLIST_TARGET="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"

    if [ -f "$LOCAL_BIN" ] && [ -f "$LOCAL_PLIST" ]; then
        step "Using local source files..."
        BIN_SRC="$LOCAL_BIN"
        HOOK_SRC="$LOCAL_PLIST"
        ok "Found local repo at $SCRIPT_DIR"
    else
        step "Downloading UniNet from GitHub..."
        TEMP_DIR="$(mktemp -d)"
        if curl -fsSL --connect-timeout 8 --max-time 20 \
            "$REPO_RELEASE_URL/uninet-macos.tar.gz" \
            -o "$TEMP_DIR/uninet-macos.tar.gz" 2>/dev/null \
           && tar -xzf "$TEMP_DIR/uninet-macos.tar.gz" -C "$TEMP_DIR" 2>/dev/null \
           && [ -f "$TEMP_DIR/bin/uninet-macos" ]; then
            BIN_SRC="$TEMP_DIR/bin/uninet-macos"
            HOOK_SRC="$TEMP_DIR/scripts/macos/com.uninet.autoconnect.plist"
            ok "Downloaded release archive"
        else
            BIN_SRC="$TEMP_DIR/uninet-macos"
            HOOK_SRC="$TEMP_DIR/com.uninet.autoconnect.plist"
            curl -fsSL "$REPO_RAW_URL/bin/uninet-macos" -o "$BIN_SRC" \
                && curl -fsSL "$REPO_RAW_URL/scripts/macos/com.uninet.autoconnect.plist" -o "$HOOK_SRC"
            ok "Downloaded from repository (raw)"
        fi
    fi
fi

chmod +x "$BIN_SRC"

# ── 4. Install User Binary ─────────────────────────────────────────────────
echo ""
step "Step 1/4 — Installing UniNet binary..."
mkdir -p "$HOME/.local/bin"
cp "$BIN_SRC" "$USER_BIN"
chmod 755 "$USER_BIN"
TARGET_BIN="$USER_BIN"

if [ -x "$USER_BIN" ]; then
    ok "Installed to $USER_BIN ($("$USER_BIN" --version 2>/dev/null || echo 'ok'))"
else
    fail "Failed to install binary to $USER_BIN"
    exit 1
fi

# Also install system-wide via sudo
if command -v sudo &>/dev/null; then
    if sudo cp "$BIN_SRC" "$GLOBAL_BIN" 2>/dev/null && sudo chmod 755 "$GLOBAL_BIN" 2>/dev/null; then
        ok "Also installed system-wide at $GLOBAL_BIN"
        TARGET_BIN="$GLOBAL_BIN"
    else
        warn "Could not install system-wide (sudo timed out or unavailable)"
        warn "User-level binary at $USER_BIN will be used instead"
    fi
fi

# Warn if ~/.local/bin not in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "~/.local/bin is not in your PATH. Add this to your ~/.bashrc or ~/.zshrc:"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 5. Install Background Auto-Connect Hook ────────────────────────────────
echo ""
step "Step 2/4 — Installing auto-connect background hook..."

DISPATCHER_INSTALLED=false

if [ "$PLATFORM" = "linux" ]; then
    if [ -d "/etc/NetworkManager/dispatcher.d" ]; then
        if sudo cp "$HOOK_SRC" "$DISPATCHER_TARGET" 2>/dev/null \
           && sudo chmod 755 "$DISPATCHER_TARGET" 2>/dev/null \
           && [ -f "$DISPATCHER_TARGET" ]; then
            DISPATCHER_INSTALLED=true
            ok "Dispatcher hook installed at $DISPATCHER_TARGET"
            # Create log file
            if sudo touch /var/log/uninet.log 2>/dev/null \
               && sudo chmod 666 /var/log/uninet.log 2>/dev/null; then
                ok "Log file ready at /var/log/uninet.log"
            fi
            # Restart dispatcher
            sudo systemctl restart NetworkManager-dispatcher 2>/dev/null || true
        else
            fail "Could not install dispatcher hook — sudo required"
            echo ""
            echo -e "  ${YELLOW}Run this command manually to complete auto-connect setup:${RESET}"
            echo ""
            echo -e "  ${BOLD}sudo cp \"$HOOK_SRC\" \"$DISPATCHER_TARGET\"${RESET}"
            echo -e "  ${BOLD}sudo chmod 755 \"$DISPATCHER_TARGET\"${RESET}"
            echo -e "  ${BOLD}sudo touch /var/log/uninet.log && sudo chmod 666 /var/log/uninet.log${RESET}"
            echo ""
            warn "Auto-connect will NOT work until the dispatcher hook is installed"
            warn "Manual commands (uninet login, uninet scan, etc.) will still work"
        fi
    else
        fail "NetworkManager dispatcher directory not found — is NetworkManager installed?"
        warn "Install with: sudo apt-get install network-manager"
    fi

elif [ "$PLATFORM" = "macos" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$HOOK_SRC" "$PLIST_TARGET"
    launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    if launchctl load "$PLIST_TARGET" 2>/dev/null; then
        DISPATCHER_INSTALLED=true
        ok "LaunchAgent loaded: $PLIST_TARGET"
    else
        fail "Could not load LaunchAgent"
        warn "Run manually: launchctl load $PLIST_TARGET"
    fi
fi

# ── 6. Install Logo Asset ──────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/assets/uom_logo.ans" ]; then
    if sudo mkdir -p "/usr/local/share/uninet" 2>/dev/null \
       && sudo cp "$SCRIPT_DIR/assets/uom_logo.ans" "/usr/local/share/uninet/uom_logo.ans" 2>/dev/null; then
        : # ok silently
    else
        mkdir -p "$HOME/.config/uninet"
        cp "$SCRIPT_DIR/assets/uom_logo.ans" "$HOME/.config/uninet/uom_logo.ans" 2>/dev/null || true
    fi
fi

# ── 7. Set Wi-Fi Auto-Connect Priority ────────────────────────────────────
echo ""
step "Step 3/4 — Setting university Wi-Fi auto-connect priority..."
if "$TARGET_BIN" trust 2>/dev/null; then
    ok "UoM Wi-Fi profiles set to priority 100 (preferred over other networks)"
else
    warn "Could not set Wi-Fi priorities — run 'uninet trust' manually after setup"
fi

# ── 8. Interactive Credential Setup ───────────────────────────────────────
echo ""
step "Step 4/4 — Setting up your university credentials..."
echo ""
"$TARGET_BIN" setup

# ── 9. Final Summary ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}========================================================"
echo -e "  Installation Summary"
echo -e "========================================================${RESET}"
echo -e "  Binary:         ${GREEN}✔ Installed${RESET} ($TARGET_BIN)"
if [ "$DISPATCHER_INSTALLED" = true ]; then
    echo -e "  Auto-connect:   ${GREEN}✔ Active${RESET} (background hook installed)"
    echo -e "  Wi-Fi Priority: ${GREEN}✔ Set to 100 for all UoM networks${RESET}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Everything is ready!${RESET}"
    echo -e "  Turn Wi-Fi off and back on — UniNet will log in automatically."
else
    echo -e "  Auto-connect:   ${RED}✘ Needs one manual step (see above)${RESET}"
    echo -e "  Wi-Fi Priority: ${GREEN}✔ Set to 100 for all UoM networks${RESET}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Almost ready!${RESET} Run the sudo commands shown above,"
    echo -e "  then toggle Wi-Fi to test auto-connect."
fi
echo -e "${CYAN}========================================================${RESET}"
echo ""
