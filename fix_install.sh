#!/usr/bin/env bash
# UniNet System Reinstall — run with: sudo bash fix_install.sh
set -e
REPO="/home/dineth/dev/uninet"

echo "[1/5] Installing global binary /usr/local/bin/uninet ..."
cp "$REPO/bin/uninet" /usr/local/bin/uninet
chmod 755 /usr/local/bin/uninet
echo "      -> OK"

echo "[2/5] Installing NetworkManager dispatcher hook ..."
cp "$REPO/scripts/linux/99-uninet.sh" /etc/NetworkManager/dispatcher.d/99-uninet.sh
chmod 755 /etc/NetworkManager/dispatcher.d/99-uninet.sh
echo "      -> OK"

echo "[3/5] Creating /etc/uninet config directory ..."
mkdir -p /etc/uninet
chmod 755 /etc/uninet

echo "[4/5] Creating /var/log/uninet.log ..."
touch /var/log/uninet.log
chmod 666 /var/log/uninet.log

echo "[5/5] Restarting NetworkManager dispatcher ..."
systemctl restart NetworkManager-dispatcher 2>/dev/null || true

echo ""
echo "============================================"
echo " System install complete!"
echo " Now run (as dineth):"
echo "   uninet trust"
echo "   uninet setup"
echo "============================================"
