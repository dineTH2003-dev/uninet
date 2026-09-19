# ==============================================================================
# UniNet - Windows Uninstaller (PowerShell)
# ==============================================================================

Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow

$TaskName = "UniNetAutoConnect"
$null = & schtasks /delete /tn $TaskName /f 2>&1

$InstallDir = "C:\ProgramData\uninet"
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$UserDir = "$env:APPDATA\uninet"
if (Test-Path $UserDir) {
    Remove-Item -Path $UserDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "✔ UniNet has been completely removed from your Windows machine." -ForegroundColor Green
