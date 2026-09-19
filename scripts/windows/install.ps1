# ==============================================================================
# UniNet - Windows One-Step Turnkey Installer (PowerShell)
#
# Usage (Run in PowerShell as Administrator):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\install.ps1
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "         UniNet Windows Auto-Connect Installer         " -ForegroundColor Cyan
Write-Host "=======================================================`n" -ForegroundColor Cyan

# 1. Target Paths & Source Acquisition
$InstallDir = "C:\ProgramData\uninet"
$RepoRawUrl = "https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$ScriptDest = "$InstallDir\uninet.ps1"
$LocalScript = $null

if ($PSScriptRoot) {
    $Candidate1 = Join-Path $PSScriptRoot "..\..\bin\uninet.ps1"
    $Candidate2 = Join-Path $PSScriptRoot "bin\uninet.ps1"
    if (Test-Path $Candidate1) {
        $LocalScript = $Candidate1
    } elseif (Test-Path $Candidate2) {
        $LocalScript = $Candidate2
    }
} elseif (Test-Path ".\bin\uninet.ps1") {
    $LocalScript = ".\bin\uninet.ps1"
}

if ($LocalScript) {
    Copy-Item -Path $LocalScript -Destination $ScriptDest -Force
} else {
    Write-Host "Fetching latest uninet engine from GitHub..." -ForegroundColor Cyan
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch { }
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "UniNet-Installer")
    $wc.DownloadFile("$RepoRawUrl/bin/uninet.ps1", $ScriptDest)
}

# Create uninet.cmd wrapper so users can type 'uninet' in CMD or PowerShell
$CmdDest = "$InstallDir\uninet.cmd"
$CmdContent = "@echo off`r`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ScriptDest`" %*"
[System.IO.File]::WriteAllText($CmdDest, $CmdContent)

# Add to system/user PATH
$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -notlike "*$InstallDir*") {
    try {
        [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$InstallDir", "Machine")
        $env:Path = "$env:Path;$InstallDir"
        Write-Host "[+] Added $InstallDir to System PATH" -ForegroundColor Green
    } catch {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($UserPath -notlike "*$InstallDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
            $env:Path = "$env:Path;$InstallDir"
            Write-Host "[+] Added $InstallDir to User PATH" -ForegroundColor Green
        }
    }
}

Write-Host "[+] Installed uninet engine to $ScriptDest" -ForegroundColor Green

# 2. Register Windows Task Scheduler trigger on Wi-Fi Connection (Event 8001)
Write-Host "Registering background auto-connect trigger..." -ForegroundColor Cyan

$TaskName = "UniNetAutoConnect"
$Action = "powershell.exe"
$Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDest`" login -Quiet"

# Safely unregister old task if present (using cmd /c to completely isolate NativeCommandError)
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

# XML trigger for WLAN-AutoConfig Event 8001 (Connection Succeeded)
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
[System.IO.File]::WriteAllText($TempXml, $TaskXml, [System.Text.Encoding]::Unicode)

$createResult = cmd.exe /c "schtasks /create /tn `"$TaskName`" /xml `"$TempXml`" /f 2>&1"
Remove-Item $TempXml -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
    Write-Host "[+] Task Scheduler trigger '$TaskName' registered successfully!" -ForegroundColor Green
} else {
    Write-Host "Notice: Administrator privileges are required to register background Task Scheduler triggers." -ForegroundColor Yellow
    Write-Host "        (UniNet CLI is still fully functional via 'uninet login' / 'uninet status')" -ForegroundColor Yellow
}

# 3. Launch interactive credentials setup in a dedicated PowerShell process
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$ScriptDest" setup

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "[+] UniNet for Windows is fully installed!" -ForegroundColor Green
Write-Host "Whenever your Windows laptop connects to university Wi-Fi:" -ForegroundColor Green
Write-Host "  - UoM_Wireless" -ForegroundColor Green
Write-Host "  - UoM.Wireless" -ForegroundColor Green
Write-Host "  - UoM-Wireless" -ForegroundColor Green
Write-Host "It will automatically authenticate in the background!" -ForegroundColor Green
Write-Host "=======================================================`n" -ForegroundColor Green
