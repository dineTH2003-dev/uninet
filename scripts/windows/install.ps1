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

# 1. Target Paths
$InstallDir = "C:\ProgramData\uninet"
$ScriptSrc = "$PSScriptRoot\bin\uninet.ps1"
$ScriptDest = "$InstallDir\uninet.ps1"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item -Path $ScriptSrc -Destination $ScriptDest -Force
Write-Host "✔ Installed uninet engine to $ScriptDest" -ForegroundColor Green

# 2. Register Windows Task Scheduler trigger on Wi-Fi Connection (Event 8001)
Write-Host "Registering background auto-connect trigger..." -ForegroundColor Cyan

$TaskName = "UniNetAutoConnect"
$Action = "powershell.exe"
$Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDest`" login -Quiet"

# Unregister if previously installed
schtasks /delete /tn $TaskName /f 2>$null | Out-Null

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

try {
    schtasks /create /tn $TaskName /xml $TempXml /f | Out-Null
    Remove-Item $TempXml -Force -ErrorAction SilentlyContinue
    Write-Host "✔ Task Scheduler trigger '$TaskName' registered successfully!" -ForegroundColor Green
} catch {
    Write-Host "Notice: Run PowerShell as Administrator to register background auto-connect." -ForegroundColor Yellow
}

# 3. Launch interactive credentials setup
& "$ScriptDest" setup

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "🎉 Congratulations! UniNet for Windows is fully installed." -ForegroundColor Green
Write-Host "Whenever your Windows laptop connects to university Wi-Fi:" -ForegroundColor Green
Write-Host "  • UoM_Wireless" -ForegroundColor Green
Write-Host "  • UoM.Wireless" -ForegroundColor Green
Write-Host "  • UoM-Wireless" -ForegroundColor Green
Write-Host "It will automatically authenticate in the background!" -ForegroundColor Green
Write-Host "=======================================================`n" -ForegroundColor Green
