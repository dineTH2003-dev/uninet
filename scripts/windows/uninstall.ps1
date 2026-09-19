# ==============================================================================
# UniNet - Windows Uninstaller (PowerShell)
# ==============================================================================

Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow

$TaskName = "UniNetAutoConnect"
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

$InstallDir = "C:\ProgramData\uninet"
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove from PATH
$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -like "*$InstallDir*") {
    $NewPath = ($MachinePath.Split(';') | Where-Object { $_ -ne $InstallDir }) -join ';'
    try { [Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine") } catch { }
}
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -like "*$InstallDir*") {
    $NewPath = ($UserPath.Split(';') | Where-Object { $_ -ne $InstallDir }) -join ';'
    try { [Environment]::SetEnvironmentVariable("Path", $NewPath, "User") } catch { }
}

$UserDir = "$env:APPDATA\uninet"
if (Test-Path $UserDir) {
    Remove-Item -Path $UserDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[+] UniNet has been completely removed from your Windows machine." -ForegroundColor Green
