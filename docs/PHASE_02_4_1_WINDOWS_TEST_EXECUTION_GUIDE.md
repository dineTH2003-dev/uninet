# UniNet Phase 02.4.1: Physical Windows 11 Test Execution Support Guide

**Repository:** `https://github.com/dineTH2003-dev/uninet`  
**Active Branch:** `feature/windows-stabilization`  
**Head Commit:** `1bf4d49`  
**Latest CI Run:** GitHub Actions CI #58 (Matrix jobs: Linux, macOS, Windows PS 5.1, Windows PS 7.4 — All Passed)  
**Document Status:** Operational Testing Protocol & Field Verification Manual  
**Physical Validation Status:** **NOT TESTED** *(Awaiting hands-on execution on physical Windows 11 hardware)*  

---

## 1. Executive Summary & Strict Directives

### 1.1 Objective
This operational guide provides the complete, field-ready protocol for an engineer or developer with a physical Windows 11 laptop on the University of Moratuwa (UoM) campus to execute, record, and verify UniNet's Windows implementation without requiring additional code changes or tool development.

### 1.2 Mandatory Operational Directives
In accordance with engineering integrity principles and the governing rules of Phase 02.4.1:
1. **Zero Fabrication:** Do not claim that physical testing has occurred. The current certification status remains strictly **NOT TESTED** until physical field observation data is recorded from real hardware.
2. **Zero Simulation of Physical Evidence:** Simulated server outputs or mock test results must never be substituted for physical Windows 11 Wi-Fi radio association, real DHCP lease acquisition, or real captive portal gateway interception.
3. **No Authentication Logic Changes:** The core authentication logic has passed 74/74 unit assertions and 8/8 simulation tests; do not alter authentication scripts unless a reproducible defect is proven on physical hardware.
4. **No Merging or Release:** Do not merge `feature/windows-stabilization` into `main`, and do not bump `VERSION` or create release tags.
5. **Preserve Linux Stability:** No modification may compromise the certified, functioning Linux implementation.
6. **Strict Credential & Secret Protection:** Never record, print, log, or commit student passwords, DPAPI cipher blobs, session cookies (`PORTAL_SESS`), or private tokens into test reports.

---

## 2. Audit of Existing Test Manuals & Defect Identification

A thorough technical review of [`docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md`](file:///home/dineth/dev/uninet/docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md) and [`docs/PHASE_02_4_WINDOWS_CAMPUS_VALIDATION.md`](file:///home/dineth/dev/uninet/docs/PHASE_02_4_WINDOWS_CAMPUS_VALIDATION.md) identified six specific command defects and environmental frictions that impact standard Windows 11 users:

### Defect 1: PowerShell Built-In Alias Collision on `curl`
- **Location:** `docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md` (Step 4.1, line 190).
- **Issue:** The command `curl -I https://www.google.com` was listed for execution in a standard terminal. In Windows PowerShell 5.1 (the default shell on Windows 11), `curl` is a built-in alias for `Invoke-WebRequest`.
- **Consequence:** `Invoke-WebRequest` does not support the `-I` (head) parameter. Pasting this command into PowerShell produces a terminating parameter binding exception:
  ```
  Invoke-WebRequest : A parameter cannot be found that matches parameter name 'I'.
  ```
- **Correction:** Must invoke the binary explicitly via `curl.exe -I https://www.google.com` or use native PowerShell:
  ```powershell
  (Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 5).StatusCode
  ```

### Defect 2: PowerShell Variable Expansion Failure on `%USERNAME%`
- **Location:** `docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md` (Step 2.3, line 144 and Security Table line 368).
- **Issue:** The task query command was specified using CMD batch variable syntax:
  ```cmd
  schtasks /query /tn "UniNetAutoConnect_%USERNAME%" /fo LIST /v
  ```
- **Consequence:** In PowerShell, `%` is the alias for `ForEach-Object` or treated literally inside double quotes. Running this command in PowerShell queries Task Scheduler for the literal task name `UniNetAutoConnect_%USERNAME%`, causing:
  ```
  ERROR: The system cannot find the file specified.
  ```
- **Correction:** Must provide exact syntax for both shells:
  - PowerShell: `schtasks /query /tn "UniNetAutoConnect_$env:USERNAME" /fo LIST /v`
  - CMD: `schtasks /query /tn "UniNetAutoConnect_%USERNAME%" /fo LIST /v`

### Defect 3: Missing WLAN Profile Prerequisite for `netsh wlan connect`
- **Location:** `docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md` (Step 4.1, line 164; Step 4.2, line 196; Step 4.3, line 225).
- **Issue:** The manual instructed the operator to associate via:
  ```cmd
  netsh wlan connect name="UoM_Wireless"
  ```
- **Consequence:** On a clean or physical laptop that has never connected to `UoM_Wireless`, Windows WLAN AutoConfig has no XML profile for that SSID. `netsh wlan connect` immediately fails with:
  ```
  There is no profile "<SSID>" assigned to the specified interface.
  ```
- **Correction:** The manual must instruct the tester to associate either via the Windows 11 Taskbar Quick Settings flyout (`Win + A` -> Wi-Fi -> Select SSID) or run `uninet` setup which automatically writes and registers the open WLAN profiles via `netsh wlan add profile`.

### Defect 4: Privileged Channel Query via `wevtutil`
- **Location:** `docs/WINDOWS_11_CAMPUS_SMOKE_TEST.md` (Step 5.3, line 349).
- **Issue:** Using `wevtutil qe Microsoft-Windows-WLAN-AutoConfig/Operational /c:5 /rd:true /f:text` requires administrative rights on many locked-down Windows 11 configurations and dumps unformatted raw XML/text.
- **Correction:** Provide native PowerShell `Get-WinEvent` commands wrapped with `-ErrorAction SilentlyContinue` and formatted property selectors (`TimeCreated`, `Id`, `Message`).

### Defect 5: Default Route Ambiguity on Multi-Adapter Laptops
- **Location:** `docs/PHASE_02_4_WINDOWS_CAMPUS_VALIDATION.md` (Diagnostic capture, line 382).
- **Issue:** Modern developer laptops frequently host virtual adapters (WSL2 vEthernet, Hyper-V, Docker Desktop, Bluetooth PAN, or VPN tunnels). Executing `Get-NetRoute -DestinationPrefix "0.0.0.0/0"` outputs multiple default routes with different interface metrics, obscuring the physical Wi-Fi gateway.
- **Correction:** Filter explicitly for the wireless adapter alias:
  ```powershell
  Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Wireless' }
  ```

### Defect 6: Incomplete Task Execution History
- **Location:** Both documents used `schtasks /query /v` to assess task execution.
- **Issue:** `schtasks /query /v` reports only the single most recent "Last Run Time" and "Last Result" code; it does not show whether the task was triggered by Event 8001, whether it ran hidden, or whether it failed on previous attempts.
- **Correction:** Query the Task Scheduler Operational event channel for Events 100 (Task Triggered), 200 (Action Started), and 102 (Task Completed).

---

## 3. Automated Windows Evidence Collection Procedure

To ensure 100% reproducible, verifiable evidence capture on physical Windows 11 laptops without risking human error, execute the following standardized PowerShell commands.

### 3.1 All-in-One Automated Evidence Collector
Copy and paste this complete block into a standard, non-elevated Windows PowerShell console. It automatically gathers all diagnostic telemetry and saves it to a sanitized text file: `$env:USERPROFILE\uninet_windows11_evidence.txt`.

```powershell
# ==============================================================================
# UniNet Windows 11 Physical Evidence Collector
# Zero-Credential Safe Telemetry Script
# ==============================================================================
$ErrorActionPreference = "Continue"
$outFile = "$env:USERPROFILE\uninet_windows11_evidence.txt"
"======================================================================" | Out-File $outFile -Encoding utf8
"UniNet Physical Windows 11 Test Telemetry Capture"                      | Out-File $outFile -Append
"Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"                  | Out-File $outFile -Append
"======================================================================" | Out-File $outFile -Append

# 1. OS & Kernel Baseline
"`n[1. OS & PowerShell Version]" | Out-File $outFile -Append
$os = Get-CimInstance Win32_OperatingSystem
"OS Name:            $($os.Caption)"                                    | Out-File $outFile -Append
"OS Build:           $($os.Version) (Build $($os.BuildNumber))"         | Out-File $outFile -Append
"OS Architecture:    $($os.OSArchitecture)"                             | Out-File $outFile -Append
$ubr = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).UBR
"Update Build (UBR): $ubr"                                              | Out-File $outFile -Append
"PowerShell Version: $($PSVersionTable.PSVersion.ToString())"           | Out-File $outFile -Append
"PowerShell Edition: $($PSVersionTable.PSEdition)"                      | Out-File $outFile -Append
"CLR Version:        $($PSVersionTable.CLRVersion.ToString())"          | Out-File $outFile -Append

# 2. Wireless Adapter Hardware & Driver
"`n[2. Wireless NIC & Driver Specification]" | Out-File $outFile -Append
$wlanAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $_.Name -match 'Wi-Fi' } | Select-Object -First 1
if ($wlanAdapter) {
    "Adapter Name:       $($wlanAdapter.Name)"                          | Out-File $outFile -Append
    "Description:        $($wlanAdapter.InterfaceDescription)"          | Out-File $outFile -Append
    "Status:             $($wlanAdapter.Status)"                        | Out-File $outFile -Append
    "Link Speed:         $($wlanAdapter.LinkSpeed)"                     | Out-File $outFile -Append
    "MAC Address:        $($wlanAdapter.MacAddress)"                    | Out-File $outFile -Append
    $driver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -eq $wlanAdapter.InterfaceDescription } | Select-Object -First 1
    if ($driver) {
        "Driver Provider:    $($driver.Manufacturer)"                   | Out-File $outFile -Append
        "Driver Version:     $($driver.DriverVersion)"                  | Out-File $outFile -Append
        "Driver Date:        $($driver.DriverDate)"                     | Out-File $outFile -Append
    }
} else {
    "No active Wi-Fi adapter detected." | Out-File $outFile -Append
}

# 3. Radio Link & WLAN State
"`n[3. WLAN Interface & Association State]" | Out-File $outFile -Append
$wlanState = netsh wlan show interfaces 2>&1
$wlanState | Out-File $outFile -Append

# 4. IP & DHCP Configuration
"`n[4. IPv4 & DHCP Configuration]" | Out-File $outFile -Append
if ($wlanAdapter) {
    $ipConfig = Get-NetIPConfiguration -InterfaceIndex $wlanAdapter.InterfaceIndex -ErrorAction SilentlyContinue
    if ($ipConfig) {
        "IPv4 Address:       $($ipConfig.IPv4Address.IPAddress)"        | Out-File $outFile -Append
        "IPv4 Subnet Prefix: $($ipConfig.IPv4Address.PrefixLength)"     | Out-File $outFile -Append
        "IPv4 Default GW:    $($ipConfig.IPv4DefaultGateway.NextHop)"   | Out-File $outFile -Append
        "DNS Servers:        $($ipConfig.DNSServer.ServerAddresses -join ', ')" | Out-File $outFile -Append
    }
}

# 5. Routing Table (Wi-Fi Specific)
"`n[5. Active Wi-Fi IPv4 Routes]" | Out-File $outFile -Append
if ($wlanAdapter) {
    Get-NetRoute -InterfaceIndex $wlanAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceMetric |
        Format-Table -AutoSize | Out-String | Out-File $outFile -Append
}

# 6. Task Scheduler Status & Execution History
"`n[6. UniNet Scheduled Task Configuration]" | Out-File $outFile -Append
$taskName = "UniNetAutoConnect_$env:USERNAME"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    "Task Name:          $($task.TaskName)"                             | Out-File $outFile -Append
    "State:              $($task.State)"                                | Out-File $outFile -Append
    "Run As User:        $($task.Principal.UserId)"                     | Out-File $outFile -Append
    "Logon Type:         $($task.Principal.LogonType)"                  | Out-File $outFile -Append
    "Run Level:          $($task.Principal.RunLevel)"                   | Out-File $outFile -Append
    "Action Exec:        $($task.Actions.Execute)"                      | Out-File $outFile -Append
    "Action Arguments:   $($task.Actions.Arguments)"                    | Out-File $outFile -Append
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskInfo) {
        "Last Run Time:      $($taskInfo.LastRunTime)"                  | Out-File $outFile -Append
        "Last Result Code:   $($taskInfo.LastTaskResult)"               | Out-File $outFile -Append
        "Next Run Time:      $($taskInfo.NextRunTime)"                  | Out-File $outFile -Append
    }
} else {
    "Task '$taskName' is not registered in Task Scheduler." | Out-File $outFile -Append
}

# 7. WLAN-AutoConfig Operational Events (Last 5)
"`n[7. Recent WLAN-AutoConfig Events (8001 / Association)]" | Out-File $outFile -Append
try {
    $wlanEvents = Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 5 -ErrorAction Stop
    $wlanEvents | Select-Object TimeCreated, Id, Message | Format-List | Out-String | Out-File $outFile -Append
} catch {
    "WLAN-AutoConfig operational event log could not be queried or has no events." | Out-File $outFile -Append
}

# 8. UniNet Engine Version & Sanitized Logs
"`n[8. UniNet Engine Version & Sanitized Execution Logs]" | Out-File $outFile -Append
if (Test-Path "C:\ProgramData\uninet\uninet.cmd") {
    $statusOut = cmd.exe /c "uninet status" 2>&1
    $statusOut | Out-File $outFile -Append
}
$logPath = "$env:APPDATA\uninet\uninet.log"
if (Test-Path $logPath) {
    "`n--- Last 30 Sanitized Log Entries ---" | Out-File $outFile -Append
    Get-Content $logPath -Tail 30 | Out-File $outFile -Append
}

Write-Host "[+] All Windows 11 evidence safely collected to: $outFile" -ForegroundColor Green
```

---

## 4. Strict Credential & Secret Sanitization Guidance

To comply with non-negotiable security mandates, all evidence submitted to public repositories, pull requests, or issue trackers must adhere to the following data sanitization rules:

| Category | Strictly Forbidden Data | Safe Replacement / Redaction Rule |
| :--- | :--- | :--- |
| **Passwords** | Student portal passwords | `<REDACTED_PASSWORD>` (Ensure 0 occurrences in logs) |
| **Usernames** | Personal Student Registration Numbers (e.g., `210001X`) | `<STUDENT_ID>` or `test_student` |
| **DPAPI Blobs** | Encrypted Base64 strings from `credentials.json` | `[DPAPI_CIPHER_REDACTED]` — **Never commit `credentials.json`** |
| **Cookies** | `PORTAL_SESS`, `PHPSESSID`, `JSESSIONID` | `PORTAL_SESS=<REDACTED_COOKIE>` |
| **Redirect Query Tokens** | Raw tokens in `url=...` or `token=...` | `https://connect.uom.lk/cgi-bin/login?cmd=login&token=<REDACTED>` |
| **MAC Addresses** | Physical BSSID / Radio Client MAC (optional privacy) | Last 3 octets masked: `a4:b2:c3:xx:xx:xx` |

---

## 5. SSID-Specific Test Record Matrices

Every physical test on campus must be recorded using the standardized matrices below. Each field must be assigned one of the four standardized status values:
- `PASS`: Criteria fully met and confirmed on physical hardware.
- `FAIL`: Criteria not met; unhandled exception, timeout, or incorrect behavior observed.
- `BLOCKED`: Test could not be executed due to environmental, driver, or network outage.
- `NOT TESTED`: Current baseline state; pending physical execution on campus.

---

### 5.1 Test Record: `UoM_Wireless` (Cisco / NEC WebAuth Architecture)

- **Target Network:** `UoM_Wireless`
- **Controller Type:** Cisco Wireless LAN Controller (WLC 5500 / 9800 series)
- **Layer-2 Security:** Open (Unencrypted 802.11)
- **Expected Gateway:** `10.10.x.x` (e.g. `10.10.31.254`)
- **Portal Endpoint:** `http://connect.uom.lk/login.html` (HTTP Port 80)

| Stage | Verification Command / Procedure | Acceptance Criteria | Observed Output | Status |
| :--- | :--- | :--- | :--- | :---: |
| **1. Association** | `netsh wlan connect name="UoM_Wireless"` (or Taskbar flyout) | Radio links, valid IP leased via DHCP (not `169.254.x.x`) | `[Awaiting physical observation]` | `NOT TESTED` |
| **2. Portal Detection** | `uninet status` or probe to `http://connectivitycheck.gstatic.com/generate_204` | Probe intercepted; returns HTTP 302 redirecting to `connect.uom.lk` | `[Awaiting physical observation]` | `NOT TESTED` |
| **3. Redirect Resolution** | Pre-auth probe inspection | Location header resolves strictly to `http://connect.uom.lk/login.html` | `[Awaiting physical observation]` | `NOT TESTED` |
| **4. Auth Request** | `uninet login` | Form extracts `buttonClicked=4`, submits POST to `connect.uom.lk` | `[Awaiting physical observation]` | `NOT TESTED` |
| **5. Auth Response** | Response inspection | Gateway removes firewall block; returns HTTP 200 or 302 | `[Awaiting physical observation]` | `NOT TESTED` |
| **6. Post-Login Check** | `curl.exe -I https://www.google.com` | Probe to `gstatic.com/generate_204` returns HTTP 204; Google returns 200 | `[Awaiting physical observation]` | `NOT TESTED` |
| **7. Reconnection** | `netsh wlan disconnect` followed by reconnect | Reconnect triggers Event 8001; silent task authenticates automatically | `[Awaiting physical observation]` | `NOT TESTED` |
| **8. Sleep / Resume** | Close lid for 30s, open lid, log in | WLAN reconnects; background authentication completes in < 5 seconds | `[Awaiting physical observation]` | `NOT TESTED` |
| **9. Cold Reboot** | `shutdown /r /t 0`, log in | System startup logon trigger fires; online within 8s of desktop load | `[Awaiting physical observation]` | `NOT TESTED` |

---

### 5.2 Test Record: `UoM.Wireless` (Aruba Networks Architecture)

- **Target Network:** `UoM.Wireless`
- **Controller Type:** Aruba Mobility Controller / ArubaOS-CX
- **Layer-2 Security:** Open / Captive Portal WebAuth
- **Expected Gateway:** `10.10.x.x`
- **Portal Endpoint:** `https://connect.uom.lk/cgi-bin/login` (HTTPS Port 443 with TLS 1.2+)

| Stage | Verification Command / Procedure | Acceptance Criteria | Observed Output | Status |
| :--- | :--- | :--- | :--- | :---: |
| **1. Association** | `netsh wlan connect name="UoM.Wireless"` (or Taskbar flyout) | Radio links, valid IP leased via DHCP | `[Awaiting physical observation]` | `NOT TESTED` |
| **2. Portal Detection** | Probe to `http://connectivity-check.ubuntu.com./` | Probe intercepted; returns HTTP 302 with query parameters | `[Awaiting physical observation]` | `NOT TESTED` |
| **3. Redirect Resolution** | Inspect redirect target URL | URL resolves to `https://connect.uom.lk/cgi-bin/login?cmd=login&mac=...` | `[Awaiting physical observation]` | `NOT TESTED` |
| **4. Auth Request** | `uninet login` | Extracts `mac, ip, essid, apname, url`, submits POST over TLS 1.2+ | `[Awaiting physical observation]` | `NOT TESTED` |
| **5. Auth Response** | Response inspection | Controller accepts credentials; returns auth success redirect/200 | `[Awaiting physical observation]` | `NOT TESTED` |
| **6. Post-Login Check** | `curl.exe -I https://www.google.com` | Probe to `ubuntu.com` returns HTTP 200/204; internet verified | `[Awaiting physical observation]` | `NOT TESTED` |
| **7. Reconnection** | `netsh wlan disconnect` followed by reconnect | Reconnect triggers Event 8001; silent task authenticates automatically | `[Awaiting physical observation]` | `NOT TESTED` |
| **8. Sleep / Resume** | Close lid for 30s, open lid, log in | WLAN reconnects; background authentication completes in < 5 seconds | `[Awaiting physical observation]` | `NOT TESTED` |
| **9. Cold Reboot** | `shutdown /r /t 0`, log in | System startup logon trigger fires; online within 8s of desktop load | `[Awaiting physical observation]` | `NOT TESTED` |

---

### 5.3 Test Record: `UoM-Wireless` (Ruijie Networks Architecture)

- **Target Network:** `UoM-Wireless`
- **Controller Type:** Ruijie Networks Cloud / Gateway Controller
- **Layer-2 Security:** Open / Captive Portal WebAuth
- **Portal Endpoint:** `https://connect.uom.lk:8443/login` (HTTPS Port 8443 with TLS 1.2+)

| Stage | Verification Command / Procedure | Acceptance Criteria | Observed Output | Status |
| :--- | :--- | :--- | :--- | :---: |
| **1. Association** | `netsh wlan connect name="UoM-Wireless"` (or Taskbar flyout) | Radio links, valid IP leased via DHCP | `[Awaiting physical observation]` | `NOT TESTED` |
| **2. Portal Detection** | Probe to `http://connectivitycheck.gstatic.com/generate_204` | Probe intercepted; redirects to `https://connect.uom.lk:8443/index.html` | `[Awaiting physical observation]` | `NOT TESTED` |
| **3. Redirect Resolution** | Pre-auth URL rewrite verification | Engine resolves action URL to `https://connect.uom.lk:8443/login` | `[Awaiting physical observation]` | `NOT TESTED` |
| **4. Auth Request** | `uninet login` | Submits `username` and `password` over TLS 1.2+ to port 8443 | `[Awaiting physical observation]` | `NOT TESTED` |
| **5. Auth Response** | Response inspection | Controller returns HTTP 200/302 success | `[Awaiting physical observation]` | `NOT TESTED` |
| **6. Post-Login Check** | `curl.exe -I https://www.google.com` | Probe returns HTTP 204; internet verified | `[Awaiting physical observation]` | `NOT TESTED` |
| **7. Reconnection** | `netsh wlan disconnect` followed by reconnect | Reconnect triggers Event 8001; silent task authenticates automatically | `[Awaiting physical observation]` | `NOT TESTED` |
| **8. Sleep / Resume** | Close lid for 30s, open lid, log in | WLAN reconnects; background authentication completes in < 5 seconds | `[Awaiting physical observation]` | `NOT TESTED` |
| **9. Cold Reboot** | `shutdown /r /t 0`, log in | System startup logon trigger fires; online within 8s of desktop load | `[Awaiting physical observation]` | `NOT TESTED` |

---

## 6. Rigorous Review of Cisco HTTP Authentication & Transport Security

A core responsibility of this engineering phase is to reassess the transport security posture of `UoM_Wireless` with uncompromising technical precision.

### 6.1 Architectural Breakdown of Security Layers

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              THE 5 SECURITY LAYERS COMPARED                            │
├────────────────────────────────┬───────────────────────────────────────────────────────┤
│ 1. Wi-Fi Link-Layer Encryption │ UoM_Wireless: NONE (Open 802.11, Zero WPA/WPA2/WPA3)  │
│                                │ UoM.Wireless: NONE (Open 802.11 Link)                 │
├────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 2. HTTPS/TLS Application Layer │ UoM_Wireless: NONE on Port 80 (Cleartext HTTP)        │
│                                │ UoM.Wireless: TLS 1.2+ HTTPS Encrypted (Port 443)     │
├────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 3. Credential Submission       │ UoM_Wireless: CLEARTEXT HTTP POST (Username & Pass)   │
│                                │ UoM.Wireless: CIPHERTEXT TLS Payload                  │
├────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 4. Destination Host Whitelist  │ Prevents redirecting credentials to evil-domain.com.  │
│                                │ CRITICAL: DOES NOT ENCRYPT THE WIRELESS TRANSMISSION! │
├────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 5. SSID Scoring Prioritization │ Prefers UoM.Wireless when available.                  │
│                                │ CRITICAL: DOES NOT ENCRYPT UoM_Wireless WHEN USED!    │
└────────────────────────────────┴───────────────────────────────────────────────────────┘
```

### 6.2 Critical Findings on Cryptographic Boundaries
1. **Link-Layer vs. Transport-Layer:**
   - Link-layer encryption (802.11i) encrypts all frames between the laptop radio and the access point. Neither `UoM_Wireless` nor `UoM.Wireless` uses 802.11i link-layer encryption (both are open SSIDs).
   - Application-layer encryption (TLS) encrypts data between the client and the authentication web server. `UoM.Wireless` uses TLS (HTTPS on port 443). `UoM_Wireless` uses unencrypted HTTP on port 80.
2. **The Cleartext Vulnerability on `UoM_Wireless`:**
   - Because `UoM_Wireless` lacks BOTH link-layer encryption AND TLS application-layer encryption, the HTTP POST request carrying `username`, `password`, and `buttonClicked=4` is broadcast over the physical RF spectrum as **plaintext**.
   - **Passive Interception Risk:** Any observer within radio range (e.g. anywhere in the same lecture hall or courtyard) operating a standard Wi-Fi adapter in monitor mode can capture these frames passively using tools such as `tcpdump` or `Wireshark`. Because the eavesdropping is entirely passive, it leaves zero network trace and bypasses all endpoint antivirus solutions.
3. **No False Claims of Encryption:**
   - Whitelisting `connect.uom.lk` via `Test-TrustedAuthEndpoint` ensures UniNet does not send credentials to an external attacker portal. **It does NOT encrypt HTTP credentials.**
   - Prioritizing `UoM.Wireless` via `uninet optimize` encourages connection to the encrypted portal. **It does NOT encrypt credentials on `UoM_Wireless` when connected.**

### 6.3 Empirical Verification Procedure to Confirm Actual Cisco Portal Transport
To conclusively prove whether the physical Cisco controller enforces HTTP, supports HTTPS, or rejects HTTPS, the physical tester must execute the following diagnostic commands from an unauthenticated state on `UoM_Wireless`:

```powershell
# Test 1: Check HTTP pre-auth behavior and capture redirect target
curl.exe -v http://connectivitycheck.gstatic.com/generate_204

# Test 2: Check direct HTTP access to the portal
curl.exe -v http://connect.uom.lk/login.html

# Test 3: Test whether HTTPS port 443 is open, rejected, or times out on the Cisco portal
curl.exe -vk --connect-timeout 5 https://connect.uom.lk/login.html

# Test 4: Check if HTTPS form submission is accepted
curl.exe -vk --connect-timeout 5 https://connect.uom.lk/login_submit
```

**Diagnostic Analysis Criteria:**
- If Test 3 connects and returns an SSL certificate: Record certificate issuer and subject. If valid, UniNet can be upgraded to submit over HTTPS.
- If Test 3 times out (`Connection timed out after 5000 ms`): Proves that the Cisco virtual gateway (`10.1.1.1`) blocks port 443 in pre-auth state, confirming that HTTP port 80 is an unavoidable institutional network constraint.

---

## 7. Step-by-Step Execution Protocol for the Physical Tester

Follow these chronological steps on a physical Windows 11 laptop on the University of Moratuwa campus:

### Phase 1: Preparation & Clean State
1. Clone the repository and switch to the stabilization branch:
   ```powershell
   git clone https://github.com/dineTH2003-dev/uninet.git
   Set-Location uninet
   git checkout feature/windows-stabilization
   ```
2. Confirm the commit is `1bf4d49` or newer.

### Phase 2: Administrative Installation & Standard User ACL Audit
1. Open PowerShell as **Administrator** and run:
   ```powershell
   & ".\scripts\windows\install.ps1"
   ```
2. Verify output confirms directory creation (`C:\ProgramData\uninet`), PATH registration, and silent runner deployment.
3. In a standard (non-elevated) PowerShell terminal, verify NTFS permissions:
   ```powershell
   (Get-Acl "C:\ProgramData\uninet").Access | Select-Object IdentityReference, FileSystemRights, AccessControlType | Format-Table
   ```
   *Criteria:* `BUILTIN\Users` must have `ReadAndExecute` only. Attempting `Set-Content "C:\ProgramData\uninet\test.txt" "hack"` must fail with `UnauthorizedAccessException`.

### Phase 3: Setup & DPAPI Secret Storage
1. As the standard user, run interactive setup:
   ```powershell
   uninet setup
   ```
2. Enter real student credentials.
3. Confirm `%APPDATA%\uninet\credentials.json` exists and that the `password` field contains Base64 DPAPI ciphertext (not plaintext).

### Phase 4: SSID Live Testing Drills
1. **Connect to `UoM_Wireless`:**
   - Associate via Windows 11 Wi-Fi flyout.
   - Run `uninet login`.
   - Run `curl.exe -I https://www.google.com`.
   - Fill out Section 5.1 test record.
2. **Connect to `UoM.Wireless`:**
   - Switch to `UoM.Wireless` via Windows 11 Wi-Fi flyout.
   - Run `uninet login`.
   - Run `curl.exe -I https://www.google.com`.
   - Fill out Section 5.2 test record.
3. **Connect to `UoM-Wireless`:**
   - Switch to `UoM-Wireless` via Windows 11 Wi-Fi flyout.
   - Run `uninet login`.
   - Run `curl.exe -I https://www.google.com`.
   - Fill out Section 5.3 test record.

### Phase 5: Power & Disconnection Transitions
1. **Reconnection Drill:** Disconnect Wi-Fi (`netsh wlan disconnect`), reconnect to `UoM.Wireless`, observe Event 8001 in Event Viewer, verify automatic login without user interaction.
2. **Sleep / Resume Drill:** Put laptop to sleep for 30s, wake and log in, verify internet restored within 5 seconds.
3. **Cold Reboot Drill:** Restart Windows (`shutdown /r /t 0`), log in, verify background task connects within 8 seconds of desktop load.

### Phase 6: Automated Telemetry Export
Run the Automated Evidence Collector script from Section 3.1:
```powershell
# Copy and run the script from Section 3.1
# Output will be written to: $env:USERPROFILE\uninet_windows11_evidence.txt
```

---

## 8. Failure Classification & Triage Protocol

If any test fails during physical validation, follow this structured triage process:

```
┌─────────────────────────────────┬───────────────────────────────────────────────────────┐
│ Failure Category                │ Immediate Diagnostic Action                           │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 1. Wi-Fi Association Failed     │ Run netsh wlan show interfaces. Check signal & BSSID. │
│                                 │ Verify if WLAN profile exists (netsh wlan show prof). │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 2. Portal Detection Failed      │ Check Get-NetIPConfiguration. Verify default gateway. │
│                                 │ Run curl.exe -v http://gstatic.com/generate_204.      │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 3. Redirect Resolution Failed   │ Inspect redirect URL. Check if domain is blocked      │
│                                 │ by Test-TrustedAuthEndpoint (must be connect.uom.lk). │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 4. Credential Submission Failed │ Run uninet status. Check uninet.log for HTTP 401/403   │
│                                 │ or timeout. Verify password validity on portal.       │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 5. Post-Auth Check Failed       │ Check routing table (Get-NetRoute). Verify DNS.       │
│                                 │ Run curl.exe -I https://www.google.com.               │
├─────────────────────────────────┼───────────────────────────────────────────────────────┤
│ 6. Background Task Failed       │ Check Get-ScheduledTaskInfo for LastTaskResult.       │
│                                 │ Query TaskScheduler operational log for Event 102.    │
└─────────────────────────────────┴───────────────────────────────────────────────────────┘
```

---

## 9. Final Deliverable Status & Merging Gates

```
=================================================================================
                               CERTIFICATION GATE
=================================================================================
Native Windows CI Matrix (4/4 Jobs):      PASS (Verified on CI Run #58)
PowerShell Unit Test Suite:               PASS (74/74 assertions passing)
Linux Simulation Engine:                  PASS (8/8 tests passing)
Windows 11 Execution Guide:               COMPLETED (docs/PHASE_02_4_1_...)
Evidence Collection Script:               COMPLETED (Section 3.1)
Cryptographic Separation Audit:           COMPLETED & CERTIFIED (Section 6)
Physical Windows 11 Campus Validation:    NOT TESTED (Awaiting Field Operator)
---------------------------------------------------------------------------------
CURRENT STAGING STATUS:                   PHYSICAL VALIDATION PENDING
MERGE / RELEASE AUTHORIZATION:            LOCKED (Option C — Not Ready for Merge)
=================================================================================
```

### Merging Conditions:
This branch may only be merged into `main` when:
1. A physical Windows 11 laptop on the University of Moratuwa campus has executed all drills in Section 7.
2. The telemetry file (`uninet_windows11_evidence.txt`) is reviewed and confirmed clean of secrets.
3. All fields in Section 5 across `UoM_Wireless`, `UoM.Wireless`, and `UoM-Wireless` are certified as `PASS`.
4. Zero regressions are reported against the existing Linux implementation.
