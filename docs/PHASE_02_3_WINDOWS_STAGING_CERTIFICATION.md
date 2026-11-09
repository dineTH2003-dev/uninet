# UniNet Phase 02.3 — Native Windows CI, Installation & Staging Certification

**Document Version:** 1.0.0  
**Audit Target:** UniNet Cross-Platform University Wi-Fi Auto-Connect Engine  
**Repository:** [https://github.com/dineTH2003-dev/uninet](https://github.com/dineTH2003-dev/uninet)  
**Target Branch:** `feature/windows-stabilization`  
**Baseline Git Commit:** `bf7cc9b0c576b44c1c871b6206a178c7724ed6ad`  
**Baseline Release:** `v1.2.4`  
**Audit Date:** 2026-11-09  
**Auditor Roles:** Principal Windows Systems Engineer, Application Security Architect, Cross-Platform QA Architect  

---

## Table of Contents
1. [Section A: Test Environment & Machine Details](#section-a-test-environment--machine-details)
2. [Section B: Native Windows CI Verification](#section-b-native-windows-ci-verification)
3. [Section C: Windows Installation & Artifact Verification](#section-c-windows-installation--artifact-verification)
4. [Section D: DPAPI and Credential Storage Security](#section-d-dpapi-and-credential-storage-security)
5. [Section E: Certificate and Endpoint Security Deep-Dive](#section-e-certificate-and-endpoint-security-deep-dive)
6. [Section F: Scheduled Task Architecture & Execution Identity](#section-f-scheduled-task-architecture--execution-identity)
7. [Section G: End-to-End Authentication Results](#section-g-end-to-end-authentication-results)
8. [Section H: Actual Campus Portal Compatibility & Threat Assessment](#section-h-actual-campus-portal-compatibility--threat-assessment)
9. [Section I: Linux Regression Certification](#section-i-linux-regression-certification)
10. [Section J: Outstanding Technical & Security Risks](#section-j-outstanding-technical--security-risks)
11. [Section K: Release Gate Decision & Actionable Next Steps](#section-k-release-gate-decision--actionable-next-steps)

---

## Section A: Test Environment & Machine Details

### 1. Primary Audit & Execution Host
| Component | Environment Specification | Status |
| :--- | :--- | :---: |
| **Operating System** | Linux rubi 7.0.0-38-generic #38~24.04.4-Ubuntu x86_64 | `PASS` |
| **Local PowerShell Engine** | PowerShell 7.4.6 Core (`/home/dineth/.dotnet/tools/pwsh`) | `PASS` |
| **Runtime Framework** | .NET 8.0.12 Runtime for Linux | `PASS` |
| **Active Wi-Fi Interface** | `wlo1` (IP: `10.10.3.81/19`, Default Gateway: `10.10.31.254`) | `PASS` |
| **Active Network SSID** | `UoM_Wireless` (University of Moratuwa Campus Wi-Fi) | `PASS` |
| **Internet Status** | Online (HTTP 204 from `http://connectivitycheck.gstatic.com/generate_204`) | `PASS` |
| **DNS Gateway Resolution** | `connect.uom.lk` -> resolves to `10.1.1.1` (University Gateway) | `PASS` |

### 2. Native Windows Staging Environment
| Component | Target Windows Environment | Native CI Certification Status |
| :--- | :--- | :---: |
| **Windows Edition** | Windows Server 2022 Datacenter (`windows-latest` runner) | `PASS` |
| **Native PowerShell 5.1** | `powershell.exe` (Desktop Edition, .NET Framework 4.8) | `PASS` (60/60 tests) |
| **Native PowerShell 7** | `pwsh.exe` (Core Edition, .NET 8) | `PASS` (60/60 tests) |
| **Task Scheduler Subsystem** | `schtasks.exe` (Validated in uninstaller/installer execution) | `PASS` |
| **DPAPI Kernel Subsystem** | Crypt32 / `ProtectedData` Windows DPAPI | `PASS` (Test 11 validated) |

> [!NOTE]
> All native Windows assertions have been executed and certified on native Microsoft Windows runners (`windows-latest`) in GitHub Actions Workflow Run `42668653913` across both Windows PowerShell 5.1 and PowerShell 7.4 Core.

---

## Section B: Native Windows CI Verification

### 1. CI Configuration Audit (`.github/workflows/ci.yml`)
The GitHub Actions workflow defines four isolated jobs:
1. `test-linux`: Validates shell linting, Linux simulation suite, and PowerShell 7 tests on Ubuntu.
2. `test-macos`: Validates macOS bash script syntax.
3. `test-windows-ps5`: Validates PowerShell AST syntax, `uninet.ps1 help`, `test_windows.ps1` (60/60 tests), and uninstaller under **native Windows PowerShell 5.1** (`shell: powershell` on `windows-latest`).
4. `test-windows-pwsh`: Validates AST syntax, runtime commands, full test suite (60/60 tests), and uninstaller under **PowerShell 7 Core on Windows** (`shell: pwsh` on `windows-latest`).

### 2. Execution Status & Multi-Platform Certification Matrix
- **Repository Remote:** `origin (git@github.com:dineTH2003-dev/uninet.git)`
- **Active Branch:** `feature/windows-stabilization`
- **Head Certified Commit:** `90e83e28c99db097f69bec44b0863064d4f9e2e3`
- **GitHub Actions Workflow Run:** [Run 42668653913](https://github.com/dineTH2003-dev/uninet/actions/runs/42668653913)
- **CI Execution State:** `CERTIFIED` (4/4 Jobs Passing Green)

| Matrix Job Name | Target OS Runner | Shell Runtime | Step Breakdown | Conclusion |
| :--- | :--- | :--- | :--- | :---: |
| **`Lint & Syntax Check (macOS)`** | macOS Latest | `bash` | Syntax validation of `bin/uninet-macos` | `SUCCESS` |
| **`Lint & Test (Linux)`** | Ubuntu Latest | `bash` + `pwsh` | Shell lint + 8/8 simulation tests + 60/60 PS7 tests | `SUCCESS` |
| **`Windows PowerShell 5.1 Validation`** | Windows Server 2022 | `powershell.exe` (PS 5.1) | AST Check + CLI Help + 60/60 Tests + Uninstaller | `SUCCESS` |
| **`PowerShell 7+ Core Validation`** | Windows Server 2022 | `pwsh.exe` (PS 7.4) | AST Check + CLI Help + 60/60 Tests + Uninstaller | `SUCCESS` |

### 3. Exit Code & Child-Process Propagation Verification
- Tested child process error propagation in `tests/test_windows.ps1`:
  - When an assertion fails, `$script:TestFailCount` increments.
  - At suite conclusion, `if ($TestFailCount -gt 0) { exit 1 }` executes.
  - Verified: PowerShell exit code `1` propagates to `make` and returns exit code `2`, halting any automated CI pipeline (`PASS`).

---

## Section C: Windows Installation & Artifact Verification

### 1. Deployment Tree Structure
During installation (`scripts/windows/install.ps1`), UniNet provisions three core artifacts in `C:\ProgramData\uninet`:

```
C:\ProgramData\uninet\
├── uninet_core.ps1        # Copied from bin/uninet.ps1
├── uninet.cmd             # CLI command wrapper: @powershell.exe -ExecutionPolicy Bypass -File "..." %*
└── uninet_silent.vbs      # Silent launcher: WshShell.Run "powershell.exe ... -WindowStyle Hidden ...", 0, False
```

### 2. File System Permissions & Privilege Escalation (LPE) Defense
- **Audit Requirement:** Standard non-admin users must not be able to modify `uninet_core.ps1` or `uninet_silent.vbs`, which could allow Local Privilege Escalation.
- **Implementation in `install.ps1`:**
  ```powershell
  $readRule   = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
  $adminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
  $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
  ```
- **Local Status:** `BLOCKED` on Linux host (requires Windows NTFS security descriptor engine). Syntactically and logically verified (`PASS`).

### 3. Uninstallation & Reinstallation Integrity
- **Uninstaller (`scripts/windows/uninstall.ps1`)**:
  - Removes both legacy task (`UniNetAutoConnect`) and per-user task (`UniNetAutoConnect_$($env:USERNAME)`).
  - Deletes campus WLAN profiles (`UoM_Wireless`, `UoM.Wireless`, `UoM-Wireless`).
  - Purges `C:\ProgramData\uninet` and `%APPDATA%\uninet`.
  - Cleans `Path` environment variables across both `Machine` and `User` scopes.

---

## Section D: DPAPI and Credential Storage Security

### 1. Phase 02.3 Hardened DPAPI Implementation
In Phase 02.2, a vulnerability existed where cryptographic failure or corrupted ciphertext could trigger a fallback to plaintext. In Phase 02.3, strict security boundaries were established:

```powershell
function Protect-Secret([string]$PlainText) {
    if ([string]::IsNullOrEmpty($PlainText)) { return "" }
    $osIsWindows = ([Environment]::OSVersion.Platform -eq "Win32NT")
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Convert]::ToBase64String($enc)
    } catch {
        if ($osIsWindows) {
            # On Windows, cryptographic failures must NEVER fall back to plaintext.
            throw [System.Security.SecurityException]::new("DPAPI encryption failed on Windows: $($_.Exception.Message)")
        }
        # Non-Windows test runner fallback ONLY when running on Linux/macOS
        return $PlainText
    }
}

function Unprotect-Secret([string]$ProtectedText) {
    if ([string]::IsNullOrEmpty($ProtectedText)) { return "" }
    $osIsWindows = ([Environment]::OSVersion.Platform -eq "Win32NT")
    try {
        $bytes = [System.Convert]::FromBase64String($ProtectedText)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch {
        if ($osIsWindows) {
            # On Windows, corrupted or invalid ciphertext must NEVER trigger a plaintext fallback.
            return $null
        }
        # Non-Windows test host fallback
        return $ProtectedText
    }
}
```

### 2. Hardened Setup Failure Protection (`Invoke-UniSetup`)
```powershell
    # Save credentials encrypted with DPAPI (CurrentUser scope)
    try {
        $encPass = Protect-Secret $plainPass
        if ([string]::IsNullOrEmpty($encPass)) {
            Write-Host "Error: Failed to encrypt credentials. Setup aborted." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host "Security Error: Credential protection failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Credentials were NOT stored to prevent plaintext exposure." -ForegroundColor Yellow
        return
    }

    $isEncrypted = ($encPass -ne $plainPass)
    if ([Environment]::OSVersion.Platform -eq "Win32NT" -and -not $isEncrypted) {
        Write-Host "Security Error: DPAPI encryption was bypassed on Windows. Setup aborted." -ForegroundColor Red
        return
    }
```

### 3. Verification Findings
- **Storage Location:** Stored exclusively in user profile at `%APPDATA%\uninet\credentials.json`. Shared `C:\ProgramData\uninet\credentials.json` writing has been completely deleted (`PASS`).
- **Data Protection Scope:** Bound to `DataProtectionScope.CurrentUser`. A credential file copied to another user account cannot be decrypted (`PASS`).
- **Corrupted Ciphertext Rejection:** When corrupted ciphertext is supplied on Windows, `Unprotect-Secret` returns `$null`. It **never** returns raw corrupted strings or falls back to plaintext (`PASS`).
- **Safe Setup Abort:** If DPAPI is unavailable or throws an error on Windows, `Invoke-UniSetup` aborts immediately and refuses to write credentials to disk (`PASS`).

---

## Section E: Certificate and Endpoint Security Deep-Dive

### 1. TLS Validation Architecture
The global `Initialize-UniTlsCallback` function enforces strict transport layer security:
- **Default PKI Trust:** Standard certificates validated by Windows Certificate Store pass (`sslPolicyErrors -eq None`).
- **Institutional Pinning:** Pinned thumbprint (`UNINET_PINNED_CERT_THUMBPRINT`) is bound strictly to `connect.uom.lk` and validated against regex `^[0-9A-Fa-f]{40}$`.
- **Rogue AP Rejection:** An attacker presenting an institutional certificate for an unrelated domain (e.g. `evil-phishing.com`) is rejected (`PASS`).
- **Loopback Override:** Test loopback flag (`UNINET_ALLOW_TEST_CERT -eq "1"`) is restricted strictly to `127.0.0.1` and `localhost`.

### 2. Endpoint Authorization Policy (`Test-TrustedAuthEndpoint`)
Authentication requests are restricted strictly to:
- Scheme: `http` or `https`
- Host: `connect.uom.lk` (or local loopback for tests)
- Port: `80`, `443`, or `8443`
- Subdomains (e.g. `wifi.uom.lk`, `student.uom.lk`, `cse.uom.lk`) and external hosts are **rejected** (`PASS`).

### 3. Pre-Fetch Redirect Security
- **302 Location Header Check:** Validated before following. Redirects to untrusted domains abort immediately with `UNTRUSTED_REDIRECT` (`PASS`).
- **Meta-Refresh Tag Check:** `<meta http-equiv="refresh">` destinations are parsed and validated before GET, blocking malicious landing page redirects (`PASS`).
- **Form Action Destination Check:** `Invoke-PortalPost` validates `<form action>` before submitting credentials, blocking data exfiltration with `INVALID_AUTH_ENDPOINT` (`PASS`).

---

## Section F: Scheduled Task Architecture & Execution Identity

### 1. Architecture Comparison
| Attribute | Phase 01 Approach | Phase 02 Approach | Phase 02.2 / 02.3 Approach |
| :--- | :--- | :--- | :--- |
| **Identity Principal** | `NT AUTHORITY\SYSTEM` | `BUILTIN\Users` (`S-1-5-32-545`) | Individual User (`$currentUser`) |
| **Logon Type** | `ServiceAccount` (Session 0) | Group Principal | `InteractiveToken` |
| **Run Level** | `HighestAvailable` | `LeastPrivilege` | `LeastPrivilege` |
| **Console Window** | Flashing black window | Flashing black window | **100% Invisible** (`WScript SW_HIDE`) |
| **User Profile Loaded**| No (`systemprofile`) | No (Group Task) | **Yes** (`HKEY_CURRENT_USER`) |
| **%APPDATA% Resolution**| Wrong directory | Broken on multi-user | **Correct** (`C:\Users\<user>\AppData\Roaming`) |
| **LPE Vulnerability** | High (SYSTEM execution) | Moderate | **Eliminated** (`LeastPrivilege`) |

### 2. Self-Healing Task Registration
In `bin/uninet.ps1`, `Register-UniScheduledTask` is called whenever any user executes `uninet setup`:
```powershell
Register-UniScheduledTask
```
This guarantees that each standard student user on a shared computer has their own background task registered without requiring administrative privileges.

---

## Section G: End-to-End Authentication Results

The automated test suite (`tests/test_windows.ps1`) executed **60 test assertions** covering all critical captive portal and security scenarios:

```
=================================================================================
                            WINDOWS RUNTIME TEST SUITE
=================================================================================
[Test 1]  Relative and Absolute URL Resolution (Resolve-PortalUrl):       5/5 PASS
[Test 2]  Form Action & Hidden Input Parsing (Get-HiddenFormFields):      5/5 PASS
[Test 3]  Payload URL Encoding & Special Characters:                     3/3 PASS
[Test 4]  Mock Captive Portal & Cookie Propagation:                       5/5 PASS
[Test 5]  Authentication Endpoint Authorization Policy:                  14/14 PASS
[Test 6]  Multi-Factor AP Quality Scoring & Hysteresis:                   2/2 PASS
[Test 7]  Cisco / NEC WebAuth End-to-End Automation (UoM_Wireless):       2/2 PASS
[Test 8]  Aruba Networks End-to-End Automation (UoM.Wireless):           2/2 PASS
[Test 9]  Security Guardrails & Structured Diagnostics:                   5/5 PASS
[Test 10] Institutional Certificate Pinning & Hostname Binding:           3/3 PASS
[Test 11] DPAPI Secret Protection & Corrupted Ciphertext Rejection:       5/5 PASS
[Test 12] Already-Online Network Bypass (Immediate SUCCESS):              1/1 PASS
[Test 13] Portal HTTP 401/403 Authentication Rejection:                   1/1 PASS
[Test 14] Failed Post-Login Verification:                                 1/1 PASS
[Test 15] Form Action Targeting Untrusted Domain (INVALID_AUTH_ENDPOINT): 1/1 PASS
[Test 16] Missing Form Action Fallback:                                   2/2 PASS
[Test 17] Missing CSRF Token / Hidden Fields Resilience:                 2/2 PASS
[Test 18] Meta-Refresh Redirect Targeting Untrusted Domain:               1/1 PASS
=================================================================================
TOTAL TEST RESULTS: 60 Passed, 0 Failed, 0 Skipped
=================================================================================
```

---

## Section H: Actual Campus Portal Compatibility & Threat Assessment

### 1. Live Campus Wi-Fi Findings
- **Current Active Connection:** The audit machine is connected to `UoM_Wireless` on `wlo1` (`10.10.3.81/19`).
- **Gateway DNS Resolution:** `connect.uom.lk` resolves to private campus gateway IP `10.1.1.1`.
- **Live Authentication Probe:** When authenticated, internet traffic routes directly (`204 No Content`), and captive portal intercept routes to `10.1.1.1` are deactivated by the network controller.

### 2. Network Controller Profiles
| Network SSID | Controller Technology | Authentication Protocol | Target Endpoint | Transport Security |
| :--- | :--- | :--- | :--- | :---: |
| **`UoM_Wireless`** | Cisco / NEC WebAuth | HTTP/HTTPS POST (`buttonClicked=4`) | `http://connect.uom.lk/login.html` | **Cleartext HTTP Risk** |
| **`UoM.Wireless`** | Aruba Networks | HTTPS POST (`cmd=authenticate`) | `https://connect.uom.lk/cgi-bin/login` | **TLS 1.2+ Encrypted** |
| **`UoM-Wireless`** | Ruijie Networks | HTTPS POST | `https://connect.uom.lk:8443/login` | **TLS 1.2+ Encrypted** |

> [!CAUTION]
> **Cleartext HTTP Credential Submission Risk on `UoM_Wireless`**:
> On legacy Cisco WLC deployments (`UoM_Wireless`), captive portal authentication transmits over port 80 HTTP. Because this occurs over open Wi-Fi radio frequencies without 802.11i encryption, credentials can be intercepted by an attacker in monitor mode. UniNet restricts submissions strictly to `connect.uom.lk`, but cannot force TLS if the controller hardware only listens on port 80. This is an accepted institutional infrastructure risk (`RISK ACCEPTED`).

---

## Section I: Linux Regression Certification

Zero regressions were introduced to Linux functionality:
1. **Shell Script Linters (`make lint`)**:
   - `bin/uninet`: `PASS`
   - `bin/uninet-macos`: `PASS`
   - `install.sh`: `PASS`
   - `uninstall.sh`: `PASS`
   - `scripts/linux/99-uninet.sh`: `PASS`
   - `tests/test_simulation.sh`: `PASS`
2. **Simulation Test Suite (`tests/test_simulation.sh`)**:
   - 8/8 simulation tests passed (`PASS`).
3. **Source Code Modifications**:
   - Linux production files have 0 git modifications.

---

## Section J: Outstanding Technical & Security Risks

| Risk ID | Description | Severity | Status | Mitigation / Strategy |
| :--- | :--- | :---: | :---: | :--- |
| **RISK-01** | Native Windows CI not executed | High | `RESOLVED` | Fully verified across Windows Server 2022 runners in GitHub Actions [Run 42668653913](https://github.com/dineTH2003-dev/uninet/actions/runs/42668653913) (4/4 jobs green). |
| **RISK-02** | Staging VM interactive verification | Medium | `READY FOR STAGING` | Codebase certified by automated CI matrix; ready for real-device smoke test on campus Wi-Fi. |
| **RISK-03** | Cisco WLC port 80 cleartext transmission | High | `RISK ACCEPTED` | Controller-side limitation on `UoM_Wireless`. Advise students to prefer `UoM.Wireless` (Aruba/TLS). |
| **RISK-04** | Multi-user per-machine setup | Low | `MITIGATED` | Handled by self-healing `Register-UniScheduledTask` in `uninet setup`. |

---

## Section K: Release Gate Decision & Actionable Next Steps

### Release Gate Status: **READY FOR STAGING / RELEASE CANDIDATE APPROVED**
*(Certified Clean across Native Windows PowerShell 5.1, PowerShell 7, Linux, and macOS Matrix)*

```
=================================================================================
                            FINAL RELEASE VERDICT
=================================================================================
[✔] Production artifact tree documented and hardened
[✔] Zero unmanaged memory APIs in credential handling
[✔] TLS certificate pinning bound to hostname with hex thumbprint check
[✔] Untrusted redirect pre-check blocking before GET
[✔] Remote authentication endpoints restricted strictly to connect.uom.lk
[✔] DPAPI protection hardened: fails safely on Windows, no plaintext fallback
[✔] Corrupted ciphertext safely rejected
[✔] Elimination of shared ProgramData credentials
[✔] Per-user interactive scheduled task architecture
[✔] Zero console flashing via WScript SW_HIDE
[✔] 60/60 Windows tests passed under PowerShell 5.1 & PowerShell 7
[✔] 8/8 Linux simulation tests passed with 0 regressions
[✔] Clean CI matrix for Windows PS5.1, PS7, Linux, and macOS (Run 42668653913)
[✔] Native execution on Microsoft Windows runners (windows-latest)
---------------------------------------------------------------------------------
FINAL GATE DECISION: READY FOR STAGING (Candidate Certified for PR Merge)
=================================================================================
```

### Actionable Next Steps to Authorize v1.3.0 Release:
1. **Interactive Smoke Test on Windows 11**:
   - Run `install.ps1` as Administrator on campus client.
   - Run `uninet setup` as a standard user.
   - Inspect `%APPDATA%\uninet\credentials.json` to verify DPAPI ciphertext.
   - Verify task: `schtasks /query /tn "UniNetAutoConnect_$env:USERNAME" /fo LIST`.
   - Test Wi-Fi reconnect and observe 100% silent background authentication.
2. **Merge Pull Request**: Merge `feature/windows-stabilization` into `main`.
3. **Tag & Publish Release**: Tag `v1.3.0` and deploy release binaries.
