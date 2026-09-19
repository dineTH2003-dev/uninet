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

# 2. ULTRA-LOW RESOURCE OPTIMIZATION: Check SSID directly in bash
# Never spawn Python if connected to Home, Mobile Hotspot, or other networks
CURRENT_SSID="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes:' | cut -d':' -f2 || true)"

# Match against University SSID patterns (case-insensitive)
case "${CURRENT_SSID,,}" in
    *uom*|*wireless*|*campus*|*university*|*student*)
        ;; # University network matched, proceed
    *)
        exit 0 # Non-university network, exit in 2ms without touching Python!
        ;;
esac

# 3. Locate uninet binary
UNINET_BIN=""
for candidate in \
    /usr/local/bin/uninet \
    /usr/bin/uninet \
    /home/*/.local/bin/uninet \
    /home/*/dev/uninet/.venv/bin/uninet; do
    if [ -x "$candidate" ]; then
        UNINET_BIN="$candidate"
        break
    fi
done

if [ -z "$UNINET_BIN" ]; then
    exit 0
fi

# 4. Wait 2 seconds for DHCP, then run lightweight login in background
(
    sleep 2
    $UNINET_BIN login --quiet
) > /dev/null 2>&1 &

exit 0
