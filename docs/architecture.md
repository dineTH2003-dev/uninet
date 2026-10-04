# UniNet Architecture & Design Specification

UniNet is engineered as a lightweight, modular Linux utility that solves a common frustration for university students and staff: navigating captive network portals every time their laptops connect to campus Wi-Fi.

---

## 1. Design Principles

1. **Zero Dependencies**: Core connectivity probing, network detection, and CLI logic rely strictly on pure Bash, `curl`, and native Linux utilities (`nmcli`). It does not require bloated GUI runtimes, interpreters like Python, or external packages.
2. **Distribution Agnostic**: Works on any Linux distribution running NetworkManager (Ubuntu, Fedora, Debian, Arch Linux, openSUSE, etc.) and macOS.
3. **Event-Driven Automation**: Integrates with NetworkManager dispatcher scripts (`/etc/NetworkManager/dispatcher.d/`) to execute only when an interface state changes, consuming zero background idle CPU.
4. **Security by Default**: Credentials are stored in simple, permission-restricted JSON files securely managed by the system.
5. **No Features**: Only addresses existing connectivity/portal issues, strictly without feature creep.

---

## 2. Event-Driven Flow (NetworkManager Dispatcher)

UniNet hooks into NetworkManager events to achieve zero idle CPU:
1. When a network interface state changes, `/etc/NetworkManager/dispatcher.d/99-uninet.sh` is invoked.
2. The script acts instantly (in ~2ms) via pure Bash substring matching against the active SSID. If it does not match campus networks (e.g. `uom.wireless`), it exits immediately.
3. If it matches, the script forks into the background, waits for DHCP / routing to settle, and then invokes `uninet login --quiet`.

---

## 3. The Two-Step Probe Pattern

Captive portals intercept outbound HTTP traffic and respond with redirects or captive pages. UniNet uses a sophisticated two-step probe flow to parse these:

### Step 1: No-Follow Probe
UniNet executes a lightweight `curl` check to an HTTP 204 endpoint (e.g. `http://connectivitycheck.gstatic.com/generate_204` or `http://connectivity-check.ubuntu.com./` for Aruba) **without** following redirects. This allows UniNet to capture the initial `Location` header, which often embeds essential gateway tokens (MAC address, IP, AP Name, etc.).

### Step 2: Follow Redirect
UniNet then resolves and follows the captured `Location` URL (or the original probe URL) to fetch the actual HTML content of the captive portal's landing page, complete with session cookies (managed via `/tmp/uninet_cookies_$UID.txt`).

---

## 4. Vendor Detection & Payload Injection

UniNet does not rely on abstract classes or providers. It implements inline form extraction and vendor-specific payload injection directly inside `cmd_login`.

### Dynamic Form Extraction
Using `grep` and `sed`, UniNet extracts the form `action` URL and any hidden inputs (`<input type="hidden">`) such as CSRF tokens or session identifiers. It auto-detects `username` and `password` field names based on common conventions.

### Vendor-Specific Injection
After extraction, UniNet adjusts the POST payload based on detected portal signatures:
* **Cisco ISE / WebAuth**: Requires an explicit `buttonClicked=4` to bypass interstitial validation.
* **Aruba Networks**: Uses the `cgi-bin/login` endpoint and demands that session parameters (like `mac`, `ip`, and `essid` obtained during the no-follow probe) are injected.
* **Ruijie Networks**: Listens on port 8443 and requires form action paths to be normalized from `/index.html` to `/login`.

---

## 5. AP Quality Scoring Algorithm

When `uninet optimize` or `uninet scan` is run, UniNet parses `nmcli` scan output and assigns each campus AP a score out of ~1000 points (displayed divided by 10 as out of 100). The formula balances signal strength and bandwidth:
1. **Signal (350 points max):** Signal percentage linearly mapped (e.g., 100% = 350).
2. **Band (300 points):** Flat +300 bonus for 5GHz / 6GHz networks, heavily favoring throughput.
3. **Rate (350 points max):** Advertised PHY rate mapped up to an 866 Mbps ceiling.
4. **Active Bonus (120 points):** Stability buffer for the currently connected AP to prevent hysteresis/flapping unless a candidate exceeds this ~15-point margin.

---

## 6. Credential Storage

Credentials are saved as plain JSON in `~/.config/uninet/credentials.json` (and `/etc/uninet/credentials.json` for system daemons).
* **Why plain JSON?** Captive portal portals require plaintext form submission anyway. A complex encryption layer would conflict with the "Zero Dependencies" rule (requiring external tools or daemons like `gnome-keyring` that may not be available in headless contexts).
* **Security:** Instead of cryptography, security is enforced via strict POSIX file permissions (`chmod 600`), preventing any other user on the system from reading the credentials.

---

## 7. Auto-Connect Priority Mechanism

To ensure the OS prioritizes university Wi-Fi over external networks (e.g. mobile hotspots), `uninet trust` leverages `nmcli` to set `connection.autoconnect-priority 100` for recognized campus SSIDs.
