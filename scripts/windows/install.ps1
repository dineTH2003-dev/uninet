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
# 4. Register Windows Task Scheduler — auto-connect on Wi-Fi join
# ---------------------------------------------------------------------------
# ROOT CAUSE OF AUTO-CONNECT FAILURE — two bugs in the original approach:
#
# BUG A: <LogonType>InteractiveToken</LogonType> without a <UserId> creates
#        the task bound to whoever ran the installer (Administrator).
#        When the regular user connects to Wi-Fi, the task fires for the
#        admin session — which may not exist — so it silently does nothing.
#        FIX: Use <GroupId>S-1-5-32-545</GroupId> (BUILTIN\Users) so the
#        task fires for EVERY logged-in standard user.
#
# BUG B: Event 8001 only fires when WLAN AutoConfig completes the 802.11
#        handshake. On sleep/resume and fast-reconnect, 8001 is NOT re-fired
#        even though the Wi-Fi is back. That means no trigger → no login.
#        FIX: Add a second <LogonTrigger> with a 5-second delay. This fires
#        whenever any user logs in, acting as a guaranteed catch-all.
# ---------------------------------------------------------------------------

$TaskName  = "UniNetAutoConnect"
$Action    = "powershell.exe"
$Arguments = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$ScriptDest`" login -Quiet"

# Remove any previous version of this task
$null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Build the task using Register-ScheduledTask (native PS — more reliable
# than schtasks /xml which silently fails on certain encodings/versions)
# ---------------------------------------------------------------------------

# PRINCIPAL: GroupId = BUILTIN\Users (S-1-5-32-545)
# Fires for ANY logged-in standard user, not just the installer account
$principal = New-ScheduledTaskPrincipal `
    -GroupId   "S-1-5-32-545" `
    -RunLevel  Limited

$action = New-ScheduledTaskAction `
    -Execute   $Action `
    -Argument  $Arguments

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit       (New-TimeSpan -Minutes 1) `
    -MultipleInstances        IgnoreNew `
    -AllowStartIfOnBatteries  `
    -DontStopIfGoingOnBatteries `
    -Hidden

# TRIGGER 1: LogonTrigger — fires 5 s after any user logs in
# Catches sleep/resume, startup, and cases where Event 8001 wasn't re-fired
$logonTrigger        = New-ScheduledTaskTrigger -AtLogOn
$logonTrigger.Delay  = "PT5S"

# Register the task with the logon trigger first (Register-ScheduledTask
# does not support EventTrigger natively, so we add it via XML next)
try {
    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Principal $principal `
        -Settings  $settings `
        -Trigger   $logonTrigger `
        -Force     | Out-Null
} catch {
    Write-Host "[!] Warning: Could not register scheduled task via Register-ScheduledTask: $_" -ForegroundColor Yellow
}

# TRIGGER 2: EventTrigger — fires instantly on WLAN Event 8001 (Wi-Fi connected)
# We inject this by exporting the task XML, adding the EventTrigger, and re-importing.
# This is necessary because Register-ScheduledTask has no -EventTrigger parameter.
try {
    $exportedXml = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    $eventSubscription = '&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;&lt;Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;*[System[(EventID=8001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
    $eventTriggerXml   = "<EventTrigger><Enabled>true</Enabled><Subscription>$eventSubscription</Subscription></EventTrigger>"

    # Inject EventTrigger BEFORE the existing LogonTrigger inside <Triggers>
    $updatedXml = $exportedXml -replace '<Triggers>', "<Triggers>$eventTriggerXml"

    $TempXml = "$env:TEMP\uninet_task_final.xml"
    $updatedXml | Out-File -FilePath $TempXml -Encoding Unicode -Force

    # Re-import with both triggers
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $result = cmd.exe /c "schtasks /create /tn `"$TaskName`" /xml `"$TempXml`" /f 2>&1"
    Remove-Item $TempXml -Force -ErrorAction SilentlyContinue

    if ($result -match "SUCCESS|successfully") {
        Write-Host "[+] Task registered with Event 8001 + Logon triggers." -ForegroundColor Green
    } else {
        Write-Host "[+] Task registered with Logon trigger (Event injection: $result)." -ForegroundColor Cyan
    }
} catch {
    Write-Host "[+] Task registered with Logon trigger only (Event trigger export failed: $_)." -ForegroundColor Cyan
}

# Verify the task actually exists
$verify = schtasks /query /tn $TaskName /fo LIST 2>$null
if ($verify -match $TaskName) {
    Write-Host "[+] Auto-connect task verified: '$TaskName' is active in Task Scheduler." -ForegroundColor Green
} else {
    Write-Host "[!] Warning: Task '$TaskName' was not found after registration. Auto-connect may not work." -ForegroundColor Yellow
    Write-Host "    You can manually re-register by running this installer again as Administrator." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. Launch interactive setup in a fresh PowerShell process
# ---------------------------------------------------------------------------
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$ScriptDest" setup

