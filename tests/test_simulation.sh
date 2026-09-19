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

echo "[Test 3] Submit simulated student credentials:"
curl -s -X POST --data-urlencode "username=210001A" --data-urlencode "password=secret" "http://127.0.0.1:$PORT$ACTION" > /dev/null
echo "  -> Form submitted successfully!"

echo "[Test 4] Post-login probe verification:"
POST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/generate_204")
echo "  -> Post-login HTTP Status: $POST_STATUS (204 Online Expected)"
[ "$POST_STATUS" = "204" ]

echo ""
echo "🎉 ALL CAPTIVE PORTAL SIMULATION TESTS PASSED!"
