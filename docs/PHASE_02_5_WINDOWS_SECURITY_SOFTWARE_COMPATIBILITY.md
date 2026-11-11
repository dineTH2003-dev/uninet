# UniNet Phase 02.5: Windows Security Software Compatibility, Firewall & Endpoint Protection Audit

**Document:** `docs/PHASE_02_5_WINDOWS_SECURITY_SOFTWARE_COMPATIBILITY.md`  
**Repository:** `https://github.com/dineTH2003-dev/uninet`  
**Branch:** `feature/windows-stabilization`  
**Baseline Commit:** `60dc2c80a6aba997a6cdc676aa35c56461bfc3db`  
**Baseline Version:** `v1.2.4`  
**Author / Roles:** Application Security Architect, Windows Systems Engineer, Network Security Analyst  
**Status:** READ-ONLY COMPREHENSIVE ENGINEERING AUDIT  

---

## 1. Executive Summary

This report delivers a rigorous engineering audit of UniNet's compatibility with native Windows security subsystems, enterprise endpoint controls, and commercial third-party antivirus suites. 

### Core Audit Principles:
1. **Zero Evasion:** UniNet must never attempt to bypass, disable, unhook, or evade security software.
2. **Strict Demarcation:** Tested compatibility (empirically observed on test hardware/CI) is strictly distinguished from theoretical architectural compatibility.
3. **Transparency:** Every potential detection vector is identified along with its legitimate, enterprise-compliant resolution.

---

## 2. Workstream C: Microsoft Defender Antivirus & Third-Party AV

### 2.1 Microsoft Defender Antivirus Subsystems

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                      MICROSOFT DEFENDER COMPONENT COMPATIBILITY                        │
├────────────────────────────────┬───────────┬───────────────────────────────────────────┤
│ Defender Feature               │ Status    │ Engineering Compatibility Analysis        │
├────────────────────────────────┼───────────┼───────────────────────────────────────────┤
│ Real-Time File Scanning        │ COMPLIANT │ Scripts reside in C:\ProgramData\uninet;  │
│                                │           │ no obfuscation, no packed binaries.      │
├────────────────────────────────┼───────────┼───────────────────────────────────────────┤
│ Cloud-Delivered Protection     │ COMPLIANT │ Script AST contains standard .NET classes │
│ (MAPS / Spynet)                │           │ (HttpWebRequest, ProtectedData).          │
├────────────────────────────────┼───────────┼───────────────────────────────────────────┤
│ Behavior Monitoring (Heuristics│ COMPLIANT │ No process injection, no memory dumping,  │
│                                │           │ no persistence outside Task Scheduler.    │
├────────────────────────────────┼───────────┼───────────────────────────────────────────┤
│ Controlled Folder Access (CFA) │ COMPLIANT │ Target paths (ProgramData & AppData) are  │
│ (Ransomware Protection)        │           │ outside CFA default user document lists.  │
├────────────────────────────────┼───────────┼───────────────────────────────────────────┤
│ Potentially Unwanted Apps (PUA)│ COMPLIANT │ Zero bundling, zero telemetry beacons,    │
│                                │           │ zero adware/cryptominers.                 │
└────────────────────────────────┴───────────┴───────────────────────────────────────────┘
```

#### Detailed Subsystem Analysis:
1. **Antimalware Scan Interface (AMSI):**
   - In Windows 10/11, PowerShell content is passed into the AMSI buffer (`AmsiScanBuffer`) before execution.
   - Malicious scripts frequently employ base64 payload decoding (`[System.Convert]::FromBase64String`), XOR obfuscation, or invoke unmanaged memory APIs (`VirtualAlloc`, `WriteProcessMemory`).
   - *UniNet Audit:* All PowerShell code in `bin/uninet.ps1` is 100% human-readable plain text with documented function signatures. It does not use reflective DLL loading, AMSI bypass patching (`amsiInitFailed`), or memory tampering. It passes AMSI evaluation without flagging.
2. **Attack Surface Reduction (ASR) Rules:**
   - In enterprise-managed Windows 11 machines, IT administrators enable Microsoft Defender ASR rules.
   - **Risk Vector (ASR Rule `D3E037E1-3EB8-44C8-A917-57927947596D`):** *"Block JavaScript or VBScript to launch downloaded executable content"*. If this rule is set to `Block`, `wscript.exe` invoking `powershell.exe` from `uninet_silent.vbs` can be blocked.
   - *Remediation:* For enterprise-hardened machines, the scheduled task can be configured to execute `powershell.exe` directly with parameters `-NoProfile -NonInteractive -WindowStyle Hidden -File ...`, bypassing the VBScript intermediary.
3. **One-Line Web Installer Pattern (`irm | iex`):**
   - The quick-install command `irm ... | iex` is widely used in modern developer tools (e.g., Chocolatey, Scoop, Winget-install, Homebrew).
   - However, EDR heuristics (e.g. Defender for Endpoint / MDE) monitor command lines for `Invoke-Expression` consuming web streams (MITRE ATT&CK T1059.001).
   - *Recommendation:* While consumer Windows Defender allows `irm | iex`, the documentation must always provide a safe two-step installation alternative (`git clone` or downloading `install.ps1` and inspecting before running).

---

### 2.2 Third-Party Antivirus & Endpoint Protection Analysis

> [!IMPORTANT]
> **Audit Classification Disclosure**:
> The compatibility ratings below represent **theoretical architectural analysis** based on published vendor detection engines and behavioral heuristics. Only Microsoft Defender has been directly verified in automated Windows CI. No third-party antivirus product may be certified as fully tested until physical observation data is recorded.

```
┌─────────────────┬─────────────┬────────────────────────────────────────────────────────┐
│ Security Vendor │ Lab Status  │ Heuristic & Behavioral Analysis                        │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ Bitdefender     │ THEORETICAL │ Advanced Threat Defense monitors script execution.     │
│                 │             │ Safe: uninet.cmd invokes standard PowerShell binary.   │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ ESET NOD32      │ THEORETICAL │ Script Scanner inspects PowerShell commands via AMSI.  │
│                 │             │ Safe: No obfuscation or suspicious memory allocations. │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ Kaspersky       │ THEORETICAL │ System Watcher monitors process lineage.               │
│                 │             │ Potential alert on VBScript spawning PowerShell.       │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ Norton 360      │ THEORETICAL │ SONAR heuristic engine monitors outbound connections.  │
│                 │             │ Safe: Outbound HTTP/HTTPS to port 80/443 is normal.    │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ McAfee (Trellix)│ THEORETICAL │ Dynamic Application Containment (DAC). Safe when run   │
│                 │             │ from standard ProgramData paths with valid ACLs.       │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ Avast / AVG     │ THEORETICAL │ CyberCapture sandbox may temporarily hold new scripts. │
│                 │             │ Code-signing certificate eliminates reputation hold.   │
├─────────────────┼─────────────┼────────────────────────────────────────────────────────┤
│ Malwarebytes    │ THEORETICAL │ Exploit Protection monitors script host vulnerabilities│
│                 │             │ Safe: Uses standard .NET HttpWebRequest.               │
└─────────────────┴─────────────┴────────────────────────────────────────────────────────┘
```

#### Legitimate Resolution Policy for False Positives:
If a third-party antivirus flags UniNet on a student machine:
1. **Never create broad folder exclusions** (e.g., excluding `C:\ProgramData` creates severe security exposure).
2. Inspect the exact detection signature (e.g., `Heur.Script.Generic`, `PowerShell.SuspiciousActivity`).
3. Submit the script to the vendor's official false-positive verification portal (e.g., Microsoft Security Intelligence False Positive Submission, VirusTotal).
4. Deploy official code-signing (Authenticode) to establish verified publisher reputation.

---

## 3. Workstream D: SmartScreen, UAC & Windows Application Control

### 3.1 Microsoft Defender SmartScreen & Mark-of-the-Web (MOTW)
- **Mark of the Web (MOTW):** When users download a `.ps1`, `.cmd`, or `.zip` file from the web via Edge or Chrome, Windows attaches an alternate data stream named `Zone.Identifier` containing `[ZoneTransfer] ZoneId=3` (Internet).
- **SmartScreen Warning:** If an unblocked `.cmd` or `.ps1` with MOTW is launched, SmartScreen presents:
  *"Windows protected your PC — Microsoft Defender SmartScreen prevented an unrecognized app from starting"*.
- **UniNet Architectural Defense:** In `install.ps1`, UniNet explicitly calls `Unblock-File` on all downloaded and generated files:
  ```powershell
  Unblock-File "$ScriptDest" -ErrorAction SilentlyContinue
  Unblock-File "$CmdDest"    -ErrorAction SilentlyContinue
  Unblock-File "$VbsDest"    -ErrorAction SilentlyContinue
  ```
  This removes the `Zone.Identifier` stream, preventing SmartScreen popup friction once installed.

### 3.2 UAC & Privilege Separation Architecture
UniNet enforces strict privilege boundary separation:
1. **Installation Time (Elevated Admin Required):**
   - Reason: Writing to `C:\ProgramData\uninet`, setting machine NTFS ACLs, modifying machine `PATH`, and running `wevtutil` to activate the WLAN-AutoConfig Operational channel require administrative elevation (`BUILTIN\Administrators`).
2. **Runtime (Standard User Only):**
   - Reason: Background auto-login, manual login, and setup execute **without administrative rights**.
   - `uninet.cmd` does **not** contain UAC elevation requests (`runas`).
   - The scheduled task runs with `<RunLevel>LeastPrivilege</RunLevel>`.
   - **Security Benefit:** If an attacker compromised the UniNet process or student user context, they gain zero administrative permissions.

### 3.3 PowerShell Execution Policies & Constrained Language Mode
- **Execution Policy Levels:**
  - `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`: Executed during installation so the user's profile permits local scripts.
  - Script wrappers (`uninet.cmd` and `uninet_silent.vbs`) invoke `powershell.exe -ExecutionPolicy Bypass`.
- **Windows Defender Application Control (WDAC) & AppLocker:**
  - In locked-down corporate or institutional laptops running AppLocker or WDAC, PowerShell is automatically forced into **Constrained Language Mode** (`$ExecutionContext.SessionState.LanguageMode = ConstrainedLanguage`).
  - In Constrained Language Mode, custom .NET object creation and invoking unmanaged APIs are restricted.
  - *Compatibility Assessment:* UniNet's core functions use standard cmdlets (`Get-NetConnectionProfile`, `Get-NetRoute`, `Invoke-WebRequest`) and supported .NET primitives (`[System.Uri]`, `[System.Security.Cryptography.ProtectedData]`). DPAPI calls work in Constrained Language mode because `ProtectedData` is a core trusted assembly in the Global Assembly Cache (GAC).

---

## 4. Workstream E: Firewall, VPN & Proxy Interference

### 4.1 Microsoft Defender Firewall Compatibility
- **Inbound Connections:** UniNet requires **ZERO inbound firewall rules**. It does not bind or listen on any TCP or UDP ports during normal operation. (Local test loopback listeners are strictly confined to offline mock unit testing).
- **Outbound Connections:**
  - UniNet initiates outbound connections to:
    - Port 80 (HTTP) to `connectivitycheck.gstatic.com` and `connect.uom.lk`.
    - Port 443 (HTTPS) to `connect.uom.lk` and `connectivity-check.ubuntu.com`.
    - Port 8443 (HTTPS) to `connect.uom.lk:8443`.
  - On default Windows Defender Firewall profiles (Domain, Private, Public), **all outbound connections are allowed by default**. UniNet requires no firewall modifications.

### 4.2 Proxy & WPAD Auto-Discovery Architecture
In Phase 02.3.1, UniNet implemented the explicit proxy policy engine:
```powershell
function Get-UniProxyForUri {
    param([System.Uri]$TargetUri, [switch]$CaptivePortalProbe)
    # Rule 1: Loopback addresses -> Bypass proxy ($null)
    # Rule 2: Captive portal probes -> Bypass proxy ($null) to hit local gateway
    # Rule 3: $env:UNINET_PROXY override -> Honors user-configured proxy
    # Rule 4: General internet requests -> Resolves system web proxy
}
```
- **Captive Portal Gateway Interception:** Probing the portal via an upstream corporate proxy fails because the proxy attempts to resolve the URL on its remote network rather than letting the local wireless gateway intercept port 80. By setting `$req.Proxy = $null` on portal probes, UniNet guarantees that TCP port 80 is intercepted by the local campus router.
- **WPAD Auto-Discovery Mitigation:** Setting `$req.Proxy = $null` eliminates the 5–10 second WPAD DHCP/DNS query stall observed on default .NET `HttpWebRequest` executions.

### 4.3 VPN Tunnel Interference Analysis
When a student connects to campus Wi-Fi while an automatic VPN client (e.g., Cisco AnyConnect, WireGuard, OpenVPN, Cloudflare WARP) is running with a **Kill Switch** enabled:
1. The VPN software immediately blocks all non-VPN outbound network traffic to prevent IP leaks.
2. The initial captive portal probe to `http://connectivitycheck.gstatic.com/generate_204` cannot reach the local gateway router; it is dropped by the VPN filter driver (e.g., WFP - Windows Filtering Platform).
3. The gateway cannot inject the HTTP 302 redirect. UniNet records `PORTAL_UNREACHABLE` or `AUTHENTICATION_TIMEOUT`.
4. **Engineering Policy:** UniNet **must never silently terminate or alter a user's VPN connection**. Instead, when an authentication timeout occurs, UniNet must detect the presence of an active VPN virtual adapter (e.g., `tun`, `tap`, `wireguard`, `anyconnect`) and report a structured warning:
   ```
   [!] Diagnostic Warning: Active VPN adapter detected ('WireGuard Tunnel').
   [!] Captive portal gateway traffic may be blocked by your VPN kill switch.
   [!] Please temporarily disconnect your VPN until campus authentication completes.
   ```

---

## 5. Code Signing & Release Distribution Recommendations

To achieve production-grade compatibility across all Windows security systems, the following distribution roadmap is established:

```
┌──────────────────────────────────────┬─────────────────────────────────────────────────┐
│ Distribution Channel                 │ Security Recommendation                         │
├──────────────────────────────────────┼─────────────────────────────────────────────────┤
│ GitHub Releases (ZIP / Standalone)   │ Sign executables with Authenticode certificate. │
│                                      │ Eliminates SmartScreen unrecognized app alerts. │
├──────────────────────────────────────┼─────────────────────────────────────────────────┤
│ Windows Package Manager (winget)     │ Submit official manifest to winget-pkgs repo.   │
│                                      │ Establishes Microsoft-verified package status.  │
├──────────────────────────────────────┼─────────────────────────────────────────────────┤
│ Turnkey Web Installer (install.ps1)  │ Sign install.ps1 with trusted code-signing cert │
│                                      │ using Set-AuthenticodeSignature.                │
└──────────────────────────────────────┴─────────────────────────────────────────────────┘
```
