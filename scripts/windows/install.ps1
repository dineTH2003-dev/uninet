# ==============================================================================
# UniNet - Windows One-Step Turnkey Installer (PowerShell)
#
# Usage (Run in PowerShell as Administrator):
#   irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/install.ps1 | iex
# ==============================================================================

# FIX 6: Use Continue — risky steps wrapped in try/catch, no silent crash on first error
$ErrorActionPreference = "Continue"

# FIX 8: Enable TLS 1.2/1.3 immediately — required for GitHub HTTPS on Windows 7/8/PS3/PS4
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
} catch {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    } catch { }
}

# Set CurrentUser execution policy so installed scripts run without extra prompts
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction SilentlyContinue
} catch { }

# ---------------------------------------------------------------------------
# 1. Paths & Source Acquisition
# ---------------------------------------------------------------------------
$InstallDir  = "C:\ProgramData\uninet"
$RepoRawUrl  = "https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"
$ReleaseZip  = "https://github.com/dineTH2003-dev/uninet/releases/latest/download/uninet-windows.zip"
$ScriptDest  = "$InstallDir\uninet_core.ps1"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Security Hardening: Ensure strict permissions on installation directory.
# Unprivileged users get ReadAndExecute only — prevent Local Privilege Escalation (LPE).
try {
    $dirInfo = New-Object System.IO.DirectoryInfo($InstallDir)
    # Scoped strictly to Access (DACL) to avoid triggering SeSecurityPrivilege
    $acl = $dirInfo.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $false)
    $usersSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545") # BUILTIN\Users
    $existingRules = @($acl.Access | Where-Object { $_.IdentityReference -eq $usersSid -or $_.IdentityReference.Value -like "*Users*" })
    foreach ($r in $existingRules) {
        try { $acl.RemoveAccessRule($r) | Out-Null } catch { }
    }
    $readRule   = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $adminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($readRule)
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    if ($dirInfo.PSObject.Methods['SetAccessControl']) {
        $dirInfo.SetAccessControl($acl)
    } else {
        $aclExt = [System.AppDomain]::CurrentDomain.GetAssemblies() |
            ForEach-Object { $_.GetType("System.IO.FileSystemAclExtensions") } |
            Where-Object { $_ -ne $null } | Select-Object -First 1
        if ($aclExt) {
            $setMethod = $aclExt.GetMethod("SetAccessControl", @([System.IO.DirectoryInfo], [System.Security.AccessControl.DirectorySecurity]))
            if ($setMethod) { $setMethod.Invoke($null, @($dirInfo, $acl)) }
            else { Set-Acl -Path $InstallDir -AclObject $acl -ErrorAction SilentlyContinue }
        } else {
            Set-Acl -Path $InstallDir -AclObject $acl -ErrorAction SilentlyContinue
        }
    }
} catch { }

# Enable WLAN-AutoConfig Operational channel so Event 8001 fires reliably on Wi-Fi association
try {
    cmd.exe /c "wevtutil sl Microsoft-Windows-WLAN-AutoConfig/Operational /e:true 2>nul"
} catch { }

# Clean legacy uninet.ps1 if present from older installations
Remove-Item "$InstallDir\uninet.ps1" -Force -ErrorAction SilentlyContinue

# Check if running from a local clone (dev workflow)
$LocalScript = $null
if ($PSScriptRoot) {
    $c1 = Join-Path $PSScriptRoot "..\..\bin\uninet.ps1"
    $c2 = Join-Path $PSScriptRoot "bin\uninet.ps1"
    if (Test-Path $c1) { $LocalScript = $c1 }
    elseif (Test-Path $c2) { $LocalScript = $c2 }
} elseif (Test-Path ".\bin\uninet.ps1") {
    $LocalScript = ".\bin\uninet.ps1"
}

if ($LocalScript) {
    Copy-Item -Path $LocalScript -Destination $ScriptDest -Force
} else {
    $downloaded = $false

    # Strategy 1: Direct raw file download — fastest, always latest
    if (-not $downloaded) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "UniNet-Windows-Installer")
            $wc.DownloadFile("$RepoRawUrl/bin/uninet.ps1", $ScriptDest)
            if ((Test-Path $ScriptDest) -and ((Get-Item $ScriptDest).Length -gt 500)) {
                $downloaded = $true
            }
        } catch { }
    }

    # Strategy 2: Invoke-WebRequest with explicit headers
    if (-not $downloaded) {
        try {
            $headers = @{ "User-Agent" = "UniNet-Windows-Installer" }
            Invoke-WebRequest -Uri "$RepoRawUrl/bin/uninet.ps1" -OutFile $ScriptDest `
                -Headers $headers -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            if ((Test-Path $ScriptDest) -and ((Get-Item $ScriptDest).Length -gt 500)) {
                $downloaded = $true
            }
        } catch { }
    }

    # Strategy 3: Invoke-RestMethod stream
    if (-not $downloaded) {
        try {
            $headers   = @{ "User-Agent" = "UniNet-Windows-Installer" }
            $rawScript = Invoke-RestMethod -Uri "$RepoRawUrl/bin/uninet.ps1" `
                -Headers $headers -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            if ($rawScript -and $rawScript.Length -gt 500) {
                Set-Content -Path $ScriptDest -Value $rawScript -Encoding UTF8
                $downloaded = $true
            }
        } catch { }
    }

    # Strategy 4: Release zip archive extraction
    if (-not $downloaded) {
        $tempZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "uninet-win.zip")
        try {
            Invoke-WebRequest -Uri $ReleaseZip -OutFile $tempZip -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            if ((Test-Path $tempZip) -and ((Get-Item $tempZip).Length -gt 500)) {
                Expand-Archive -Path $tempZip -DestinationPath $InstallDir -Force
                if (Test-Path "$InstallDir\uninet.ps1") {
                    Move-Item -Path "$InstallDir\uninet.ps1" -Destination $ScriptDest -Force
                    $downloaded = $true
                }
            }
        } catch { }
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    }

    if (-not $downloaded -or -not (Test-Path $ScriptDest)) {
        Write-Error "Failed to install UniNet engine. Please check your internet connection."
        exit 1
    }
}

# Unblock downloaded file so SmartScreen / Defender don't flag the Mark of the Web
Unblock-File "$ScriptDest" -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 2. Create uninet.cmd wrapper & uninet_silent.vbs runner
# ---------------------------------------------------------------------------
$CmdDest    = "$InstallDir\uninet.cmd"
$CmdContent = "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ScriptDest`" %*"
Set-Content -Path $CmdDest -Value $CmdContent -Encoding ASCII
Unblock-File "$CmdDest" -ErrorAction SilentlyContinue

# Silent VBScript launcher: runs PowerShell with SW_HIDE (0) so zero console windows flash
$VbsDest    = "$InstallDir\uninet_silent.vbs"
$VbsContent = "Set WshShell = CreateObject(`"WScript.Shell`")`r`nWshShell.Run `"powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"`"$ScriptDest`"`" login -Quiet`", 0, False"
Set-Content -Path $VbsDest -Value $VbsContent -Encoding ASCII
Unblock-File "$VbsDest" -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 3. Add InstallDir to PATH (Machine scope, fall back to User scope)
# ---------------------------------------------------------------------------
$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -notlike "*$InstallDir*") {
    try {
        [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$InstallDir", "Machine")
        $env:Path = "$env:Path;$InstallDir"
    } catch {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($UserPath -notlike "*$InstallDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
            $env:Path = "$env:Path;$InstallDir"
        }
    }
}


# ---------------------------------------------------------------------------
# 4. Register Windows Task Scheduler — auto-connect on Wi-Fi join
# ---------------------------------------------------------------------------
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ([string]::IsNullOrWhiteSpace($currentUser)) {
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
}
$userClean = $env:USERNAME
if (-not $userClean) { $userClean = ($currentUser -split '\\')[-1] }
$TaskName  = "UniNetAutoConnect_$userClean"
$Action    = "wscript.exe"
$Arguments = "//nologo `"$VbsDest`""

# Remove legacy and current task versions
$null = cmd.exe /c "schtasks /delete /tn `"UniNetAutoConnect`" /f >nul 2>nul"
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

# Complete Task XML definition:
# 1. Triggers on NetworkProfile Event 10000 (Universal network connection on Windows 10/11)
# 2. Triggers on WLAN-AutoConfig Event 8001 (Wi-Fi association)
# 3. Triggers on User Logon (with 5s delay for sleep/resume, unlock, and startup)
# 4. Runs as current user ($currentUser) with InteractiveToken and LeastPrivilege:
#    - Runs inside the user security context with access to %APPDATA%\uninet\credentials.json
#    - Complete isolation between users on multi-user systems
#    - 100% invisible background execution via wscript.exe and SW_HIDE (0)
# 5. Allows running on battery power (DisallowStartIfOnBatteries = false)
$TaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;Query Id="1" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;&lt;Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;*[System[(EventID=8001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5S</Delay>
      <UserId>$currentUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$currentUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$Action</Command>
      <Arguments>$Arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$TempXml = "$env:TEMP\uninet_task.xml"
Set-Content -Path $TempXml -Value $TaskXml -Encoding Unicode
$regOutput = cmd.exe /c "schtasks /create /tn `"$TaskName`" /xml `"$TempXml`" /f 2>&1"
Remove-Item $TempXml -Force -ErrorAction SilentlyContinue

# Fallback: if schtasks XML creation failed, register via native PowerShell cmdlets
$taskExists = $false
$verify = schtasks /query /tn $TaskName /fo LIST 2>$null
if ($verify -match $TaskName) {
    $taskExists = $true
} else {
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel LeastPrivilege
        $taskAct   = New-ScheduledTaskAction -Execute $Action -Argument $Arguments
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
        $logonTrig = New-ScheduledTaskTrigger -AtLogOn
        $logonTrig.Delay = "PT5S"
        Register-ScheduledTask -TaskName $TaskName -Action $taskAct -Principal $principal -Settings $settings -Trigger $logonTrig -Force | Out-Null
        $taskExists = $true
    } catch { }
}

if ($taskExists) {
    Write-Host "[+] Auto-connect task verified: '$TaskName' is active in Task Scheduler." -ForegroundColor Green
} else {
    Write-Host "[!] Warning: Task '$TaskName' could not be registered automatically." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. Launch interactive setup in a fresh PowerShell process
# ---------------------------------------------------------------------------
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$ScriptDest" setup

