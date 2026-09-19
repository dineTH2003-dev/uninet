# Captive Portal Analysis & Reverse-Engineering Guide

This guide walks you through analyzing how your university's captive portal works under the hood so you can build a provider for it.

---

## 1. Quick Capture with UniNet

UniNet includes a built-in diagnostic dump command:

```bash
uninet test --dump-portal
```

If a captive portal is detected, this command saves the landing page HTML and HTTP headers into `portal_dump.html` and `portal_headers.json`.

---

## 2. Manual Browser DevTools Inspection

The most accurate way to understand your portal's authentication flow is using your browser's Developer Tools:

### Step 1: Open DevTools before connecting
1. Disconnect from your university Wi-Fi or turn off Wi-Fi.
2. Open Chrome/Firefox/Brave.
3. Press `F12` or `Ctrl + Shift + I` to open Developer Tools.
4. Go to the **Network** tab.
5. Check **Preserve log** (crucial, as redirects will clear the log otherwise).

### Step 2: Connect and Trigger Portal
1. Connect to your university Wi-Fi.
2. In the browser, navigate to an insecure HTTP site (e.g. `http://neverssl.com` or `http://example.com`).
3. Notice how the network intercepts the request and redirects to your university portal URL.
4. In DevTools, locate the **first request** to `neverssl.com`. Inspect:
   - Status code (usually `302 Found` or `307 Temporary Redirect`).
   - `Location` header (contains the login URL with tokens, client IP, or MAC address).

### Step 3: Inspect the Login Form Submission
1. Enter your student credentials on the login page and click **Login / Submit**.
2. Look at the Network tab for the `POST` request sent when clicking Submit:
   - **Request URL**: Where is the form submitting? (e.g., `/login`, `/cgi-bin/login`, `/auth/index.php`).
   - **Request Method**: `POST` or `GET`.
   - **Form Data / Payload**: Look at the keys being sent:
     - Username field (e.g. `user`, `username`, `auth_user`, `email`).
     - Password field (e.g. `password`, `pass`, `auth_pass`).
     - Hidden tokens (e.g. `csrf_token`, `magic`, `dst`, `4Tredir`).
   - **Response**:
     - Check if it sets session cookies (`Set-Cookie`).
     - Check the redirect target or success text (e.g., "Login Successful", "You are now connected").

---

## 3. Command-Line Inspection with `curl`

You can also simulate the redirection flow directly from the terminal:

```bash
# 1. Test standard HTTP probe and follow redirect
curl -v -L "http://connectivitycheck.gstatic.com/generate_204"

# 2. Inspect headers only
curl -I "http://connectivitycheck.gstatic.com/generate_204"

# 3. Save the login page HTML to inspect forms
curl -s -L "http://connectivitycheck.gstatic.com/generate_204" > campus_login.html
```

Inspect the form fields inside `campus_login.html`:
```bash
grep -i -E '<form|<input' campus_login.html
```

---

## 4. Common Portal Vendors

Most universities use off-the-shelf commercial network controllers:
- **Aruba ClearPass**: Often submits to `/cgi-bin/login` or `/guest/portal.php`.
- **Fortinet FortiGate**: Uses `fgtauth` or submits to `https://<gateway>:1003/keepalive?`.
- **Cisco ISE**: Submits to `/portal/PortalSetup.action` or `/guest/`.
- **Mikrotik Hotspot**: Submits to `http://<gateway>/login` with `username` and `password`.
- **pfSense / OPNsense**: Form submits to `:8002/index.php?zone=...`.

Once you have identified your university's submission URL and form fields, you can either use the `GenericProvider` or create a customized provider class under `src/uninet/providers/`.
