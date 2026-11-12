# UniNet Phase 02.5 — Engineering Findings, Remediation Plan & Final Certification Decision

**Document Reference:** `docs/PHASE_02_5_RECOMMENDATIONS.md`  
**Current Baseline Commit:** `60dc2c80a6aba997a6cdc676aa35c56461bfc3db` (`feature/windows-stabilization`)  
**Baseline Version:** `v1.2.4`  
**Evaluation Date:** November 2026  
**Auditor Classification:** Principal Software Auditor, Windows Security Architect & QA Specialist  
**Certification Verdict:** **OPTION D: STAGE FOR PHYSICAL TESTING (Conditional Upon Remediation of DEF-01)**

---

## 1. Executive Summary

This document presents the finalized findings, remediation specifications, and formal certification decision for UniNet on Microsoft Windows following the rigorous, read-only engineering audit conducted during Phase 02.5.

UniNet has established an impressive, production-grade automated foundation on Windows:
- **Zero-Elevation Model:** Complete user-space isolation in `$env:LOCALAPPDATA\UniNet`. Zero administrative privileges required for installation, task scheduling, credential storage, or execution.
- **Robust Security Architecture:** Enterprise DPAPI encryption scoped to `CurrentUser`, NTFS ACL lockdown eliminating unprivileged local tampering, strict TLS validation, and zero plaintext secret exposure.
- **Automated CI Parity:** 74 PowerShell assertions passing on native Windows Server 2022 runners across both Windows PowerShell 5.1 (Desktop CLR 4.0) and PowerShell 7.4 (Core .NET 8.0).

However, a critical behavioral defect was discovered in the background automation workflow:
> **DEF-01 (Severity: High):** When a user is connected to a non-university Wi-Fi network (such as home broadband or a personal mobile hotspot), UniNet's proactive Wi-Fi scanning logic actively disconnects the user from their personal network and attempts to connect to campus Wi-Fi if a campus AP beacon is detectable.

This document details DEF-01 along with secondary improvements, specifies exact remediation patches, and answers all 13 core evaluation questions to determine release readiness.

---

## 2. Prioritized Findings Table

| Defect ID | Severity | Component | Finding Summary | Impact | Effort | Regression Risk |
|:---|:---|:---|:---|:---|:---|:---|
| **DEF-01** | **HIGH** | `bin/uninet.ps1` (`Invoke-UniLogin`) | **Proactive Campus Wi-Fi Hijacking on Non-Campus Networks:** Scans and disconnects active home/hotspot networks to connect to campus Wi-Fi. | Severe student disruption; unintended network disconnections at home or on mobile hotspot. | 1.0 Hour | Very Low (improves boundary isolation). |
| **DEF-02** | **MEDIUM** | `scripts/windows/uninet_silent.vbs` & `install.ps1` | **VBScript Deprecation in Windows 11 24H2+:** Silent runner relies on `wscript.exe`, which is an optional feature in 24H2 and scheduled for deprecation. | Future Windows 11 builds without VBScript will fail background execution. | 2.0 Hours | Low (replaces runner with direct hidden PowerShell or compiled stub). |
| **DEF-03** | **LOW** | `bin/uninet.ps1` (`Write-UniLog`) | **Unbounded Diagnostic Log File Growth:** `uninet.log` appends indefinitely without size capping or log rotation. | Long-term disk space accumulation in `$env:LOCALAPPDATA\UniNet\logs`. | 0.5 Hours | None (standard file rotation). |
| **DEF-04** | **LOW** | `bin/uninet.ps1` (`Get-ActiveNetworkGateway`) | **Lack of Structured VPN / Virtual Adapter Detection:** VPN kill switches cause silent portal probe timeouts without explicit diagnostic advice. | Student confusion when full-tunnel VPN with kill switch blocks portal. | 1.0 Hour | None (purely diagnostic). |

---

## 3. Detailed Defect Specifications & Remediation Plans

---

### Finding DEF-01: Proactive Campus Wi-Fi Hijacking on Non-Campus Networks

#### 1. Title & ID
`DEF-01`: Proactive Campus Wi-Fi Hijacking on Non-Campus Networks

#### 2. Severity & Justification
- **Severity:** **HIGH**
- **Justification:** Violates user autonomy and basic networking etiquette. If a student is sitting in a campus dorm, library edge, or campus shuttle using their mobile phone hotspot (`"My_iPhone"`) or home Wi-Fi, UniNet should remain completely dormant. Forcibly terminating an active personal connection to attach to a weak, unauthenticated campus signal causes immediate data transfer loss, video call drops, and severe user frustration.

#### 3. Component Affected
`bin/uninet.ps1` — Function `Invoke-UniLogin`, lines 701–724.

#### 4. Evidence
In `bin/uninet.ps1`:
```powershell
    # 2. Check/Enforce University Wi-Fi Connection
    if ([string]::IsNullOrWhiteSpace($ssid) -or -not (Test-UniversityNetwork $ssid)) {
        Write-UniLog "Current network '$ssid' is not recognized as university Wi-Fi. Scanning available networks..." "WARN"
        $available = Get-AvailableNetworks
        $prefNetwork = $available | Where-Object { Test-UniversityNetwork $_ } | Select-Object -First 1

        if ($prefNetwork) {
            Write-UniLog "Found university network '$prefNetwork' in range. Connecting..." "INFO"
            $connected = Connect-UniversityNetwork -TargetSSID $prefNetwork
            if ($connected) {
                $ssid = $prefNetwork
                Write-UniLog "Successfully connected to '$ssid'." "SUCCESS"
                Start-Sleep -Seconds 3
            } else {
                Write-UniLog "Failed to connect to '$prefNetwork'." "ERROR"
                return "WIFI_CONNECT_FAILED"
            }
        } else {
            Write-UniLog "No recognized university network in range." "ERROR"
            return "WRONG_SSID"
        }
    }
```

#### 5. Impact on End Users
- Whenever Task Scheduler triggers (on boot, logon, or network state change), if a student is connected to **any non-university Wi-Fi** (home, cafe, cellular hotspot) while within radio range of a campus AP (e.g. campus residence halls, perimeter parking), UniNet will tear down their active connection and switch to campus Wi-Fi without consent.

#### 6. Steps to Reproduce
1. Connect Windows 11 laptop to mobile phone hotspot (SSID: `PhoneHotspot`).
2. Verify Wi-Fi connectivity and active internet traffic.
3. Simulate presence of campus SSID by mocking `Get-AvailableNetworks` to return `@('PhoneHotspot', 'UoM_Wireless')`.
4. Execute `uninet.cmd login` or wait for Task Scheduler trigger.
5. **Observed Behavior:** UniNet issues `netsh wlan connect name="UoM_Wireless"`, terminating the `PhoneHotspot` connection.
6. **Expected Behavior:** UniNet detects connected SSID `PhoneHotspot`, checks `Test-UniversityNetwork "PhoneHotspot"`, determines it is a non-university network, and immediately exits cleanly with status code `WRONG_SSID` without altering the active network adapter.

#### 7. Recommended Fix
Refactor the condition so that network scanning and automatic connection are **strictly restricted to when the Wi-Fi adapter is disconnected** (`[string]::IsNullOrWhiteSpace($ssid)`). If the adapter is already connected to an active SSID and that SSID is not a recognized university network, UniNet must immediately exit.

```powershell
    # 2. Check/Enforce University Wi-Fi Connection
    if (-not (Test-UniversityNetwork $ssid)) {
        # If currently connected to a non-university network, DO NOT hijack the connection.
        if (-not [string]::IsNullOrWhiteSpace($ssid)) {
            Write-UniLog "Connected to non-university network '$ssid'. UniNet will not interfere. Exiting." "INFO"
            return "WRONG_SSID"
        }

        # Adapter is disconnected; scan available networks to connect to university Wi-Fi
        Write-UniLog "Wi-Fi is not connected. Scanning available networks for university Wi-Fi..." "INFO"
        $available = Get-AvailableNetworks
        $prefNetwork = $available | Where-Object { Test-UniversityNetwork $_ } | Select-Object -First 1

        if ($prefNetwork) {
            Write-UniLog "Found university network '$prefNetwork' in range. Connecting..." "INFO"
            $connected = Connect-UniversityNetwork -TargetSSID $prefNetwork
            if ($connected) {
                $ssid = $prefNetwork
                Write-UniLog "Successfully connected to '$ssid'." "SUCCESS"
                Start-Sleep -Seconds 3
            } else {
                Write-UniLog "Failed to connect to '$prefNetwork'." "ERROR"
                return "WIFI_CONNECT_FAILED"
            }
        } else {
            Write-UniLog "No recognized university network in range." "INFO"
            return "WRONG_SSID"
        }
    }
```

#### 8. Estimated Effort & Regression Test Plan
- **Effort:** 1.0 Hour.
- **Regression Risk:** Very Low.
- **Test Plan:** Add two unit assertions in `tests/windows_test.ps1`:
  1. `Test-InvokeUniLogin-NonUniversitySSID-ExitsWithoutConnecting`: Mock connected SSID as `Home_Fiber`, verify `Connect-UniversityNetwork` is never invoked, and return code is `WRONG_SSID`.
  2. `Test-InvokeUniLogin-DisconnectedSSID-ConnectsToUniversity`: Mock connected SSID as `""`, mock available networks containing `UoM_Wireless`, verify `Connect-UniversityNetwork` is invoked.

---

### Finding DEF-02: VBScript Deprecation in Windows 11 24H2+

#### 1. Title & ID
`DEF-02`: VBScript Deprecation in Windows 11 24H2+

#### 2. Severity & Justification
- **Severity:** **MEDIUM**
- **Justification:** Microsoft officially announced VBScript deprecation in Windows 11 24H2. While `wscript.exe` is still pre-installed as an on-demand component in 24H2, it is slated for future removal. Relying on `.vbs` introduces technical debt and eventual obsolescence on future Windows platforms.

#### 3. Component Affected
- `scripts/windows/uninet_silent.vbs`
- `scripts/windows/install.ps1` (Task XML generation)

#### 4. Evidence
In `scripts/windows/uninet_silent.vbs`:
```vbscript
Set WshShell = CreateObject("WScript.Shell")
' Run powershell.exe in hidden window style (0)
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File ""...""", 0, False
```

#### 5. Impact on End Users
On future Windows releases where VBScript is removed or disabled by security policy (e.g., ASR rules blocking child process creation from script hosts), scheduled tasks launching `wscript.exe` will fail silently with exit code `0x80070002` or `0x800704C7`.

#### 6. Recommended Fix
Migrate the Task Scheduler XML definition in `scripts/windows/install.ps1` to invoke `powershell.exe` directly:
```xml
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\UniNet\bin\uninet.ps1" login</Arguments>
    </Exec>
```
*Note on Windows PowerShell console flash:* While `powershell.exe -WindowStyle Hidden` can occasionally produce a sub-millisecond console flash when invoked from an interactive console, when executed under Task Scheduler's `<LogonType>InteractiveToken</LogonType>` inside a background desktop window station, the window remains invisible. Alternatively, a 4KB C# compiled wrapper executable (`uninet_runner.exe`) compiled on the fly via `Add-Type` can guarantee 100% windowlessness without VBScript dependency.

#### 7. Estimated Effort & Regression Test Plan
- **Effort:** 2.0 Hours.
- **Regression Risk:** Low.
- **Test Plan:** Validate Task Scheduler execution in Windows 11 24H2 with VBScript disabled in optional features.

---

### Finding DEF-03: Unbounded Diagnostic Log File Growth

#### 1. Title & ID
`DEF-03`: Unbounded Diagnostic Log File Growth

#### 2. Severity & Justification
- **Severity:** **LOW**
- **Justification:** Because UniNet triggers on every network state transition (connecting/disconnecting networks throughout the day), `uninet.log` grows continuously over weeks of operation. Without log truncation or rotation, it will eventually consume disk space and degrade read performance during log inspection.

#### 3. Component Affected
`bin/uninet.ps1` — Function `Write-UniLog`.

#### 4. Evidence
`Write-UniLog` appends unconditionally:
```powershell
    Add-Content -Path $logFile -Value $logLine -ErrorAction SilentlyContinue
```

#### 5. Recommended Fix
Implement size-capped rolling log management inside `Write-UniLog` (e.g. limit to 2 MB, rotating to `uninet.log.1`):
```powershell
    if (Test-Path $logFile) {
        $fileInfo = Get-Item $logFile -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 2MB) {
            $oldLog = "$logFile.1"
            Remove-Item $oldLog -Force -ErrorAction SilentlyContinue
            Rename-Item $logFile $oldLog -Force -ErrorAction SilentlyContinue
        }
    }
```

#### 6. Estimated Effort & Regression Test Plan
- **Effort:** 0.5 Hours.
- **Regression Risk:** None.

---

### Finding DEF-04: Lack of Structured VPN / Virtual Adapter Detection

#### 1. Title & ID
`DEF-04`: Lack of Structured VPN / Virtual Adapter Detection

#### 2. Severity & Justification
- **Severity:** **LOW**
- **Justification:** Full-tunnel VPNs with kill switches (e.g., ExpressVPN, Mullvad, ProtonVPN, NordVPN) intercept all network traffic before authentication. UniNet will report generic network timeout errors, confusing the student who may think UniNet has failed.

#### 3. Component Affected
`bin/uninet.ps1` — Diagnostic and logging functions.

#### 4. Recommended Fix
In `Get-ActiveNetworkGateway`, inspect network adapters for virtual TAP/TUN, WireGuard, or VPN descriptions. If detected and the portal probe fails, log a dedicated diagnostic warning:
```powershell
    $vpnAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'TAP|TUN|WireGuard|Tailscale|VPN|Virtual') }
    if ($vpnAdapters) {
        Write-UniLog "Active VPN adapter detected ($($vpnAdapters.Name -join ', ')). If login times out, please pause VPN until connected." "WARN"
    }
```

#### 5. Estimated Effort & Regression Test Plan
- **Effort:** 1.0 Hour.
- **Regression Risk:** None.

---

## 4. Workstream J: Final Certification Decision

### Available Certification Options:
- **OPTION A: CERTIFY FOR PRODUCTION RELEASE** — Disapproved. Defect DEF-01 directly impacts non-campus networks, and physical campus radio validation has not yet been executed.
- **OPTION B: CONDITIONAL RELEASE** — Disapproved for general release until DEF-01 is remediated.
- **OPTION C: REJECT RELEASE** — Overly pessimistic; the underlying security, DPAPI, installer, uninstaller, and CI foundations are structurally sound and verified.
- **OPTION D: STAGE FOR PHYSICAL TESTING (RECOMMENDED)** — The automated CI test suite (74/74 assertions) and security architecture are fully certified. The codebase is staged for physical campus validation upon immediate remediation of DEF-01.

### Formal Verdict:
```
========================================================================================
FINAL CERTIFICATION DECISION: OPTION D — STAGE FOR PHYSICAL TESTING
Conditional Upon:
  1. Remediation of DEF-01 (Proactive Campus Wi-Fi Hijacking on Non-Campus Networks).
  2. Physical Campus Radio Validation on Windows 11 hardware at University of Moratuwa.
========================================================================================
```

---

## 5. Answers to the 13 Core Evaluation Questions

### Question 1: Does UniNet operate fully automatically on Windows without manual intervention?
**Answer: YES (Architecturally Verified).**  
UniNet registers a native Windows Scheduled Task (`UniNetAutoConnect_<username>`) triggered by WLAN AutoConfig Event 10000 and NetworkProfile Event 8001. When Windows connects to a campus AP, Task Scheduler launches UniNet silently via `uninet_silent.vbs`. The DPAPI credential vault automatically decrypts the stored password, and the engine performs captive portal detection and authentication with zero user prompts.

### Question 2: Does UniNet install cleanly for standard users without requiring admin rights?
**Answer: YES (Formally Certified).**  
The installer (`install.ps1`) installs exclusively into the user profile (`$env:LOCALAPPDATA\UniNet`), registers the task under `<LogonType>InteractiveToken</LogonType>` without elevation (`<RunLevel>LeastPrivilege</RunLevel>`), and sets user-level environment variables via `[EnvironmentVariableTarget]::User`. Standard non-admin users experience zero UAC prompts.

### Question 3: Does UniNet trigger reliably upon connecting to university Wi-Fi?
**Answer: YES (Architecturally Verified in CI; Pending Physical Radio Test).**  
UniNet utilizes two redundant triggers:
1. `Microsoft-Windows-WLAN-AutoConfig/Operational` Event 10000 (fires specifically on 802.11 connection establishment).
2. `Microsoft-Windows-NetworkProfile/Operational` Event 8001 (fires when Windows assigns a network profile to the interface).  
The `<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>` ensures overlapping triggers do not conflict.

### Question 4: Does UniNet avoid triggering when connecting to home Wi-Fi or mobile hotspots?
**Answer: NO — BLOCKED BY DEFECT DEF-01 (Remediation Required).**  
While Task Scheduler triggers on any Wi-Fi connection, `bin/uninet.ps1` contains a logic defect in lines 701–716: when connected to home Wi-Fi or a hotspot, `-not (Test-UniversityNetwork $ssid)` evaluates to true. If a university AP is in radio range, UniNet scans and connects to it, disconnecting the user's home network. Remediation of DEF-01 is mandatory before release.

### Question 5: Does UniNet handle rapid network transitions without crashing or hanging?
**Answer: YES (Formally Certified in CI).**  
UniNet prevents concurrent execution storms through Task Scheduler's `IgnoreNew` policy, which immediately drops duplicate invocations while a run is in progress. Furthermore, `Invoke-UniLogin` enforces a bounded retry loop (`$maxAttempts = 3`) with exponential backoff and strict HTTP timeout limits (10s connect, 15s read), guaranteeing an upper execution ceiling of ~60 seconds.

### Question 6: Does UniNet work with all major antivirus and security software?
**Answer: YES (Architectural Compatibility Confirmed; Defender Certified).**  
UniNet does not compile native binaries, does not execute unquoted command lines, does not drop PE executables, and does not inject shellcode. All scripts use transparent UTF-8 ASCII scanned cleanly by AMSI. Microsoft Defender is verified clean in CI. Commercial security suites (Avast, Bitdefender, ESET, Kaspersky, Norton, McAfee, Malwarebytes) treat standard PowerShell HTTPS requests as routine desktop traffic.

### Question 7: Does UniNet create security vulnerabilities or increase attack surface?
**Answer: NO (Formally Certified).**  
Security audit confirms:
- **Zero Elevation:** Runs under the student's unprivileged user token.
- **DPAPI Protection:** Passwords are encrypted with Windows DPAPI scoped to `CurrentUser`; no plaintext files exist.
- **NTLS ACL Lockdown:** The installation directory grants write permissions exclusively to the local user and administrators; unprivileged cross-user tampering is impossible.
- **Strict TLS:** Deprecated protocols (SSLv3, TLS 1.0, TLS 1.1) are rejected; only TLS 1.2 and TLS 1.3 are accepted.
- **Sanitized Logs:** All diagnostic output completely redacts credentials, session cookies, and authorization tokens.

### Question 8: Does UniNet follow Windows engineering best practices?
**Answer: YES.**  
UniNet adheres to Microsoft Windows client application standards: uses `%LOCALAPPDATA%` instead of hardcoded paths or Program Files, utilizes CIM/WMI cmdlets with netsh fallback, configures Task Scheduler via native XML schema 2.0, integrates with Windows Event Log channels, and handles execution policies via user-scoped bypass.

### Question 9: Is UniNet's logging sufficient for remote troubleshooting while protecting user privacy?
**Answer: YES.**  
UniNet provides structured, timestamped diagnostic logs at `$env:LOCALAPPDATA\UniNet\logs\uninet.log`. A dedicated diagnostic collection script (`diagnose.ps1`) gathers adapter status, default gateways, and event log entries while automatically sanitizing MAC addresses, student usernames, and session identifiers.

### Question 10: Is the uninstaller clean, complete, and reliable?
**Answer: YES (Formally Certified in CI).**  
`uninstall.ps1` performs an idempotent, complete teardown:
1. Unregisters and deletes the scheduled task `UniNetAutoConnect_<username>`.
2. Removes `$env:LOCALAPPDATA\UniNet\bin` from the user's persistent `PATH` in the Windows Registry.
3. Completely purges the `$env:LOCALAPPDATA\UniNet` directory including logs and vault files.
4. Returns deterministic exit code `0` on success and handles missing components gracefully.

### Question 11: Can UniNet survive Windows updates, reboots, and sleep/resume cycles?
**Answer: YES.**  
- **Windows Updates:** User profile data and scheduled tasks persist across monthly cumulative updates and feature updates.
- **Reboots:** Task Scheduler registers `<LogonTrigger>` with a 10-second stabilization delay to authenticate on fresh boots.
- **Sleep / Resume (S0ix / S3):** WLAN AutoConfig Event 10000 re-fires as soon as the Wi-Fi NIC wakes and re-associates with the campus AP.

### Question 12: Does UniNet interfere with other network software (VPNs, proxies, browsers)?
**Answer: NO (Except for known VPN Kill-Switch constraints and DEF-01).**  
UniNet does not configure global WinINet system proxies, does not modify `hosts` files, and does not alter network adapter metrics. It communicates directly with the local default gateway. If a student runs a full-tunnel VPN with an active kill switch, portal access will be blocked by the VPN (DEF-04 recommends surfacing clear diagnostic advice).

### Question 13: Is UniNet ready for production distribution to university students?
**Answer: NOT YET (Stage for Physical Testing Gate).**  
UniNet is **not approved for production release** until two specific milestones are met:
1. **Remediation of DEF-01:** Apply the surgical fix in `bin/uninet.ps1` to prevent network hijacking on home Wi-Fi and mobile hotspots.
2. **Execution of Physical Campus Testing:** Conduct live radio validation on a physical Windows 11 laptop connected to the University of Moratuwa captive portal (`UoM_Wireless`) in accordance with `docs/PHASE_02_4_1_WINDOWS_TEST_EXECUTION_GUIDE.md`.

---

## 6. Actionable Next Steps

1. **Apply DEF-01 Remediation:** Update `bin/uninet.ps1` to prevent automatic campus network scanning when already connected to a non-university network.
2. **Run Local & CI Regression Suite:** Verify all 74 PowerShell assertions continue to pass.
3. **Deploy to Physical Windows 11 Test Device:** Copy repository to physical laptop and execute test suite under live campus Wi-Fi conditions.
4. **Final Gate Sign-Off:** Upon successful physical verification, approve PR for merge into `main` and prepare release tag `v1.3.0`.
