#!/usr/bin/env bash
# NetworkManager Dispatcher script for UniNet
# Location: /etc/NetworkManager/dispatcher.d/99-uninet.sh
# Permissions: chmod 755 /etc/NetworkManager/dispatcher.d/99-uninet.sh

INTERFACE="$1"
ACTION="$2"

# 1. Trigger ONLY when interface reaches "up" or "connectivity-change"
if [ "$ACTION" != "up" ] && [ "$ACTION" != "connectivity-change" ]; then
    exit 0
fi

# 2. ULTRA-LOW RESOURCE OPTIMIZATION: Instant SSID check in pure bash
# NetworkManager passes $CONNECTION_ID in the environment; fallback to nmcli
SSID="${CONNECTION_ID:-}"
if [ -z "$SSID" ]; then
    SSID="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes:' | cut -d':' -f2 || true)"
fi

# Match against University SSID patterns (case-insensitive)
case "${SSID,,}" in
    *uom*|*wireless*|*campus*|*university*|*student*)
        ;; # University network matched, proceed
    *)
        exit 0 # Non-university network, exit in 2ms without touching Python!
        ;;
esac

# 3. Locate uninet binary - prioritize user-level binary so updates take effect immediately
UNINET_BIN=""
for candidate in \
    /home/*/.local/bin/uninet \
    /usr/local/bin/uninet \
    /usr/bin/uninet; do
    if [ -x "$candidate" ]; then
        UNINET_BIN="$candidate"
        break
    fi
done

if [ -z "$UNINET_BIN" ]; then
    exit 0
fi

# 4. Wait 2 seconds for DHCP lease and gateway to settle, then run login in background
(
    sleep 2
    # Sync global binary if running as root and user binary is newer
    if [ -w "/usr/local/bin/uninet" ] && [ -f "$UNINET_BIN" ] && [ "$UNINET_BIN" != "/usr/local/bin/uninet" ]; then
        cp "$UNINET_BIN" /usr/local/bin/uninet 2>/dev/null || true
    fi
    $UNINET_BIN login --quiet
) >> /var/log/uninet.log 2>&1 &

exit 0
