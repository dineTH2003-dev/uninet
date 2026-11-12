# UniNet Phase 03.0 — macOS Compatibility & Architecture Audit

**Target Platform:** Apple macOS (OS X 10.15 Catalina through macOS 15 Sequoia)  
**Architectures:** Intel (`x86_64`) & Apple Silicon (`arm64` M1/M2/M3/M4)  
**Baseline Version:** `v1.2.4`  
**Audit Target:** [`bin/uninet-macos`](file:///home/dineth/dev/uninet/bin/uninet-macos), [`install.sh`](file:///home/dineth/dev/uninet/install.sh), [`uninstall.sh`](file:///home/dineth/dev/uninet/uninstall.sh), [`scripts/macos/com.uninet.autoconnect.plist`](file:///home/dineth/dev/uninet/scripts/macos/com.uninet.autoconnect.plist)  
**Status:** **READ-ONLY ENGINEERING AUDIT COMPLETED**

---

## 1. Executive Summary

UniNet provides a dedicated macOS implementation comprising a standalone shell script ([`bin/uninet-macos`](file:///home/dineth/dev/uninet/bin/uninet-macos), 811 lines) and a `launchd` job specification ([`scripts/macos/com.uninet.autoconnect.plist`](file:///home/dineth/dev/uninet/scripts/macos/com.uninet.autoconnect.plist)). 

While the script has historically passed syntax validation (`bash -n bin/uninet-macos`) on Linux and macOS GitHub Actions runners, **a deep engineering audit reveals fatal architectural defects, deprecated API dependencies, and runtime incompatibilities that prevent reliable, secure, and automatic operation on modern Mac computers.**

### Critical Audit Findings Overview:
1. **Bash 3.2 Fatal Runtime Incompatibility (DEF-01):** Line 257 in `bin/uninet-macos` uses negative array subscripting (`unset 'filtered_data[-1]'`), a feature introduced in Bash 4.3+. Default macOS ships with GNU Bash 3.2.57(1). On macOS, this produces a runtime syntax error (`bad array subscript`) during Cisco/NEC portal payload sanitization, aborting authentication.
2. **Apple Private `airport` CLI Removal in macOS 14/15 (DEF-02):** Lines 495–505 rely on `/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s` for Wi-Fi scanning and multi-factor AP quality scoring. Apple has deprecated and removed/disabled this private binary and its scanning capability in macOS Sonoma (14) and macOS Sequoia (15). Consequently, `uninet scan` and `uninet optimize` silently fail on all modern Macs.
3. **Background Wi-Fi Detection Failure via `launchd` `WatchPaths` (DEF-03):** The `com.uninet.autoconnect.plist` LaunchAgent monitors `/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist` and `NetworkInterfaces.plist`. Neither file is touched or modified when a Mac associates with an existing Wi-Fi network, reconnects, roams between APs, or wakes from sleep. Dynamic Wi-Fi association events occur exclusively in-memory inside `configd` (`SCDynamicStore`). Thus, **UniNet never wakes up or executes on campus arrival.**
4. **TCC / Location Services Restriction on SSID Queries in Sonoma & Sequoia (DEF-04):** In macOS 14 and 15, `networksetup -getairportnetwork` requires Location Services permission to return the active SSID. Without TCC authorization, it outputs `You are not associated with an AirPort network.` even while actively connected. In a headless `launchd` session, no TCC prompt can be displayed, permanently blinding UniNet.
5. **Plaintext Credential Storage in `~/.config/uninet/credentials.json` (DEF-05):** UniNet stores student passwords in unencrypted JSON, completely bypassing the native **macOS Keychain** (`/usr/bin/security`).
6. **Insecure SSL/TLS Verification and Missing Domain Whitelisting (DEF-06):** All HTTP requests use `curl -k` (`--insecure`), disabling SSL certificate validation and exposing credentials to rogue access points. Furthermore, there is zero domain whitelisting on form action URLs, allowing rogue portals to exfiltrate passwords to arbitrary domains.

---

## 2. macOS Codebase & Component Audit

### 2.1 File Map & Responsibilities

| File Path | Lines | Target OS Scope | Key Functions |
| :--- | :---: | :--- | :--- |
| [`bin/uninet-macos`](file:///home/dineth/dev/uninet/bin/uninet-macos) | 811 | macOS 10.15+ (Bash/Zsh) | CLI routing, SSID detection, captive portal negotiation, vendor payload injection, network quality scoring, updater. |
| [`scripts/macos/com.uninet.autoconnect.plist`](file:///home/dineth/dev/uninet/scripts/macos/com.uninet.autoconnect.plist) | 26 | macOS `launchd` | User LaunchAgent definition intended to trigger background authentication on network change. |
| [`install.sh`](file:///home/dineth/dev/uninet/install.sh) | 282 | macOS & Linux | Detects `Darwin`, copies binary to `~/.local/bin` and `/usr/local/bin`, installs LaunchAgent, sets network priority. |
| [`uninstall.sh`](file:///home/dineth/dev/uninet/uninstall.sh) | 73 | macOS & Linux | Unloads LaunchAgent, removes preferred wireless networks via `networksetup`, removes config. |

---

## 3. macOS Bash 3.2 Compatibility Analysis

Apple ceased updating GNU Bash after version 3.2.57(1)-release (2007) due to the GNU General Public License v3 (GPLv3). While macOS Catalina (10.15) switched the default interactive shell to Zsh, `/bin/bash` remains strictly Bash 3.2 on all modern macOS releases, including macOS 15 Sequoia.

### 3.1 Fatal Runtime Defect: Negative Array Subscripting
In [`bin/uninet-macos`](file:///home/dineth/dev/uninet/bin/uninet-macos#L248-L263), the Cisco/NEC WebAuth payload sanitization routine executes:

```bash
# bin/uninet-macos:248-263
for item in "${curl_data[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
        skip_next=0
        continue
    fi
    if [ "$item" = "--data-urlencode" ]; then
        filtered_data+=("$item")
    elif [[ "$item" == buttonClicked=* ]] || [[ "$item" == err_flag=1* ]]; then
        unset 'filtered_data[-1]'    # <--- FATAL IN BASH 3.2
        skip_next=0
    else
        filtered_data+=("$item")
    fi
done
```

#### Diagnostic Evaluation:
- **Bash 4.3+ Behavior:** Negative array indices (`[-1]`) index from the end of the array, successfully unsetting the last element.
- **macOS Bash 3.2 Behavior:**
  ```text
  bash: unset: [filtered_data[-1]]: bad array subscript
  ```
- **Operational Impact:** When a student connects to `UoM_Wireless` (Cisco/NEC), Bash throws a runtime error. Depending on shell error trapping, the script either crashes or leaves corrupted arguments in `curl_data`, causing authentication rejection by the campus gateway.
- **Why CI Missed It:** The GitHub Actions workflow (`Lint & Syntax Check (macOS)`) executes `bash -n bin/uninet-macos`. Static syntax checking (`-n`) only validates parser tokens and grammar; it **never evaluates runtime array indexing**.

### 3.2 Subshell and Process Substitution Behavior
In [`bin/uninet-macos`](file:///home/dineth/dev/uninet/bin/uninet-macos#L210-L221):
```bash
while IFS='=' read -r h_name h_val; do
    ...
done < <(echo "$probe_output" | grep -i -o '<input[^>]*>' | while read -r tag; do ...)
```
Process substitution (`<(...)`) is supported in Bash 3.2 on macOS via named pipes (`/dev/fd/N`). However, nested process substitution inside a while-loop spawned under `launchd` without an active TTY can suffer from SIGPIPE or file descriptor exhaustion if `probe_output` contains large HTML chunks.

---

## 4. macOS Networking Utilities & API Audit

### 4.1 Wi-Fi Interface Discovery (`get_wifi_interface`)
```bash
get_wifi_interface() {
    networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}' | head -n 1 || echo "en0"
}
```
- **Evaluation:** **FUNCTIONAL ON MACBOOKS**.
- On MacBooks (MacBook Pro, MacBook Air), the internal Wi-Fi NIC is consistently indexed as `en0`.
- On desktop Macs (Mac Studio, Mac Pro, Mac mini) equipped with dual 10GbE interfaces, Wi-Fi is frequently assigned to `en1` or `en2`. The `awk` parser correctly inspects hardware ports and extracts the interface matching `Wi-Fi` or `AirPort`, with a safe fallback to `en0`.

### 4.2 Active SSID Retrieval (`get_active_ssid`)
```bash
get_active_ssid() {
    local iface
    iface="$(get_wifi_interface)"
    networksetup -getairportnetwork "$iface" 2>/dev/null | awk -F': ' '{print $2}' || true
}
```
- **Evaluation:** **BROKEN ON macOS 14 SONOMA & macOS 15 SEQUOIA (TCC PRIVACY BARRIER)**.
- **Behavior on macOS 10.15–13:** Outputs `Current Wi-Fi Network: UoM_Wireless`, parsed to `UoM_Wireless`.
- **Behavior on macOS 14+:** Apple classified Wi-Fi SSID and BSSID as location-revealing metadata under the CoreLocation / TCC privacy framework.
  - If the calling process (e.g. Terminal, iTerm2, or `launchd`) does not have Location Services enabled in `System Settings > Privacy & Security > Location Services`, `networksetup -getairportnetwork` returns:
    ```text
    You are not associated with an AirPort network.
    ```
  - When this occurs while connected to `UoM_Wireless`, `bin/uninet-macos` line 128 evaluates the output as disconnected, prints `"Not connected to Wi-Fi"`, and terminates with `exit 0`.
  - In a background `launchd` LaunchAgent, the process is non-interactive and headless; macOS will **never** display a prompt requesting Location permission, resulting in permanent silent failure.

### 4.3 Deprecated & Removed `airport` Binary (`scan_networks_macos`)
```bash
local airport_cmd="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
```
- **Evaluation:** **DEFUNCT / UNSUPPORTED ON MODERN macOS**.
- Apple has marked the private `Apple80211.framework` as legacy:
  - In macOS 14.4+, scanning via `airport -s` was restricted to root/system processes.
  - In macOS 15 Sequoia, `/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport` was completely stripped of its scanning interface or removed entirely.
- Calling `airport_cmd -s` returns an empty string or error, causing `scan_networks_macos` to return null.
- Consequently:
  - `uninet scan` reports `"No Wi-Fi networks found."`
  - `uninet optimize` reports `"No university networks detected in range."` and cannot perform AP candidate evaluation or band steering.

### 4.4 Network Preferred Profile Registration (`cmd_trust_networks`)
```bash
networksetup -addpreferredwirelessnetworkatindex "$iface" "$ssid" 0 OPEN 2>/dev/null
```
- **Evaluation:** **PARTIALLY FUNCTIONAL**.
- Successfully inserts `UoM_Wireless`, `UoM.Wireless`, and `UoM-Wireless` at index 0 of the preferred networks list in `com.apple.airport.preferences.plist`.
- However, on macOS Ventura (13), Sonoma (14), and Sequoia (15), modifying preferred wireless networks without prior administrative elevation or outside an interactive session may fail or be ignored by `WiFiAgent` unless executed with appropriate permissions.

---

## 5. Platform Architecture Differences: Intel vs Apple Silicon

| Engineering Factor | Intel Mac (`x86_64`) | Apple Silicon Mac (`arm64`) | UniNet Compatibility Assessment |
| :--- | :--- | :--- | :--- |
| **Binary Architecture** | Interpreted Bash script | Interpreted Bash script | Compatible; bash runs natively on both architectures without Rosetta 2. |
| **System Binary Path** | `/usr/local/bin` | `/usr/local/bin` / `/opt/homebrew/bin` | **PARTIAL RISK**: Standard Apple Silicon installations prioritize `/opt/homebrew/bin` in user PATH. `install.sh` places binaries in `~/.local/bin` and `/usr/local/bin`. If `/usr/local/bin` is absent from user PATH, CLI invocation fails. |
| **LaunchAgent Execution** | Supported in user domain | Supported in user domain | Identical behavior under `launchd`. |
| **Hardware Enclave (Secure Enclave)** | Available on T2 security chip | Standard across all M-series chips | UniNet currently uses neither; credentials are in plaintext. |

---

## 6. Deprecated Commands & Unsupported APIs

1. **`launchctl load` / `launchctl unload`**:
   - [`install.sh:235-236`](file:///home/dineth/dev/uninet/install.sh#L235-L236) and [`uninstall.sh:25`](file:///home/dineth/dev/uninet/uninstall.sh#L25) execute `launchctl load` and `launchctl unload`.
   - Apple deprecated `load` and `unload` in OS X 10.11 El Capitan.
   - The modern command syntax is `launchctl bootstrap gui/$UID <plist>` and `launchctl bootout gui/$UID/<label>`.
   - While legacy subcommands still function as aliases in macOS 14/15, Apple logs deprecation warnings in the unified system log (`OSLog`).
2. **`airport -s` (Network Scanning)**:
   - Completely unsupported on macOS 15 Sequoia.
3. **`networksetup -setairportnetwork`**:
   - In modern macOS, switching Wi-Fi networks programmatically without user intervention is heavily restricted by `WiFiAgent`.

---

## 7. Credential Storage & Security Posture Audit

### 7.1 Plaintext Credentials in `~/.config/uninet/credentials.json`
[`bin/uninet-macos:424-430`](file:///home/dineth/dev/uninet/bin/uninet-macos#L424-L430) stores student credentials as:
```json
{
  "username": "student_id",
  "password": "plaintext_password"
}
```
- Permissions are set to `chmod 600`.
- **Security Vulnerability:** This exposes student university credentials to:
  1. Any process running under the same user UID (e.g. third-party electron apps, browser extensions with local file read permissions).
  2. Unencrypted Time Machine backups or iCloud Drive syncing (if `~/.config` is inadvertently synced).
  3. Memory scanning or disk forensics.
- **Missing macOS Integration:** macOS provides `/usr/bin/security`, which interacts directly with the **macOS Keychain**. On Windows, UniNet secured credentials using DPAPI `CurrentUser` encryption. On macOS, no equivalent cryptographic protection is implemented.

---

## 8. Captive Portal Authentication Lifecycle Audit

```
[SSID Check] ──────► [Probe 204] ──────► [HTML Redirect] ──────► [Form Extraction] ──────► [POST Credentials] ──────► [Post-Login 204]
   CRITICAL             PASS                 PASS                   CRITICAL                  CRITICAL                 PASS
TCC blocks SSID       gstatic               Follows                 Missing                 -k Insecure;             Verifies
in macOS 14/15        probe                Redirects              Untrusted Form            Bash 3.2 array           gateway state
                                                                   Action Guard             crash on Cisco
```

### 8.1 Critical Flaws in the Authentication Lifecycle:
1. **Insecure SSL/TLS (`curl -k`)**:
   - Lines 167, 187, and 300 execute `curl -k` (`--insecure`).
   - This disables all X.509 certificate validation, hostname validation, and authority checking.
   - Any attacker hosting a rogue Wi-Fi AP (`UoM_Wireless` evil twin) with a self-signed certificate can intercept the POST request and capture student passwords in cleartext.
2. **Missing Untrusted Form Action Guardrail**:
   - Lines 195–202 extract the `<form action="...">` target and resolve it.
   - Unlike the Windows implementation (Phase 02.2/02.3 Test 15), there is **zero domain whitelisting**.
   - If a malicious landing page specifies `<form action="https://evil-attacker.com/steal">`, UniNet will post student credentials directly to the external server.
3. **Cookie Jar Race Condition**:
   - Cookie storage is hardcoded to `/tmp/uninet_cookies_$UID.txt`.
   - Because `/tmp` is shared across all processes, file collision or symlink attacks are possible.

---

## 9. Logging & Diagnostics Audit

1. **Terminal-Centric Output**:
   - `bin/uninet-macos` formats output using ANSI escape sequences (`\033[36m`).
   - When executed by `launchd`, escape sequences are dumped verbatim into `/tmp/uninet.log`.
2. **Insecure Log Paths**:
   - `com.uninet.autoconnect.plist` sets `StandardOutPath` to `/tmp/uninet.log` and `StandardErrorPath` to `/tmp/uninet.err`.
   - `/tmp` is world-writable on macOS. A local attacker can create a symlink from `/tmp/uninet.log` to an arbitrary user file, resulting in unauthorized file overwrite when `uninet` runs.
3. **No Log Size Management**:
   - UniNet lacks log rotation on macOS. Over months of background execution, `/tmp/uninet.log` will grow continuously until the next system reboot purges `/tmp`.

---

## 10. Audit Conclusion

The current macOS implementation in `bin/uninet-macos` and `scripts/macos/` **cannot operate reliably or securely on a real Mac**. It contains severe blocking defects:
- Crashes on Cisco/NEC portals due to Bash 3.2 syntax errors.
- Fails background triggering due to inert `launchd` `WatchPaths`.
- Fails SSID detection on macOS 14/15 due to TCC location restrictions.
- Stores credentials in plaintext and disables SSL certificate validation.

Detailed background automation and security analysis follows in [`docs/PHASE_03_0_MACOS_AUTOMATION_SECURITY.md`](file:///home/dineth/dev/uninet/docs/PHASE_03_0_MACOS_AUTOMATION_SECURITY.md).
