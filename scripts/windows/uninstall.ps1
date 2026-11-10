# ==============================================================================
# UniNet - Windows Uninstaller (PowerShell)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\ProgramData\uninet",
    [string]$UserDir = $(if ($env:APPDATA) { Join-Path $env:APPDATA "uninet" } else { "" }),
    [string]$TaskName = "UniNetAutoConnect",
    [switch]$SkipWlanProfiles
)

Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow

$script:HasCleanupError = $false

# ------------------------------------------------------------------------------
# 1. Scheduled Task Removal (Idempotent with genuine error detection)
# ------------------------------------------------------------------------------
function Remove-UniTaskSafe([string]$tn) {
    if ([string]::IsNullOrWhiteSpace($tn)) { return }
    if ([Environment]::OSVersion.Platform -ne "Win32NT") { return }

    # Check if task exists first
    $null = cmd.exe /c "schtasks /query /tn `"$tn`" >nul 2>&1"
    if ($LASTEXITCODE -ne 0) {
        # Task does not exist — this is safe and expected
        $global:LASTEXITCODE = 0
        return
    }

    # Task exists — attempt removal
    $out = cmd.exe /c "schtasks /delete /tn `"$tn`" /f 2>&1"
    $taskExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($taskExit -ne 0) {
        Write-Error "Failed to delete scheduled task '$tn': $out"
        $script:HasCleanupError = $true
    }
}

Remove-UniTaskSafe -tn $TaskName
if ($env:USERNAME) {
    Remove-UniTaskSafe -tn "${TaskName}_$($env:USERNAME)"
}

# ------------------------------------------------------------------------------
# 2. WLAN Profile Removal
# ------------------------------------------------------------------------------
if (-not $SkipWlanProfiles -and [Environment]::OSVersion.Platform -eq "Win32NT") {
    foreach ($ssid in @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")) {
        $null = cmd.exe /c "netsh wlan delete profile name=`"$ssid`" >nul 2>&1"
        $global:LASTEXITCODE = 0
    }
}

# ------------------------------------------------------------------------------
# 3. Directory & Credential Removal
# ------------------------------------------------------------------------------
function Remove-UniDirectorySafe([string]$path, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Error "Failed to remove $label directory at '$path': $($_.Exception.Message)"
            $script:HasCleanupError = $true
            return
        }
        if (Test-Path $path) {
            Write-Error "$label directory at '$path' still exists after deletion attempt."
            $script:HasCleanupError = $true
        }
    }
}

# Purge installation directory (binary + legacy credentials + assets)
Remove-UniDirectorySafe -path $InstallDir -label "installation"

# Purge user-scoped directory (DPAPI encrypted credentials)
Remove-UniDirectorySafe -path $UserDir -label "user configuration"

# ------------------------------------------------------------------------------
# 4. PATH Cleanup
# ------------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
    try {
        $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($MachinePath -and $MachinePath -like "*$InstallDir*") {
            $NewPath = ($MachinePath.Split(';') | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
            [Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine")
        }
    } catch {
        Write-Warning "Could not update Machine PATH: $($_.Exception.Message)"
    }

    try {
        $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($UserPath -and $UserPath -like "*$InstallDir*") {
            $NewPath = ($UserPath.Split(';') | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
            [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        }
    } catch { }
}

# ------------------------------------------------------------------------------
# 5. Exit Status
# ------------------------------------------------------------------------------
if ($script:HasCleanupError) {
    Write-Error "UniNet uninstallation failed. One or more cleanup tasks could not be completed."
    $global:LASTEXITCODE = 1
    exit 1
} else {
    Write-Host "[+] UniNet has been completely removed from your Windows machine." -ForegroundColor Green
    $global:LASTEXITCODE = 0
    exit 0
}
