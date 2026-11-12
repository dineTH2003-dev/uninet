# UniNet Phase 03.0 — macOS Background Automation & Security Deep Dive

**Target Platform:** Apple macOS 10.15 Catalina through macOS 15 Sequoia  
**Component Focus:** `launchd`, `configd`, `SCDynamicStore`, `TCC / CoreLocation`, `Keychain`, `Captive Network Assistant (CNA)`  
**Deliverable Type:** Architectural Engineering Analysis & Vulnerability Report  
**Status:** **READ-ONLY ENGINEERING AUDIT COMPLETED**

---

## 1. Background Automation Architecture: `launchd` Deep Dive

UniNet configures macOS background execution through a single launch job specification: [`scripts/macos/com.uninet.autoconnect.plist`](file:///home/dineth/dev/uninet/scripts/macos/com.uninet.autoconnect.plist).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.uninet.autoconnect</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/uninet</string>
        <string>login</string>
        <string>--quiet</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist</string>
        <string>/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/uninet.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/uninet.err</string>
</dict>
</plist>
```

---

## 2. The `WatchPaths` Myth vs. macOS Networking Reality

### 2.1 The Architectural Assumption
The author of `com.uninet.autoconnect.plist` assumed that when a MacBook associates with a Wi-Fi network, macOS updates `/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist` or `NetworkInterfaces.plist`, causing `launchd` to detect the filesystem modification and launch `uninet login --quiet`.

### 2.2 The Operating System Reality
macOS handles network state transitions through **`configd`** and **`SCDynamicStore`** (SystemConfiguration Dynamic Store):

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   macOS KERNEL / DRIVER                                │
│                              (AirPort_BrcmNIC / AppleBCMWLAN)                          │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ 802.11 Association / Roaming Event
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                       configd (System Configuration Daemon)                            │
│                                           │                                            │
│  ┌────────────────────────────────────────┴─────────────────────────────────────────┐  │
│  │                     SCDynamicStore (In-Memory Key-Value IPC)                     │  │
│  │  State:/Network/Interface/en0/AirPort                                            │  │
│  │  State:/Network/Global/IPv4                                                      │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
│                                           │                                            │
│  ┌────────────────────────────────────────▼─────────────────────────────────────────┐  │
│  │  SCPreferences (On-Disk Static Configuration)                                    │  │
│  │  /Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist    │  │
│  │  (MODIFIED ONLY when a user adds, reorders, or deletes preferred networks)       │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

1. **`com.apple.airport.preferences.plist` is Static:**
   - This file stores *persisted preferences* (the ordered list of known SSIDs, remembered security types, auto-join flags).
   - When a MacBook roams between access points on `UoM_Wireless` or connects to an existing preferred network, **`configd` DOES NOT write to this file.**
   - Writing to disk on every connection or signal fluctuation would cause excessive SSD flash wear on MacBooks.
2. **`NetworkInterfaces.plist` is Hardware-Only:**
   - This file records *physical and virtual network interfaces* (e.g. `en0` = Wi-Fi, `en1` = Thunderbolt).
   - It is written strictly when hardware interfaces are initialized during macOS installation or when external Thunderbolt/USB network adapters are plugged in.
   - It is **never** touched during wireless connection, disconnection, or roaming.

### 2.3 Verdict on `WatchPaths`
**`WatchPaths` will NEVER fire upon Wi-Fi connection, campus arrival, AP roaming, or wake from sleep.**
The LaunchAgent is completely dormant during normal daily student use.

---

## 3. Automation Lifecycle Audit Across Real-World Scenarios

| Operational Scenario | Expected Behavior | Actual Behavior in Existing Code | Status |
| :--- | :--- | :--- | :---: |
| **1. User Logs In** | Run portal check; authenticate if campus Wi-Fi is connected. | `RunAtLoad` fires immediately at second 0. Wi-Fi has not finished DHCP / 802.11 handshake. `get_active_ssid` returns empty. `--quiet` flag triggers immediate `exit 0`. Authentication never occurs. | **FAILED** |
| **2. Enters Campus / Wi-Fi Connects** | Detect `UoM_Wireless` association; automatically trigger captive portal login. | No trigger fires. `com.apple.airport.preferences.plist` is untouched. UniNet remains dormant. User has no internet until opening Terminal manually. | **FAILED** |
| **3. Disconnects & Reconnects** | Re-probe gateway; re-authenticate if session expired. | No trigger fires. UniNet remains dormant. | **FAILED** |
| **4. Wakes from Sleep** | Detect wake event; verify connectivity; authenticate if session dropped. | `launchd` provides zero wake-from-sleep triggers for LaunchAgents. No execution occurs. | **FAILED** |
| **5. Roams Between Campus APs** | Re-evaluate AP quality; re-verify authentication token. | No trigger fires. UniNet remains dormant. | **FAILED** |

---

## 4. LaunchAgent vs. LaunchDaemon Selection

### 4.1 Current Choice: User LaunchAgent (`~/Library/LaunchAgents`)
- **Execution Domain:** `gui/$UID` (User Desktop Session).
- **Security Context:** Runs as the logged-in student user.
- **Advantages:**
  - Has direct access to the user's home directory (`~/.config/uninet`).
  - Capable of interacting with the user's login Keychain (`login.keychain-db`).
  - Does not require ongoing root privileges.
- **Disadvantages:**
  - Hardcoded binary path: Plist targets `/usr/local/bin/uninet`. If installed to `~/.local/bin/uninet` (because sudo was declined during `install.sh`), `launchd` fails with exit code 127 (`No such file or directory`).
  - Terminal-less execution: Any error outputs to `/tmp/uninet.err` with zero student visibility.

### 4.2 Alternative: System LaunchDaemon (`/Library/LaunchDaemons`)
- **Execution Domain:** System root (`system`).
- **Disadvantages:**
  - Runs as `root`, violating the Principle of Least Privilege.
  - Cannot access the user's unlocked Login Keychain without complex IPC.
  - Cannot easily determine which GUI user is active if fast user switching is used.
- **Architecture Decision:** **LaunchAgent is the correct domain**, but the triggering mechanism must be completely overhauled from passive filesystem watching to an active event listener or system dynamic store monitor.

---

## 5. macOS Security Architecture & Compatibility Audit

```
┌────────────────────────────────────────────────────────────────────────┐
│                        macOS SECURITY STACK                            │
├────────────────────────────────┬───────────────────────────────────────┤
│ System Integrity Protection    │ PASS: UniNet lives in user space      │
├────────────────────────────────┼───────────────────────────────────────┤
│ Gatekeeper & Notarization      │ PARTIAL: Blocked if downloaded via UI │
├────────────────────────────────┼───────────────────────────────────────┤
│ TCC / Location Privacy         │ CRITICAL DEFECT: Blocks SSID queries  │
├────────────────────────────────┼───────────────────────────────────────┤
│ macOS Keychain Integration     │ CRITICAL DEFECT: Stored in plaintext  │
├────────────────────────────────┼───────────────────────────────────────┤
│ Captive Network Assistant(CNA) │ CONFLICT: Apple sheet races with curl │
├────────────────────────────────┼───────────────────────────────────────┤
│ SSL/TLS Verification           │ CRITICAL DEFECT: curl -k (Insecure)   │
└────────────────────────────────┴───────────────────────────────────────┘
```

---

## 6. Privacy & TCC Barrier: Location Services for Wi-Fi SSID

### 6.1 The Sonoma (14) & Sequoia (15) TCC Privacy Lockout
In macOS 14 Sonoma and macOS 15 Sequoia, Apple hardened the `CoreWLAN` framework and `networksetup` CLI:
- **Privacy Rationale:** A device's active BSSID and SSID can be mapped against public geolocation databases (e.g. Apple Wi-Fi Location Services / Skyhook) to pinpoint a user's exact physical coordinates with high precision.
- **Enforcement:**
  - Calling `networksetup -getairportnetwork <iface>` or querying `CWWiFiClient` requires the calling process or its parent application to hold **Location Services authorization**.
  - If the calling application (e.g., Terminal, or a headless background process spawned by `launchd`) does NOT possess Location Services approval:
    ```text
    $ networksetup -getairportnetwork en0
    You are not associated with an AirPort network.
    ```
- **Consequence for UniNet:**
  - Even when the student's MacBook is actively connected to `UoM_Wireless`, `get_active_ssid` returns empty or the `"not associated"` string.
  - `bin/uninet-macos:128` treats this as disconnected and terminates immediately.
  - In a background `launchd` LaunchAgent, the process has no UI window or bundle identifier. macOS **never prompts the user** for permission, resulting in a permanent, silent failure loop.

---

## 7. Credential Storage: Plaintext vs. macOS Keychain

### 7.1 Existing Vulnerability
UniNet stores credentials at `~/.config/uninet/credentials.json`:
```json
{
  "username": "student_id",
  "password": "cleartext_password"
}
```
While permissions are set to `chmod 600`, this design fails to meet basic macOS security standards:
- Any process running under the user's UID can read the file.
- Unencrypted backups (Time Machine without FileVault, iCloud Drive sync) expose credentials.
- In contrast to Windows (which uses DPAPI `CurrentUser` encryption), macOS has zero cryptographic protection for student credentials.

### 7.2 Native macOS Solution: macOS Keychain (`/usr/bin/security`)
macOS provides a native, pre-installed command-line interface to the Keychain:
- **Save Credential:**
  ```bash
  security add-generic-password -a "$username" -s "UniNet" -w "$password" -U
  ```
- **Retrieve Password:**
  ```bash
  security find-generic-password -s "UniNet" -w
  ```
- **Retrieve Username:**
  ```bash
  security find-generic-password -s "UniNet" | grep '"acct"<blob>=' | cut -d'"' -f4
  ```
- **Delete Credential:**
  ```bash
  security delete-generic-password -s "UniNet"
  ```
The Keychain encrypts passwords with AES-256 using keys managed by the macOS Secure Enclave (Apple Silicon) or T2 Security Chip, unlocked automatically when the user logs into their Mac desktop.

---

## 8. Captive Network Assistant (CNA) Coexistence

### 8.1 Apple CNA Behavior
When a Mac associates with an open university Wi-Fi network:
1. `captiveagent` probes `http://captive.apple.com/hotspot-detect.html`.
2. The university gateway intercepts the probe and returns a redirect (HTTP 302 or HTML meta-refresh).
3. macOS immediately spawns `/System/Library/CoreServices/Captive Network Assistant.app` (the modal login web sheet).
4. **The Collision:**
   - While CNA is open, the Mac's networking stack restricts non-CNA traffic or isolates the Wi-Fi interface.
   - If UniNet attempts to authenticate via background `curl` while CNA is active:
     - `curl` and CNA compete for gateway session states.
     - Even if UniNet successfully posts credentials, the CNA window remains stranded on screen with an incomplete browser state until manually dismissed by the student.

---

## 9. Gatekeeper, XProtect, & Notarization

1. **CLI Script Execution:**
   - `bin/uninet-macos` is a plain text script. It is interpreted by `/bin/bash` or `/bin/zsh`.
   - Scripts executed directly via shell are not blocked by Gatekeeper.
2. **Quarantine Flag (`com.apple.quarantine`):**
   - If a student downloads a zip/tarball of UniNet via Safari or Chrome, macOS attaches the `com.apple.quarantine` extended attribute.
   - Running an unnotarized binary extracted from such an archive triggers a Gatekeeper alert (`"uninet" cannot be opened because it is from an unidentified developer`).
   - The curl-based installation (`curl ... | bash`) avoids quarantine flags because `curl` in Terminal does not attach quarantine xattrs.

---

## 10. Antivirus, EDR, Firewall, and VPN Interference

1. **Enterprise Endpoint Security (CrowdStrike Falcon, Microsoft Defender for Mac, SentinelOne):**
   - EDR agents monitor `/tmp` and detect unencrypted credentials stored in plaintext JSON files (`credentials.json`).
   - Plaintext credentials matching corporate/university formats trigger Data Loss Prevention (DLP) alerts.
2. **macOS Application Firewall (`socketfilterfw`):**
   - Outbound HTTP POST requests from standard CLI utilities (`curl`) are permitted by default.
3. **VPN & Split-Tunneling:**
   - If a student has an active VPN with a "Kill Switch" or full-tunnel configuration (e.g. Cisco AnyConnect, GlobalProtect), captive portal DNS queries and HTTP redirects to local gateways (`10.x.x.x` or `172.x.x.x`) are dropped, causing authentication to time out.

---

## 11. Conclusion

Background automation and credential security on macOS are currently **NON-FUNCTIONAL and VULNERABLE**:
- `WatchPaths` will never fire on campus Wi-Fi arrival.
- TCC location restrictions break SSID queries on macOS 14 and 15.
- Credentials lack Keychain protection.
- CNA modal sheet conflicts with headless authentication.

The complete capability matrix and grading are provided in [`docs/PHASE_03_0_MACOS_TEST_MATRIX.md`](file:///home/dineth/dev/uninet/docs/PHASE_03_0_MACOS_TEST_MATRIX.md).
