# PROMPT FOR AI ASSISTANT / ARCHITECT

You are a Principal Systems Engineer, Linux Specialist, and Network Security Architect. Below is the complete technical architecture and implementation specification for "UniNet", a mature open-source captive portal automation engine.

Review the codebase architecture, design choices, algorithms, and limitations detailed below. Then provide:
1. Architectural Critique & Potential Vulnerabilities / Failure Modes.
2. Short-term Improvements (maintaining the strict "Zero Dependencies" constraint).
3. Medium-to-Long-term Feature Ideas & Modernization Roadmap (e.g., cross-institution support, optional tray apps, diagnostics).
4. Edge Case Handling (e.g., VPN clashes, sleep/wake network race conditions, captive portal session expirations, MAC address randomization).
5. Enterprise / Scalability Suggestions (if expanding beyond University of Moratuwa to other universities worldwide).

---

# UniNet Project Technical Report & Architectural Specification

## 1. Executive Summary & Core Philosophy

- **Project Name:** UniNet
- **Current Version:** `v1.2.4`
- **License:** MIT (Free & Open Source)
- **Target Institution:** University of Moratuwa (UoM), Sri Lanka
- **Primary Goal:** Eliminate repetitive, manual browser-based captive portal logins on university Wi-Fi across Linux, macOS, and Windows.
- **Repository:** https://github.com/dineTH2003-dev/uninet

### Non-Negotiable Engineering Principles:
1. **Zero External Dependencies:** 
   - Linux: Pure Bash 4.x + `curl` + `nmcli` (NetworkManager) + GNU coreutils.
   - macOS: Pure POSIX / Bash 3.2 + `curl` + `networksetup` + `airport`.
   - Windows: Pure PowerShell 5.1+ / .NET built-ins (`System.Net.HttpWebRequest`, `netsh`).
   - *No Python, no Node.js, no Go binaries, no external runtimes required.*
2. **0% Idle CPU & 0.0 MB Idle RAM:**
   - No continuously running daemon, no background polling loops, no timer intervals.
   - Purely event-driven: triggered strictly by OS network state transitions.
   - When not on campus Wi-Fi, the trigger exits in < 2ms without doing any network work.
3. **Zero Interruption / Silent Operation:**
   - Background execution must never spawn visible terminal windows, flash console dialogs, or interrupt the user.
4. **Resilient Portability:**
   - Works across varied Linux distributions (Ubuntu, Fedora, Arch, Debian, openSUSE), macOS versions, and Windows 10/11.

---

## 2. The Problem & Campus Network Environment

At the University of Moratuwa, Wi-Fi connectivity is segmented across faculties, libraries, and common areas using three distinct network setups and multi-vendor controller architectures:

| SSID | Hardware Vendor / Gateway | Auth Flow & Behavioral Nuance |
| :--- | :--- | :--- |
| **`UoM_Wireless`** | Cisco ISE / NEC WebAuth | Intercepts HTTP traffic. Requires synthetic form payload injection (`buttonClicked=4`) to bypass interstitial warnings. |
| **`UoM.Wireless`** | Aruba Networks Controller | Submits to `/cgi-bin/login`. Extracts session parameters (`mac`, `ip`, `essid`) embedded in the initial 302/307 redirect URL. Probes via `generate_204` can pass through prematurely, requiring verification against `http://connectivity-check.ubuntu.com./`. |
| **`UoM-Wireless`** | Ruijie Networks Portal | Secure captive portal operating over SSL/HTTPS on port 8443 (`:8443`). Requires URL path normalization from `/index.html` to `/login`. |

Connecting manually forces students to open a browser, trigger a dummy HTTP page (e.g. `neverssl.com`), get redirected to the gateway, and re-type student credentials multiple times per day whenever their laptop wakes from sleep or roams between access points.

---

## 3. Cross-Platform Event-Driven Integration

UniNet achieves zero idle CPU by integrating directly into native OS network lifecycle hooks:

### A. Linux (NetworkManager Dispatcher)
- **Hook Location:** `/etc/NetworkManager/dispatcher.d/99-uninet.sh`
- **Lifecycle Trigger:** Invoked automatically by NetworkManager on `up` and `connectivity-change` events.
- **Fast Exit:** Performs an immediate pure-Bash case check on `$1` (interface) and `$2` (action). If the connected SSID does not match `uom_wireless|uom.wireless|uom-wireless`, it terminates in ~2ms.
- **Settling Delay:** If an SSID matches, it forks into the background, allows DHCP routing and DNS to settle (1.5s), and executes `/usr/local/bin/uninet login --quiet`.

### B. macOS (`launchd` + Dynamic Store)
- **Hook Location:** `~/Library/LaunchAgents/com.uninet.autoconnect.plist`
- **Lifecycle Trigger:** Monitored via `launchd` using `WatchPaths` on `/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist` and `NetworkState` state changes.
- **Compatibility:** Built strictly to adhere to macOS's default Bash 3.2 syntax (no associative arrays, standard POSIX constructs).

### C. Windows (Task Scheduler + Windows Event Log)
- **Hook Location:** Windows Task Scheduler task: `\UniNet\UniNet-AutoConnect`
- **Triggers (Event IDs):**
  1. `Microsoft-Windows-NetworkProfile/Operational` — **Event ID 10000** (Network Connected).
  2. `Microsoft-Windows-WLAN-AutoConfig/Operational` — **Event ID 8001** (WLAN Interface Associated).
- **Session 0 Silent Execution:**
  - Registered under the `S-1-5-18` (`NT AUTHORITY\SYSTEM`) context or current user with `ExecutionTimeLimit = PT1M`.
  - Runs with `-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass` to completely prevent PowerShell console window popups.
- **CLI Global Wrapper:** Installs `uninet.cmd` alongside `uninet.ps1` in `C:\Program Files\UniNet` (or AppData) and binds to the system `PATH`.

---

## 4. Core Algorithms & Mechanisms

### A. The Two-Step Network Probe Pattern
Captive portals trap standard HTTP traffic and issue HTTP 302/307 redirects. UniNet dissects these using a two-step probe:
1. **Step 1: No-Follow Probe:**
   - Issues a lightweight HTTP GET to `http://connectivitycheck.gstatic.com/generate_204` with `--max-redirs 0` (no redirect following).
   - If HTTP 204 is returned: Internet is already fully active; exit immediately.
   - If HTTP 302/307 is returned: Captures the `Location:` header. This header contains essential gateway state parameters (client IP, gateway MAC, AP ID, authentication tokens).
2. **Step 2: Follow Redirect & Form Scraping:**
   - Resolves the redirected portal URL.
   - Extracts session cookies to an isolated cookie jar (`/tmp/uninet_cookies_$UID.txt` on Unix, session memory on Windows).
   - Scrapes HTML via regex to extract:
     - Form submission target (`<form action="...">`).
     - Dynamic hidden tokens (`<input type="hidden" name="..." value="...">` like CSRF tokens, `magic`, `dst`, etc.).
     - Input field identifiers for username and password.

### B. Multi-Vendor Payload Normalization
Before dispatching the POST authentication request:
- **Cisco ISE:** Injects `buttonClicked=4` into the payload.
- **Aruba ClearPass:** Extracts parameters from the redirect query string (`cmd`, `mac`, `ip`, `essid`, `url`) and attaches them to the POST body.
- **Ruijie:** Rewrites endpoint paths targeting port 8443 to the normalized `/login` URI.

### C. Smart AP Quality Optimizer (`uninet optimize` / `uninet scan`)
When moving across campus, devices frequently cling to weak 2.4 GHz access points (sticky client problem). UniNet implements a multi-factor AP quality scoring engine:

$$\text{Final Score} = (\text{Signal} \times 0.35) + \text{Band Bonus} + (\text{PHY Rate} \times 0.35) + \text{Active Stability Bonus}$$

Where:
- **Signal (Max 350 pts):** Direct percentage mapping of RSSI.
- **Band Bonus (300 pts):** Flat +300 points for 5 GHz / 6 GHz channels (prioritizing high throughput and lower congestion over raw 2.4 GHz range).
- **PHY Rate (Max 350 pts):** Negotiated link rate scaled linearly up to an 866 Mbps baseline.
- **Active Stability Bonus (120 pts):** Stability buffer awarded to the currently connected BSSID.
- **Hysteresis Threshold (15.0 pts / 150 raw points):** A candidate AP must outscore the active AP by at least **15.0 points** before UniNet initiates a roaming switch (`nmcli dev wifi connect <BSSID>`). This prevents connection flapping while sitting between two access points.

### D. Zero-Dependency Self-Updater & Update Cache
- Queries GitHub API (`/repos/dineTH2003-dev/uninet/releases/latest`) using pure Bash/PowerShell JSON parsing.
- Implements strict SemVer comparison (`is_newer_version`) to prevent accidental downgrades.
- **24-Hour Cache:** Status and scan checks cache the version check in `~/.config/uninet/update_check` with an epoch timestamp to eliminate 1-2s network lag during regular CLI operations.

---

## 5. Security & Credential Storage Architecture

- **Storage Locations:**
  - Linux/macOS: `~/.config/uninet/credentials.json` (User) and `/etc/uninet/credentials.json` (System Dispatcher).
  - Windows: `$env:ProgramData\UniNet\credentials.json` or `$env:USERPROFILE\.config\uninet\credentials.json`.
- **Permission Hardening:**
  - Stored with POSIX `chmod 600` permissions (readable/writable exclusively by owner).
  - On Windows, ACLs restrict access to `SYSTEM` and `Administrators`.
- **Design Rationale for Plain JSON:**
  - Campus captive portals inherently require cleartext username and password transmission over HTTP/HTTPS form submission.
  - Relying on external secret stores (e.g. `gnome-keyring`, `secret-tool`, `kwallet`, or Windows Credential Manager requiring interactive prompts) would break headless, non-interactive execution during system boot or sleep/wake events.
- **Sanitization:** Input escaping prevents shell injection and JSON syntax corruption when passwords contain quotes, slashes, or special characters.

---

## 6. Codebase Structure & Test Suite

```
uninet/
├── bin/
│   ├── uninet             # Main Linux CLI & Engine (Pure Bash 4.x, ~36 KB)
│   ├── uninet-macos       # macOS CLI & Engine (Bash 3.2 Compatible, ~28 KB)
│   └── uninet.ps1         # Windows PowerShell Engine (~40 KB)
├── scripts/
│   ├── linux/
│   │   ├── 99-uninet.sh   # NetworkManager Dispatcher Hook
│   │   └── uninet.service # Optional systemd fallback service
│   ├── macos/
│   │   └── com.uninet.autoconnect.plist # launchd LaunchAgent
│   └── windows/
│       ├── install.ps1    # Windows 1-line web installer & Task Scheduler setup
│       └── uninstall.ps1  # Windows clean uninstaller
├── tests/
│   └── test_simulation.sh # Local captive portal & optimization test runner
├── docs/
│   ├── architecture.md    # System design documentation
│   ├── portal-analysis.md # Reverse-engineering and DevTools inspection guide
│   └── development.md     # Contributor guide
├── install.sh             # Linux & macOS unified 1-line web installer
├── uninstall.sh           # Linux & macOS uninstaller
├── Makefile               # Test automation and syntax linting
└── VERSION                # Current release tag (1.2.4)
```

### Verification & Testing (`make test`):
The test suite spins up a lightweight local mock HTTP server that simulates:
- **Test 1:** Initial HTTP probe to captive portal (verifying 302 Redirect).
- **Test 2:** Redirect follow and regex form action resolution.
- **Test 3:** Simulated student credential POST submission.
- **Test 4:** Post-login probe verification (HTTP 204 validation).
- **Test 5:** Multi-factor AP quality scoring validation (5 GHz vs 2.4 GHz preference).
- **Test 6:** Hysteresis and flapping prevention threshold validation.
- **Test 7:** Multi-vendor hidden CSRF/Aruba token extraction.
- **Test 8:** Campus SSID discovery and priority auto-connect profile enforcement.

---

## 7. Current Strengths & Competitive Wins

1. **True Zero Dependencies:** Can be installed on a minimal, freshly-installed Linux distro, macOS, or Windows without installing any packages or runtime environments.
2. **Instant Setup:** 1-line terminal/PowerShell command installs background hooks, requests credentials, configures Wi-Fi priorities, and authenticates in under 10 seconds.
3. **No Battery Drain:** Zero idle polling processes running in the background.
4. **Flapping-Free Roaming:** AP quality scoring with hysteresis reliably moves users from slow 2.4 GHz legacy APs to high-speed 5 GHz APs without disruptive disconnect loops.

---

## 8. Current Limitations & Known Challenges

1. **Single-Institution Hardcoding:**
   - SSID detection patterns (`uom_wireless`, `uom.wireless`, `uom-wireless`) and vendor heuristics are optimized specifically for the University of Moratuwa.
2. **Plaintext Credential Storage:**
   - While protected by filesystem permissions (`0600`), passwords are saved in unencrypted JSON format on the local disk.
3. **Lack of Graphical Interface:**
   - Non-technical students unfamiliar with the Terminal or PowerShell occasionally struggle with installation or error diagnosis.
4. **Captive Portal Session Expirations:**
   - Some network controllers terminate sessions after 2 to 4 hours of continuous connection without dropping Wi-Fi association. Because the interface state does not change, the event-driven hook does not automatically fire until Wi-Fi is toggled or a connection dropped.
5. **MAC Address Randomization:**
   - Modern Windows and macOS versions enable Private Wi-Fi Addresses / Random MACs by default, which can invalidate active session tokens or confuse vendor controllers that bind credentials to a client MAC.

---

## 9. Key Questions & Topics for ChatGPT Review

Please review this specification and provide detailed feedback on:

1. **Institutional Scalability / Plugin Architecture:**
   - How can we refactor UniNet into a generic captive portal engine where universities across the globe can contribute their own YAML/JSON portal definitions without adding external runtimes?
2. **Credential Security Enhancements:**
   - Can we securely leverage native OS secret stores (e.g., Linux Secret Service / Keyring, macOS Keychain via `security`, Windows DPAPI via PowerShell) while preserving non-interactive, headless execution during boot/sleep wakeups?
3. **Session Expiry Detection without Polling:**
   - How can we detect captive portal timeouts (e.g. 2-hour idle timeouts) without running a battery-draining continuous polling loop?
4. **Lightweight GUI / Status Indicator Options:**
   - What is the most lightweight, dependency-free method to offer an optional tray icon or desktop notification (e.g., showing login status or AP score) across Linux, macOS, and Windows?
5. **Network Stack Edge Cases:**
   - How should UniNet handle conflicts with active VPN tunnels (e.g., WireGuard, OpenVPN, Cloudflare WARP) that block local portal redirection probes?
