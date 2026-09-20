# ==============================================================================
# UniNet - Windows Uninstaller (PowerShell)
# ==============================================================================

Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow

# Remove scheduled task
$TaskName = "UniNetAutoConnect"
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

# Remove WLAN profiles registered by 'uninet setup' / 'uninet trust'
foreach ($ssid in @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")) {
    $null = cmd.exe /c "netsh wlan delete profile name=`"$ssid`" >nul 2>nul"
}

# Remove install directory (binary + credentials + assets)
$InstallDir = "C:\ProgramData\uninet"
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove from system PATH
$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -like "*$InstallDir*") {
    $NewPath = ($MachinePath.Split(';') | Where-Object { $_ -ne $InstallDir }) -join ';'
    try { [Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine") } catch { }
}

# Remove from user PATH
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -like "*$InstallDir*") {
    $NewPath = ($UserPath.Split(';') | Where-Object { $_ -ne $InstallDir }) -join ';'
    try { [Environment]::SetEnvironmentVariable("Path", $NewPath, "User") } catch { }
}

# Remove user-scoped config directory
$UserDir = "$env:APPDATA\uninet"
if (Test-Path $UserDir) {
    Remove-Item -Path $UserDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[+] UniNet has been completely removed from your Windows machine." -ForegroundColor Green
