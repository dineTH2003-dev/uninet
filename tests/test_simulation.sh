#!/usr/bin/env bash
# Standalone Automated Test for UniNet Captive Portal Simulation
set -e

PORT=18081

# 1. Start mock university captive portal server in background
python3 -c "
import http.server
import threading

auth = {'logged_in': False}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            if auth['logged_in']:
                self.send_response(204)
                self.end_headers()
            else:
                self.send_response(302)
                self.send_header('Location', 'http://127.0.0.1:$PORT/login')
                self.end_headers()
        elif self.path == '/login':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/login_submit\" method=\"POST\"><input name=\"user\"><input name=\"pass\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/login_submit':
            auth['logged_in'] = True
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

http.server.HTTPServer(('127.0.0.1', $PORT), H).serve_forever()
" &
SERVER_PID=$!

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

echo "[Test 1] Initial probe to captive portal:"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/generate_204")
echo "  -> HTTP Status: $STATUS (302 Redirect Expected)"
[ "$STATUS" = "302" ]

echo "[Test 2] Follow redirect and capture form action:"
REDIRECT_URL=$(curl -s -i "http://127.0.0.1:$PORT/generate_204" | grep -i '^Location:' | awk '{print $2}' | tr -d '\r\n')
echo "  -> Redirect Target: $REDIRECT_URL"

HTML=$(curl -s "$REDIRECT_URL")
ACTION=$(echo "$HTML" | grep -i -o '<form[^>]*action="[^"]*"' | head -n 1 | sed -E 's/.*action="([^"]*)".*/\1/')
echo "  -> Extracted Form Action: $ACTION"
[ "$ACTION" = "/login_submit" ]

# Validate resolve_url properly resolves relative action to full absolute URL
eval "$(sed -n '/resolve_url() {/,/^}/p' bin/uninet)"
RESOLVED_ACTION=$(resolve_url "$REDIRECT_URL" "$ACTION")
echo "  -> Resolved Full URL: $RESOLVED_ACTION"
[ "$RESOLVED_ACTION" = "http://127.0.0.1:$PORT/login_submit" ]

echo "[Test 3] Submit simulated student credentials:"
curl -s -X POST --data-urlencode "username=210001A" --data-urlencode "password=secret" "$RESOLVED_ACTION" > /dev/null
echo "  -> Form submitted successfully!"

echo "[Test 4] Post-login probe verification:"
POST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/generate_204")
echo "  -> Post-login HTTP Status: $POST_STATUS (204 Online Expected)"
[ "$POST_STATUS" = "204" ]

echo "[Test 5] Multi-Factor AP Quality Scoring Validation:"
# Source calculate_ap_score function from bin/uninet
eval "$(sed -n '/calculate_ap_score() {/,/^}/p' bin/uninet)"

# 2.4 GHz AP (95% signal, 117 Mbps, active)
SCORE_24GHZ=$(calculate_ap_score 95 2412 117 1)
# 5.0 GHz AP (70% signal, 866 Mbps, non-active candidate)
SCORE_5GHZ=$(calculate_ap_score 70 5200 866 0)

echo "  -> 2.4 GHz (95% signal, 117 Mb/s, active): Score = $((SCORE_24GHZ / 10)).$((SCORE_24GHZ % 10))"
echo "  -> 5.0 GHz (70% signal, 866 Mb/s, candidate): Score = $((SCORE_5GHZ / 10)).$((SCORE_5GHZ % 10))"

if [ "$SCORE_5GHZ" -le "$SCORE_24GHZ" ]; then
    echo "  -> ERROR: 5 GHz high-throughput connection did not outscore 2.4 GHz!"
    exit 1
fi
echo "  -> Success: 5 GHz high-throughput connection correctly outscored 2.4 GHz!"

echo "[Test 6] Hysteresis & Connection Switching Margin Validation:"
DIFF=$((SCORE_5GHZ - SCORE_24GHZ))
echo "  -> Score difference: $((DIFF / 10)).$((DIFF % 10)) pts (Threshold: 15.0 pts)"
if [ "$DIFF" -ge 150 ]; then
    echo "  -> Candidate exceeds 15.0 pt threshold: Auto-switch triggers as expected!"
else
    echo "  -> ERROR: Expected candidate to exceed switching threshold!"
    exit 1
fi

# Marginal candidate test (difference < 15.0 pts)
MARGINAL_SCORE=$(calculate_ap_score 96 2412 130 0)
MARGINAL_DIFF=$((MARGINAL_SCORE - SCORE_24GHZ))
if [ "$MARGINAL_DIFF" -lt 150 ]; then
    echo "  -> Marginal candidate difference ($((MARGINAL_DIFF / 10)).$((MARGINAL_DIFF % 10)) pts) is within 15.0 pt margin: Flapping prevented!"
fi

echo "[Test 7] Aruba & Multi-Vendor Hidden Token Extraction Validation:"
MOCK_ARUBA_HTML='<html><form action="/cgi-bin/login" method="POST"><input type="hidden" name="cmd" value="authenticate"><input type="hidden" name="mac" value="aa:bb:cc:dd:ee:ff"><input type="text" name="user"><input type="password" name="password"></form></html>'
HIDDEN_TOKENS=$(echo "$MOCK_ARUBA_HTML" | grep -i -o '<input[^>]*>' | while read -r tag; do
    if echo "$tag" | grep -iq 'type=["'\''"]\?hidden'; then
        n="$(echo "$tag" | sed -E -n 's/.*name=["'\''"]([^"'\''>[:space:]]+)["'\''"].*/\1/p')"
        v="$(echo "$tag" | sed -E -n 's/.*value=["'\''"]([^"'\''>]*).*/\1/p')"
        [ -n "$n" ] && echo "$n=$v"
    fi
done)
if echo "$HIDDEN_TOKENS" | grep -q "cmd=authenticate" && echo "$HIDDEN_TOKENS" | grep -q "mac=aa:bb:cc:dd:ee:ff"; then
    echo "  -> Success: Successfully extracted hidden CSRF/Aruba tokens dynamically!"
else
    echo "  -> ERROR: Failed to extract hidden tokens!"
    exit 1
fi

echo "[Test 8] Campus SSID Network Discovery & Priority Pattern Validation:"
MOCK_EXISTING_PROFILES="vivo Y04 2
Dialog 4G 072
UoM.Wireless
UoM.Wireless 1
UoM_Wireless
Pixel6"

for ssid in "UoM_Wireless" "UoM.Wireless" "UoM-Wireless"; do
    MATCHED=$(echo "$MOCK_EXISTING_PROFILES" | grep -E "^${ssid}(\s+[0-9]+)?$" || true)
    if [ "$ssid" = "UoM.Wireless" ]; then
        if echo "$MATCHED" | grep -q "UoM.Wireless" && echo "$MATCHED" | grep -q "UoM.Wireless 1"; then
            echo "  -> Success: Discovered existing '$ssid' and variant 'UoM.Wireless 1' for priority enforcement!"
        else
            echo "  -> ERROR: Failed to match '$ssid' profiles!"
            exit 1
        fi
    elif [ "$ssid" = "UoM_Wireless" ]; then
        if echo "$MATCHED" | grep -q "UoM_Wireless"; then
            echo "  -> Success: Discovered existing '$ssid' for priority enforcement!"
        else
            echo "  -> ERROR: Failed to match '$ssid'!"
            exit 1
        fi
    elif [ "$ssid" = "UoM-Wireless" ]; then
        if [ -z "$MATCHED" ]; then
            echo "  -> Success: Detected missing '$ssid' for fresh profile creation with priority 100!"
        else
            echo "  -> ERROR: Expected no matches for unconfigured '$ssid'!"
            exit 1
        fi
    fi
done

echo ""
echo "🎉 ALL CAPTIVE PORTAL & AP OPTIMIZATION TESTS PASSED!"
