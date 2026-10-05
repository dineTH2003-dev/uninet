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

# FIX 9: Remove legacy uninet_silent.vbs if present from old installs
Remove-Item "$InstallDir\uninet.ps1"       -Force -ErrorAction SilentlyContinue
Remove-Item "$InstallDir\uninet_silent.vbs" -Force -ErrorAction SilentlyContinue

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
# 2. Create uninet.cmd wrapper — allows typing 'uninet' in CMD or PowerShell
# ---------------------------------------------------------------------------
$CmdDest    = "$InstallDir\uninet.cmd"
$CmdContent = "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ScriptDest`" %*"
Set-Content -Path $CmdDest -Value $CmdContent -Encoding ASCII
Unblock-File "$CmdDest" -ErrorAction SilentlyContinue

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
# 4. Register Windows Task Scheduler — triggers on Wi-Fi connect (Event 8001)
# FIX 9: Direct powershell.exe with <Hidden>true</Hidden> — no VBScript launcher
# FIX 7: Task Scheduler reads credentials from C:\ProgramData\uninet\credentials.json
# ---------------------------------------------------------------------------
$TaskName  = "UniNetAutoConnect"
$Action    = "powershell.exe"
$Arguments = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$ScriptDest`" login -Quiet"

# Remove old task silently
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

# XML-based task — triggers on WLAN-AutoConfig Event 8001 (Wi-Fi Connection Succeeded)
$TaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;&lt;Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;*[System[(EventID=8001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
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
$null = cmd.exe /c "schtasks /create /tn `"$TaskName`" /xml `"$TempXml`" /f >nul 2>nul"
Remove-Item $TempXml -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 5. Launch interactive setup in a fresh PowerShell process
# ---------------------------------------------------------------------------
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$ScriptDest" setup
