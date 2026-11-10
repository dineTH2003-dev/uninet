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

### Step 1.1: Standard User vs. Administrative Installation Verification

#### Step 1.1a: Attempt Installation as Standard (Non-Elevated) User
1. Open a standard, non-elevated PowerShell console (do NOT run as Administrator).
2. Navigate to the UniNet repository clone:
   ```powershell
   Set-Location "C:\path\to\uninet"
   ```
3. Attempt to run the installer:
   ```powershell
   & ".\scripts\windows\install.ps1"
   ```
4. **Expected Result & Security Acceptance Criteria:**
   - The installer encounters permission restrictions when attempting to write to `C:\ProgramData\uninet`, invoke `Set-Acl`, modify Machine-level `PATH`, or run `wevtutil` to enable event channels.
   - System integrity is preserved; standard users cannot compromise system-wide binaries or machine environment variables.

#### Step 1.1b: Administrative Installation
1. Open PowerShell as an **Administrator** (`Run as Administrator`).
2. Navigate to the repository:
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
   - WLAN-AutoConfig Operational channel activation via `wevtutil`.

### Step 1.2: NTFS ACL & Privilege Escalation (LPE) Verification
Verify that standard, non-administrator users have `ReadAndExecute` permissions only, preventing malicious tampering with executable scripts:
```powershell
Get-Acl "C:\ProgramData\uninet" | Format-List AccessToString
```
**Verification Checklist:**
- [ ] `BUILTIN\Administrators`: FullControl (`ContainerInherit, ObjectInherit`)
- [ ] `NT AUTHORITY\SYSTEM`: FullControl (`ContainerInherit, ObjectInherit`)
- [ ] `BUILTIN\Users`: ReadAndExecute (`ContainerInherit, ObjectInherit`) — **NO Write or Modify permissions**.

### Step 1.3: Uninstallation and Reinstallation Verification
1. **Standard User Denial Check:**
   - From a non-elevated prompt, attempt to delete `C:\ProgramData\uninet` or execute `uninstall.ps1`.
   - Confirm operation fails with `Access is denied`.
2. **Administrative Uninstallation:**
   - Execute the uninstaller from an administrative terminal:
     ```powershell
     & ".\scripts\windows\uninstall.ps1"
     ```
   - Verify output indicates clean removal of binaries, scheduled tasks, and machine `PATH` entry.
   - Confirm process exit code is `0` (`$LASTEXITCODE -eq 0`).
   - Confirm `Test-Path "C:\ProgramData\uninet"` returns `False`.
3. **Uninstaller Idempotency Check:**
   - Re-run `uninstall.ps1` immediately when already uninstalled:
     ```powershell
     & ".\scripts\windows\uninstall.ps1"
     ```
   - Confirm exit code is `0` and no uncaught exceptions are thrown.
4. **Reinstallation Verification:**
   - Re-run `install.ps1` from the administrative console:
     ```powershell
     & ".\scripts\windows\install.ps1"
     ```
   - Verify `C:\ProgramData\uninet` and system binaries are cleanly redeployed for subsequent test phases.

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

### Drill 4.6: System Reboot & Cold Boot Auto-Connect Verification
1. Perform a full system restart:
   ```cmd
   shutdown /r /t 0
   ```
2. Log in to Windows desktop as the standard student user.
3. Observe network initialization:
   - Wi-Fi adapter connects to campus SSID (e.g. `UoM.Wireless`).
   - WLAN-AutoConfig fires Event `8001`.
   - `UniNetAutoConnect_%USERNAME%` triggers silently via Task Scheduler.
4. **Verify:**
   - Full internet connectivity is established within 5–8 seconds of Windows desktop load.
   - Zero terminal popups or UAC prompts appear on screen.
   - Run `uninet status` to confirm `State Machine Status: ONLINE`.

---

## 6. Test Phase 5: Diagnostic Log & Event Viewer Inspection

*Objective: Verify structured diagnostics, log integrity, event tracing, and zero credential leakage.*

### Step 5.1: CLI Diagnostics Inspection
Execute the following diagnostic commands from standard PowerShell / CMD:
1. **Network & Portal Status:**
   ```cmd
   uninet status
   ```
   *Verify:* Correct SSID, active BSSID, RSSI %, gateway IP, probe target, and current connection state (`ONLINE` or `PORTAL_DETECTED`).
2. **Recent Execution Logs:**
   ```cmd
   uninet logs
   ```
   *Verify:* Chronological execution trace, timestamps, sanitized endpoints, absence of passwords, and exit status.
3. **Multi-Factor Network Optimization Analysis:**
   ```cmd
   uninet optimize
   ```
   *Verify:* Scans campus SSIDs, lists signal percentages, frequencies, and channel scores without error.

### Step 5.2: File System Log File Audit
Inspect the user-scoped log file directly:
```powershell
Get-Content "$env:APPDATA\uninet\uninet.log" -Tail 50
```
**Log Audit Checklist:**
- [ ] Log entries follow structured format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] Message`.
- [ ] No plaintext passwords, hashes, session cookies (`PORTAL_SESS`), or student credentials appear in any line.
- [ ] Error messages record structured failure codes (`TLS_VALIDATION_FAILED`, `AUTHENTICATION_REJECTED`, etc.) rather than unhandled exception stack traces.

### Step 5.3: Windows Event Viewer Audit
1. **WLAN-AutoConfig Event Channel:**
   ```powershell
   wevtutil qe Microsoft-Windows-WLAN-AutoConfig/Operational /c:5 /rd:true /f:text
   ```
   - Confirm Event ID `8001` (*"WLAN AutoConfig service has successfully connected to a wireless network"*) is logged with the target campus SSID.
2. **Task Scheduler Event Channel:**
   ```powershell
   wevtutil qe Microsoft-Windows-TaskScheduler/Operational /q:"*[System[Provider[@Name='Microsoft-Windows-TaskScheduler'] and (EventID=100 or EventID=102 or EventID=200 or EventID=201)]]" /c:5 /rd:true /f:text
   ```
   - Confirm Event `100` (Task triggered by event), Event `200` (Action started), and Event `102` (Task completed with exit code 0).

---

## 7. Test Phase 6: Security & Privacy Certification

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

## 8. Post-Test Cleanup & Production Sign-Off

Upon completing all campus testing drills:
1. Purge all test logs:
   ```cmd
   uninet clean
   ```
2. Verify system state via `uninet status`.
3. Complete and submit the signed **Campus Verification Summary** to the engineering repository.
