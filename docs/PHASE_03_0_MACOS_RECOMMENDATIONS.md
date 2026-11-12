# UniNet Phase 03.0 — macOS Engineering Recommendations & Defect Register

**Target Platform:** Apple macOS 10.15 Catalina through macOS 15 Sequoia  
**Deliverable Type:** Defect Register, Remediation Blueprint & Final Certification Decision  
**Baseline Version:** `v1.2.4`  
**Status:** **READ-ONLY AUDIT COMPLETE — REMEDIATIONS SPECIFIED**

---

## 1. Prioritized Defect Register

| Defect ID | Severity | Component | Issue Description | Operational Impact |
| :--- | :---: | :--- | :--- | :--- |
| **DEF-01** | **CRITICAL** | `bin/uninet-macos:257` | Negative array subscript `unset 'filtered_data[-1]'` unsupported in macOS Bash 3.2. | Cisco/NEC portal authentication crashes with runtime syntax error. |
| **DEF-02** | **CRITICAL** | `scripts/macos/com.uninet.autoconnect.plist` | `WatchPaths` monitors static preference plists that never update on Wi-Fi association or roaming. | UniNet **never** automatically triggers on campus arrival, connection, or wake from sleep. |
| **DEF-03** | **CRITICAL** | `bin/uninet-macos:54` | `networksetup -getairportnetwork` blocked by TCC Location Services on macOS 14/15. | Returns `"You are not associated..."`; headless background agent permanently blinded. |
| **DEF-04** | **HIGH** | `bin/uninet-macos:424` | Credentials stored in unencrypted JSON in `~/.config/uninet/credentials.json`. | Plaintext passwords exposed to user-space malware, DLP scanners, and unencrypted backups. |
| **DEF-05** | **HIGH** | `bin/uninet-macos:495` | Reliance on `/System/Library/.../airport -s` for Wi-Fi scanning. | Defunct and removed in macOS 15; `scan` and `optimize` fail silently. |
| **DEF-06** | **HIGH** | `bin/uninet-macos:167,187,300` | Universal `curl -k` (`--insecure`) usage. | Completely disables TLS validation, exposing students to rogue evil-twin AP MITM credential theft. |
| **DEF-07** | **HIGH** | `bin/uninet-macos:195` | Missing untrusted form action destination guardrail. | Rogue portals can exfiltrate student credentials to external phishing servers. |
| **DEF-08** | **MEDIUM** | System Coexistence | Lack of coordination with Apple Captive Network Assistant (CNA). | CNA web sheet pops up and races against background `curl`, locking network routing. |
| **DEF-09** | **MEDIUM** | `com.uninet.autoconnect.plist` | Log paths hardcoded to world-writable `/tmp` without rotation. | Local symlink vulnerabilities and unbounded log disk consumption. |
| **DEF-10** | **LOW** | `bin/uninet-macos:778` | In-app `uninstall` command fails to unload or delete LaunchAgent plist. | Stale LaunchAgent persists after student uninstalls via CLI. |

---

## 2. Concrete Architectural Remediations

### Remediation for DEF-01: Bash 3.2 Safe Array Manipulation
**Issue:** `unset 'filtered_data[-1]'` fails on macOS default `/bin/bash` (3.2.57).  
**Correction:** Replace negative indexing with portable length calculation:
```bash
# Before:
unset 'filtered_data[-1]'

# After (POSIX / Bash 3.2 Compatible):
local last_idx=$((${#filtered_data[@]} - 1))
if [ "$last_idx" -ge 0 ]; then
    unset 'filtered_data[last_idx]'
fi
```

---

### Remediation for DEF-02: Event-Driven Background Wi-Fi Detection
**Issue:** `launchd` `WatchPaths` on `com.apple.airport.preferences.plist` does not detect Wi-Fi connection or waking from sleep.  
**Solution Options:**
1. **Option A (Pure Native SCDynamicStore Monitor via scutil):**
   Run a persistent, lightweight event loop LaunchAgent that subscribes to `SCDynamicStore` notifications:
   ```bash
   scutil --monitor << 'EOF' | while read -r line; do
   # Watch for changes in primary IPv4 or Wi-Fi state
   n.add State:/Network/Global/IPv4
   n.add State:/Network/Interface/en0/AirPort
   n.watch
   EOF
       # Debounce and trigger uninet login --quiet
       /usr/local/bin/uninet login --quiet
   done
   ```
2. **Option B (Watch `/etc/resolv.conf` with ThrottleInterval):**
   When DHCP assigns an IP address on campus, `configd` writes new DNS nameservers to `/var/run/resolv.conf` (symlinked as `/etc/resolv.conf`).
   Monitoring `/etc/resolv.conf` via `WatchPaths` fires reliably on DHCP acquisition, paired with `<key>ThrottleInterval</key><integer>5</integer>` to prevent rapid flapping.

---

### Remediation for DEF-03: Resolving TCC / Location Privacy Barrier
**Issue:** On macOS 14 Sonoma and macOS 15 Sequoia, `networksetup -getairportnetwork` requires Location Services. Without it, it outputs `"You are not associated with an AirPort network."`.  
**Correction:** Implement a resilient multi-tier network detection cascade:
```bash
get_active_ssid() {
    local iface
    iface="$(get_wifi_interface)"

    # Tier 1: Try networksetup (functional on macOS 10.15–13, or if Location is granted)
    local ssid
    ssid="$(networksetup -getairportnetwork "$iface" 2>/dev/null | awk -F': ' '{print $2}' || true)"
    if [ -n "$ssid" ] && [ "$ssid" != "You are not associated with an AirPort network." ]; then
        echo "$ssid"
        return
    fi

    # Tier 2: Check default gateway IP / DNS domain via scutil/network
    # On UoM campus, DHCP domain is typically uom.lk or default gateway matches campus subnets
    local domain
    domain="$(scutil --dns 2>/dev/null | awk '/domain\[0\]/{print $3; exit}' || true)"
    if [[ "$domain" == *"uom.lk"* ]]; then
        echo "UoM_Wireless" # Fallback to primary campus profile
        return
    fi

    # Tier 3: Probe captive gateway IP
    local gateway_ip
    gateway_ip="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}' || true)"
    if [ -n "$gateway_ip" ] && ! is_online; then
        # Check if gateway responds with UoM captive portal signatures
        local probe_sig
        probe_sig="$(curl -s -m 2 "http://$gateway_ip" 2>/dev/null || true)"
        if [[ "$probe_sig" =~ (uom|moratuwa|WebAuth|Aruba) ]]; then
            echo "UoM_Wireless"
            return
        fi
    fi

    echo ""
}
```

---

### Remediation for DEF-04: macOS Keychain Integration
**Issue:** Passwords stored in plaintext JSON in `~/.config/uninet/credentials.json`.  
**Correction:** Migrate credential storage to `/usr/bin/security` (macOS Keychain):

```bash
# Save to macOS Keychain
store_credentials_keychain() {
    local username="$1"
    local password="$2"
    security add-generic-password -a "$username" -s "UniNet" -w "$password" -U
}

# Retrieve from macOS Keychain
get_credentials_keychain() {
    USERNAME="$(security find-generic-password -s "UniNet" 2>/dev/null | awk -F'"' '/acct/{print $4}' || true)"
    PASSWORD="$(security find-generic-password -s "UniNet" -w 2>/dev/null || true)"
    [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]
}

# Purge on uninstall
purge_credentials_keychain() {
    security delete-generic-password -s "UniNet" 2>/dev/null || true
}
```

---

### Remediation for DEF-06 & DEF-07: Hardening TLS and Form Guardrails
**Issue:** `curl -k` permits HTTPS MITM; forms lack destination domain validation.  
**Correction:**
1. Restrict `curl -k` strictly to the initial captive portal detection probe (since portals hijack unauthenticated TLS).
2. For institutional authentication endpoints (`connect.uom.lk:8443`), enforce strict CA validation:
   ```bash
   if [[ "$action_url" == *"connect.uom.lk"* ]]; then
       # Enforce strict system keychain TLS verification
       curl --fail --silent --show-error ...
   fi
   ```
3. Enforce strict domain whitelisting on form actions:
   ```bash
   local action_host
   action_host="$(echo "$action_url" | grep -o -E 'https?://[^/?#:]+' | sed -E 's|https?://||')"
   if [[ "$action_host" != *"uom.lk"* ]] && \
      ! [[ "$action_host" =~ ^10\. ]] && \
      ! [[ "$action_host" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && \
      ! [[ "$action_host" =~ ^192\.168\. ]]; then
       log "${RED}Security Alert: Form action points to untrusted external host '$action_host'. Aborting.${RESET}"
       exit 1
   fi
   ```

---

### Remediation for DEF-08: Captive Network Assistant (CNA) Coexistence
**Issue:** Apple CNA web sheet locks the interface.  
**Correction:**
Once UniNet finishes submitting credentials, probe `http://captive.apple.com/hotspot-detect.html`. When Apple's probe returns `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>`, `captiveagent` automatically dismisses the modal CNA sheet.

---

### Remediation for DEF-09 & DEF-10: Plist Paths and Uninstaller Parity
1. Update `com.uninet.autoconnect.plist`:
   ```xml
   <key>StandardOutPath</key>
   <string>/Users/SHARED_OR_HOME/Library/Logs/uninet.log</string>
   <key>StandardErrorPath</key>
   <string>/Users/SHARED_OR_HOME/Library/Logs/uninet.err</string>
   ```
2. In `bin/uninet-macos` `uninstall` case (line 778), add:
   ```bash
   local plist="$HOME/Library/LaunchAgents/com.uninet.autoconnect.plist"
   if [ -f "$plist" ]; then
       launchctl bootout "gui/$UID" "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
       rm -f "$plist"
   fi
   purge_credentials_keychain
   ```

---

## 3. Final Certification Question & Evidence-Based Answer

### Question:
> **"Can UniNet operate automatically, securely and reliably on a normal MacBook without users manually executing terminal commands?"**

### Formal Answer:
# **NO. In its current implementation, UniNet CANNOT operate automatically, securely, or reliably on a normal MacBook.**

### Grounded Technical Evidence:
1. **Automation Fails Completely (DEF-02 & DEF-03):**
   - The LaunchAgent's `WatchPaths` monitors files that macOS never modifies when Wi-Fi connects or when a laptop wakes from sleep.
   - On macOS 14 Sonoma and 15 Sequoia, TCC Location Services blocks SSID discovery in headless background sessions.
   - A student arriving on campus will receive **zero background execution**. They must manually open Terminal and execute `uninet login` to connect.
2. **Crashes on Cisco Networks Under Standard macOS Shell (DEF-01):**
   - Default macOS ships with GNU Bash 3.2.57.
   - Line 257 in `bin/uninet-macos` uses negative array subscripting (`unset 'filtered_data[-1]'`), causing an immediate fatal shell error (`bad array subscript`) during `UoM_Wireless` authentication.
3. **Severe Security Posture Deficiencies (DEF-04, DEF-06, DEF-07):**
   - Student passwords are saved in unencrypted plaintext in `~/.config/uninet/credentials.json`, bypassing the native macOS Keychain.
   - Universally executes `curl -k` with zero TLS certificate verification and zero form action domain whitelisting, exposing credentials to rogue evil-twin access points.
4. **Scanning & Optimization Completely Broken (DEF-05):**
   - Relies on Apple's private `airport` CLI, which is removed and defunct on macOS 15.

---

## 4. Physical Testing Requirements (What Still Requires Real Mac Testing)

Before macOS support can be certified for release, the following items **cannot be validated in Linux CI** and strictly require physical testing on an actual MacBook (Intel & Apple Silicon) on campus:

1. **`SCDynamicStore` / `configd` Event Latency:** Measuring exact latency between 802.11 association and background agent execution.
2. **TCC Privacy Prompt Behavior:** Verifying whether fallback DNS/Gateway detection can bypass the TCC location barrier without triggering intrusive OS prompts.
3. **Apple Captive Network Assistant (CNA) Timing:** Testing whether background authentication completes fast enough to prevent CNA from displaying, or observing whether CNA auto-closes upon receiving the `captive.apple.com` success response.
4. **macOS Keychain Access in Non-Interactive LaunchAgent:** Verifying that `security find-generic-password` succeeds inside a `launchd` `gui/$UID` context without prompting for the user's login password.
5. **Wake-from-Sleep Power Management (`IOPM`):** Observing adapter settling time when a MacBook lid is opened on campus before `curl` times out.
6. **Physical Radio Handover (Aruba & Ruijie):** Verifying real-world POST requests against University of Moratuwa physical controllers (`connect.uom.lk:8443` and Aruba gateways).

---

## 5. Certification Verdict

```
========================================================================================
FINAL PHASE 03.0 DECISION: OPTION C — REJECT & REDESIGN REQUIRED
========================================================================================
The macOS implementation requires substantial remediation before it can be staged
for physical campus validation.

MANDATORY PREREQUISITES BEFORE ANY PHYSICAL MAC TESTING:
  1. Fix DEF-01: Remove Bash 4 negative subscripting in bin/uninet-macos:257.
  2. Fix DEF-02: Replace inert WatchPaths with SCDynamicStore or resolv.conf triggers.
  3. Fix DEF-03: Implement TCC-resilient network identification cascade.
  4. Fix DEF-04: Migrate plaintext credentials to macOS Keychain via /usr/bin/security.
  5. Fix DEF-06 & DEF-07: Harden TLS validation and enforce form action whitelisting.
========================================================================================
```
