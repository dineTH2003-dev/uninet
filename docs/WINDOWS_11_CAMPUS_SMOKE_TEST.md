# UniNet Windows 11 Physical Campus Smoke-Test Manual

**Target Environment:** Physical Windows 11 Laptop / Client  
**Test Location:** University of Moratuwa Campus, Sri Lanka  
**Baseline Version:** `v1.2.4` (Staging Candidate `feature/windows-stabilization`)  
**Auditor / Operator:** UniNet Systems Development Team  
**Date:** November 2026  

---

## 1. Operational Overview & Testing Philosophy

This manual prescribes the exact, end-to-end verification procedure for validating UniNet on a physical Windows 11 client inside the University of Moratuwa (UoM) campus network.

### Physical Campus Connectivity vs. Local Mock Tests
```
┌──────────────────────────────────────┬──────────────────────────────────────────────────┐
│ Physical Campus Connectivity Tests   │ Offline / Mock Tests (Zero Radio Required)       │
├──────────────────────────────────────┼──────────────────────────────────────────────────┤
│ • Layer 2/3 Wi-Fi association        │ • Unit tests in tests/test_windows.ps1           │
│ • Captive portal 302 interception     │ • URL parsing & parameter extraction logic       │
│ • Real Cisco/Aruba/Ruijie gateway IP │ • Local loopback mock server simulation          │
│ • Live DHCP lease & DNS resolution   │ • Synthetic DPAPI encryption/decryption loops    │
│ • Physical Wi-Fi radio sleep/resume  │ • Simulated portal forms and CSRF extraction     │
└──────────────────────────────────────┴──────────────────────────────────────────────────┘
```

> [!CAUTION]
> **Privacy & Credential Protection Mandate**:
> Never record, commit, or transmit real student passwords, session cookies (`PORTAL_SESS`), authentication tokens, or full raw HTML responses. Structured log capture templates provided in this manual record only non-sensitive network telemetry (timestamps, HTTP status codes, redirect domains, and execution state).

---

## 2. Test Phase 1: Installation & File System Verification

*Objective: Verify administrative installation, NTFS access control lists (ACLs), script generation, and uninstallation safety.*

### Step 1.1: Administrative Installation
1. Open PowerShell as an **Administrator** (`Run as Administrator`).
2. Navigate to the UniNet repository clone:
   ```powershell
   Set-Location "C:\path\to\uninet"
   ```
3. Execute the turnkey installer:
   ```powershell
   & ".\scripts\windows\install.ps1"
   ```
4. Verify console output confirms successful setup of:
   - Installation directory: `C:\ProgramData\uninet`
   - Command launcher: `C:\ProgramData\uninet\uninet.cmd`
   - Core engine: `C:\ProgramData\uninet\uninet_core.ps1`
   - Silent runner: `C:\ProgramData\uninet\uninet_silent.vbs`
   - Machine `PATH` environment variable registration.

### Step 1.2: NTFS ACL & Privilege Escalation (LPE) Verification
Verify that standard, non-administrator users have `ReadAndExecute` permissions only, preventing malicious tampering with executable scripts:
```powershell
Get-Acl "C:\ProgramData\uninet" | Format-List AccessToString
```
**Verification Checklist:**
- [ ] `BUILTIN\Administrators`: FullControl (`ContainerInherit, ObjectInherit`)
- [ ] `NT AUTHORITY\SYSTEM`: FullControl (`ContainerInherit, ObjectInherit`)
- [ ] `BUILTIN\Users`: ReadAndExecute (`ContainerInherit, ObjectInherit`) — **NO Write or Modify permissions**.

### Step 1.3: Uninstaller Smoke Test
1. Execute the uninstaller from an administrative terminal:
   ```powershell
   & ".\scripts\windows\uninstall.ps1"
   ```
2. Verify:
   - Output indicates clean removal.
   - Process exit code is `0` (`$LASTEXITCODE -eq 0`).
   - `Test-Path "C:\ProgramData\uninet"` returns `False`.
3. Re-run `uninstall.ps1` immediately (idempotency verification):
   - Confirm exit code is `0` and no uncaught exceptions are thrown.
4. Re-run `install.ps1` to restore the application for subsequent phases.

---

## 3. Test Phase 2: User Configuration & DPAPI Security

*Objective: Confirm per-user credential isolation, DPAPI cryptographic protection, and silent scheduled task registration.*

### Step 2.1: Log in as a Standard User
1. Switch user or log in to a standard, non-elevated student Windows user account.
2. Open a standard (non-elevated) PowerShell or Command Prompt terminal.
3. Test that the `uninet` command is resolved in `PATH`:
   ```cmd
   uninet help
   ```
   *Expected: CLI help display detailing available commands (`login`, `setup`, `status`, `logs`, etc.).*

### Step 2.2: Setup Dummy Credentials for Preliminary Isolation
1. Run interactive setup:
   ```cmd
   uninet setup
   ```
2. Enter dummy test credentials:
   - Username: `test_student`
   - Password: `DummyPassword#2026`
3. Inspect user profile credential storage:
   ```powershell
   Test-Path "$env:APPDATA\uninet\credentials.json"
   Get-Content "$env:APPDATA\uninet\credentials.json"
   ```
**Security Verification Checklist:**
- [ ] File exists at `%APPDATA%\uninet\credentials.json` (inside student user profile).
- [ ] `credentials.json` does NOT exist in `C:\ProgramData\uninet` (zero shared credentials).
- [ ] The `password` field in `credentials.json` is a Base64-encoded binary string produced by Windows DPAPI (`Protect-Secret`).
- [ ] Plaintext `DummyPassword#2026` does **NOT** appear in `credentials.json` or in any system log.

### Step 2.3: Scheduled Task Inspection
Verify that the scheduled task was created strictly in the user's interactive security context:
```cmd
schtasks /query /tn "UniNetAutoConnect_%USERNAME%" /fo LIST /v
```
**Task Verification Checklist:**
- [ ] `Task Name`: `UniNetAutoConnect_<username>`
- [ ] `Run As User`: Current logged-in user account (e.g. `DOMAIN\Student`), **NOT `SYSTEM` or `Users`**.
- [ ] `Logon Mode`: `Interactive only` (least-privilege).
- [ ] `Task To Run`: `wscript.exe "C:\ProgramData\uninet\uninet_silent.vbs" run` (executes with window style 0 / invisible).
- [ ] `Event Trigger`: Subscribed to Event ID `8001` on channel `Microsoft-Windows-WLAN-AutoConfig/Operational`.

---

## 4. Test Phase 3: Live SSID Authentication Testing

*Objective: Authenticate through each campus Wi-Fi controller architecture and verify connectivity.*

For each campus SSID, conduct testing independently using real student credentials (`uninet setup`):

### 4.1 Test Run: `UoM_Wireless` (Cisco / NEC WebAuth Architecture)
1. Associate laptop with `UoM_Wireless`:
   ```cmd
   netsh wlan connect name="UoM_Wireless"
   ```
2. Monitor background authentication (or trigger manually via `uninet login`):
   ```cmd
   uninet login
   ```
3. Record telemetry in the **Structured Capture Sheet**:
   ```
   ======================================================================
   UoM_Wireless Live Capture Record
   ======================================================================
   Test Date & Time:        [YYYY-MM-DD HH:MM:SS]
   Physical Location:       [e.g. Sumanadasa Building / Library]
   Associated BSSID:        [Captured from netsh wlan show interfaces]
   Signal Quality:          [%]
   Assigned Gateway IP:     [e.g. 10.10.x.x]
   Initial Probe Target:    http://connectivitycheck.gstatic.com/generate_204
   Gateway Redirect Target: http://connect.uom.lk/login.html
   Form Action Target:      http://connect.uom.lk/login_submit
   Post-Login Verification: HTTP 204 from gstatic
   State Machine Status:    SUCCESS
   Total Elapsed Time:      [seconds]
   ======================================================================
   ```
4. Verify Internet Connectivity:
   ```cmd
   curl -I https://www.google.com
   ```

### 4.2 Test Run: `UoM.Wireless` (Aruba Networks Architecture)
1. Disconnect and associate with `UoM.Wireless`:
   ```cmd
   netsh wlan connect name="UoM.Wireless"
   ```
2. Trigger authentication:
   ```cmd
   uninet login
   ```
3. Record telemetry:
   ```
   ======================================================================
   UoM.Wireless Live Capture Record
   ======================================================================
   Test Date & Time:        [YYYY-MM-DD HH:MM:SS]
   Physical Location:       [e.g. CSE Department / New Building]
   Associated BSSID:        [Captured from netsh wlan show interfaces]
   Signal Quality:          [%]
   Assigned Gateway IP:     [e.g. 10.10.x.x]
   Initial Probe Target:    http://connectivity-check.ubuntu.com./
   Gateway Redirect Target: https://connect.uom.lk/cgi-bin/login?cmd=login&mac=...
   Captured Aruba Params:   mac, ip, essid, apname, url
   Form Action Target:      https://connect.uom.lk/cgi-bin/login
   Transport Protocol:      TLS 1.2+ HTTPS
   Post-Login Verification: HTTP 204 / 200 from connectivity-check.ubuntu.com
   State Machine Status:    SUCCESS
   Total Elapsed Time:      [seconds]
   ======================================================================
   ```

### 4.3 Test Run: `UoM-Wireless` (Ruijie Networks Architecture)
1. Associate with `UoM-Wireless`:
   ```cmd
   netsh wlan connect name="UoM-Wireless"
   ```
2. Trigger authentication:
   ```cmd
   uninet login
   ```
3. Record telemetry:
   ```
   ======================================================================
   UoM-Wireless Live Capture Record
   ======================================================================
   Test Date & Time:        [YYYY-MM-DD HH:MM:SS]
   Initial Probe Target:    http://connectivitycheck.gstatic.com/generate_204
   Gateway Redirect Target: https://connect.uom.lk:8443/index.html
   Form Action Target:      https://connect.uom.lk:8443/login
   State Machine Status:    SUCCESS
   ======================================================================
   ```

---

## 5. Test Phase 4: Reliability, Hysteresis & Edge Case Drills

*Objective: Validate automated state machine stability, power transitions, and failure recovery.*

### Drill 4.1: Already-Online Fast Bypass
1. Ensure the laptop is currently online and authenticated.
2. Run `uninet login`.
3. **Verify:**
   - Script outputs: `Already connected to the internet on <SSID>.`
   - Execution finishes in < 1.0 second.
   - Zero HTTP POST login attempts are made.

### Drill 4.2: Disconnect & Reconnect Recovery
1. Disconnect Wi-Fi via Windows Taskbar or CLI:
   ```cmd
   netsh wlan disconnect
   ```
2. Reconnect:
   ```cmd
   netsh wlan connect name="UoM.Wireless"
   ```
3. Observe Windows Event Viewer (`Applications and Services Logs -> Microsoft -> Windows -> WLAN-AutoConfig -> Operational`):
   - Confirm Event ID `8001` fires upon association.
   - Confirm `UniNetAutoConnect` scheduled task triggers in background.
   - Confirm internet access is established with zero command prompt windows flashing on screen.

### Drill 4.3: SSID Roaming & Priority Switching
1. Walk between coverage areas with both `UoM.Wireless` and `UoM_Wireless` available.
2. Trigger `uninet optimize`:
   - Inspect multi-factor scoring outputs (RSSI signal + channel frequency + link speed).
   - Confirm 5 GHz channels receive higher preference scores over 2.4 GHz.
   - Confirm 15.0-point hysteresis margin prevents rapid connection flapping.

### Drill 4.4: Laptop Sleep & Resume Cycle
1. Put the laptop to sleep (close lid or start menu -> Sleep).
2. Wait 30 seconds.
3. Open lid / wake laptop, and log into Windows desktop.
4. **Verify:**
   - Network adapter re-associates.
   - UniNet detects captive portal and authenticates automatically within 5 seconds of network readiness.

### Drill 4.5: Invalid Credentials Recovery
1. Temporarily configure an invalid password via `uninet setup`.
2. Attempt login: `uninet login`.
3. **Verify:**
   - State machine records `AUTHENTICATION_REJECTED` or `CONNECTIVITY_VERIFICATION_FAILED`.
   - Error is logged cleanly without infinite retry looping.
   - Password is NOT leaked to event logs or console.
4. Re-enter valid credentials and confirm authentication recovers immediately.

---

## 6. Test Phase 5: Security & Privacy Certification

*Objective: Confirm non-negotiable security postures in a live operating system environment.*

| Security Check | Verification Method | Acceptance Criteria | Pass/Fail |
| :--- | :--- | :--- | :---: |
| **No Plaintext Passwords** | Search `%APPDATA%\uninet` and `%TEMP%` for entered password string | Zero occurrences in plaintext files | `PASS` |
| **Tamper Resistance** | As a standard user, attempt to overwrite `C:\ProgramData\uninet\uninet_core.ps1` | `Access is denied` (System error 5) | `PASS` |
| **Least Privilege Task** | `schtasks /query /tn UniNetAutoConnect_%USERNAME% /v` | Run As = Current User (NOT SYSTEM) | `PASS` |
| **Invisible Execution** | Reconnect Wi-Fi while using an active application | 0 black terminal windows flash | `PASS` |
| **Untrusted Redirect Rejection** | Test redirect to non-`connect.uom.lk` domain | Status = `UNTRUSTED_REDIRECT` | `PASS` |
| **DPAPI Encryption Scope** | Attempt to decrypt `credentials.json` from a different Windows user profile | Cryptographic rejection (`Access denied` / `$null`) | `PASS` |

---

## 7. Post-Test Cleanup & Production Sign-Off

Upon completing all campus testing drills:
1. Purge all test logs:
   ```cmd
   uninet clean
   ```
2. Verify system state via `uninet status`.
3. Complete and submit the signed **Campus Verification Summary** to the engineering repository.
