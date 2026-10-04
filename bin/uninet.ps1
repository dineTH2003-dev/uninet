# ==============================================================================
# UniNet - Windows University Wi-Fi Auto-Connect Engine (PowerShell)
#
# Supported Networks:
#   - UoM_Wireless
#   - UoM.Wireless
#   - UoM-Wireless
#
# Zero Python. 100% native PowerShell 5.1+ / 7+ on Windows 10 & 11.
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Position=0)]
    [string]$Command = "login",

    [switch]$Quiet
)

$Version = "1.0.6"
$RepoRawUrl = "https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"
$ConfigDir = "$env:APPDATA\uninet"
$CredsFile = "$ConfigDir\credentials.json"
$ProbeUrl = "http://connectivitycheck.gstatic.com/generate_204"
$MatchPatterns = @("uom_wireless", "uom.wireless", "uom-wireless", "uom", "wireless", "campus")

function Write-UniLog([string]$Message, [string]$Color = "Cyan") {
    if (-not $Quiet) {
        Write-Host "[UniNet] $Message" -ForegroundColor $Color
    }
}

# 1. Get currently connected Wi-Fi SSID on Windows
function Get-ActiveSSID {
    try {
        $interfaces = netsh wlan show interfaces
        $ssidMatch = $interfaces | Select-String "^\s*SSID\s*:" | Select-Object -First 1
        if ($ssidMatch) {
            return ($ssidMatch.Line -split ":")[1].Trim()
        }
    } catch { }
    return ""
}

# 2. Check if SSID matches university patterns
function Test-UniversityNetwork([string]$SSID) {
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $false }
    $lower = $SSID.ToLower()
    foreach ($pat in $MatchPatterns) {
        if ($lower -like "*$pat*") {
            return $true
        }
    }
    return $false
}

# 3. Check if internet is already online (HTTP 204)
function Test-IsOnline {
    try {
        $req = [System.Net.HttpWebRequest]::Create($ProbeUrl)
        $req.Timeout = 4000
        $req.Method = "GET"
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 204)
    } catch {
        return $false
    }
}

# 4. Read credentials safely from JSON file
function Get-SavedCredentials {
    if (-not (Test-Path $CredsFile)) {
        # Check system directory fallback
        $sysFile = "C:\ProgramData\uninet\credentials.json"
        if (Test-Path $sysFile) {
            $CredsFile = $sysFile
        } else {
            return $null
        }
    }

    try {
        $json = Get-Content -Raw -Path $CredsFile -ErrorAction Stop | ConvertFrom-Json
        if ($json.username -and $json.password) {
            return $json
        }
    } catch { }
    return $null
}

# 5. Core Login Flow
function Invoke-UniLogin {
    # Allow DHCP and Wi-Fi stack to settle when triggered on event
    $ssid = ""
    for ($i = 0; $i -lt 5; $i++) {
        $ssid = Get-ActiveSSID
        if ($ssid -and (Test-UniversityNetwork $ssid)) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if ([string]::IsNullOrWhiteSpace($ssid)) {
        Write-UniLog "No active Wi-Fi connection detected." "Gray"
        return
    }

    if (-not (Test-UniversityNetwork $ssid)) {
        Write-UniLog "Connected to non-university Wi-Fi ($ssid). Exiting." "Gray"
        return
    }

    # Small delay to ensure DHCP lease and routing are established
    Start-Sleep -Seconds 2

    if (Test-IsOnline) {
        Write-UniLog "Already connected to the internet on $ssid." "Green"
        return
    }

    Write-UniLog "Captive portal detected on $ssid. Authenticating..." "Yellow"

    $creds = Get-SavedCredentials
    if (-not $creds) {
        Write-UniLog "Error: No saved credentials found. Run 'uninet setup' first." "Red"
        return
    }

    # Probe portal with retry to capture redirect URL and session cookies
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $landingUrl = ""
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            # Allow untrusted SSL for internal university gateways
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $resp = Invoke-WebRequest -Uri $ProbeUrl -SessionVariable "session" -MaximumRedirection 5 -TimeoutSec 6 -UseBasicParsing -ErrorAction SilentlyContinue
            if ($resp) {
                if ($resp.StatusCode -eq 204) {
                    Write-UniLog "[+] Already connected! Internet is now active on $ssid." "Green"
                    return
                }
                if ($resp.BaseResponse -and $resp.BaseResponse.ResponseUri) {
                    $landingUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
                    break
                }
            }
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.ResponseUri) {
                $landingUrl = $_.Exception.Response.ResponseUri.AbsoluteUri
                break
            }
        }
        Start-Sleep -Seconds 1
    }

    if (-not $landingUrl) {
        $landingUrl = $ProbeUrl
    }

    Write-UniLog "Submitting login credentials for $($creds.username)..." "Cyan"

    $body = @{
        username         = $creds.username
        password         = $creds.password
        user             = $creds.username
        pass             = $creds.password
        student_id       = $creds.username
        student_password = $creds.password
    }

    try {
        Invoke-WebRequest -Uri $landingUrl -Method POST -Body $body -WebSession $session -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    Start-Sleep -Seconds 1

    if (Test-IsOnline) {
        Write-UniLog "[+] Successfully connected! Internet is now active on $ssid." "Green"
    } else {
        Write-UniLog "Notice: Login submitted. Verifying connection status..." "Yellow"
    }
}

# 6. Status Command & Version Notification
function Test-VersionNotification {
    if (-not (Test-IsOnline)) { return }

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "UniNet-Windows")
        $latest = ($wc.DownloadString("$RepoRawUrl/VERSION")).Trim()
        if ($latest -and $latest -ne $Version) {
            Write-Host "[*] A new version of UniNet is available (v$latest)." -ForegroundColor Yellow
            Write-Host "    Run 'uninet update' to upgrade automatically.`n" -ForegroundColor Yellow
        }
    } catch { }
}

function Show-UniStatus {
    $ssid = Get-ActiveSSID
    Write-Host "`n=== UniNet Windows Status ===" -ForegroundColor Cyan
    Write-Host "Active Wi-Fi:   $($ssid -replace '^$', 'None')"

    if ($ssid) {
        if (Test-UniversityNetwork $ssid) {
            Write-Host "University Net: Yes ($ssid)" -ForegroundColor Green
        } else {
            Write-Host "University Net: No (Home/Other)" -ForegroundColor Yellow
        }
    }

    if (Test-IsOnline) {
        Write-Host "Internet:       ONLINE (Direct Internet Access confirmed)`n" -ForegroundColor Green
    } else {
        Write-Host "Internet:       CAPTIVE PORTAL / OFFLINE`n" -ForegroundColor Yellow
    }

    Test-VersionNotification
}


function Invoke-UniSetup {
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "         UNIVERSITY OF MORATUWA - CAMPUS WI-FI          " -ForegroundColor Cyan
    Write-Host "               UniNet Auto-Connect Engine               " -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan

    $ssid = Get-ActiveSSID
    if ($ssid) {
        Write-Host "Active Wi-Fi: $ssid`n"
    }

    $username = Read-Host "Student Username      "
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "Error: Username cannot be empty." -ForegroundColor Red
        return
    }

    $password = Read-Host "Network Password      " -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    if ([string]::IsNullOrWhiteSpace($plainPass)) {
        Write-Host "Error: Password cannot be empty." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    $data = @{
        username = $username
        password = $plainPass
    } | ConvertTo-Json

    Set-Content -Path $CredsFile -Value $data -Encoding UTF8

    # Also save to ProgramData for Windows Task Scheduler access
    $sysDir = "C:\ProgramData\uninet"
    if (-not (Test-Path $sysDir)) {
        New-Item -ItemType Directory -Path $sysDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path $sysDir) {
        Set-Content -Path "$sysDir\credentials.json" -Value $data -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    # Quiet connection test if currently connected to campus Wi-Fi
    if ($ssid -and (Test-UniversityNetwork $ssid)) {
        if (-not (Test-IsOnline)) {
            Invoke-UniLogin -Quiet
        }
    }

    # Register UoM SSIDs as trusted networks for auto-join
    Add-TrustedNetworks

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "[+] Credentials securely saved!" -ForegroundColor Green
    Write-Host "You are all set!`n" -ForegroundColor Green
    Write-Host "Your Windows machine will now automatically join university" -ForegroundColor Green
    Write-Host "Wi-Fi whenever it is in range - no manual selection needed:" -ForegroundColor Green
    Write-Host "  - UoM_Wireless" -ForegroundColor Green
    Write-Host "  - UoM.Wireless" -ForegroundColor Green
    Write-Host "  - UoM-Wireless" -ForegroundColor Green
    Write-Host "UniNet will authenticate the portal in the background!" -ForegroundColor Green
    Write-Host "========================================================`n" -ForegroundColor Green
}

# 7b. Trust UoM Networks -- import open WLAN profiles so Windows auto-joins
function Add-TrustedNetworks {
    $ssids = @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")
    $added = 0

    $iface = ""
    try {
        $ifLines = netsh wlan show interfaces
        $ifMatch = $ifLines | Select-String "^\s*Name\s*:" | Select-Object -First 1
        if ($ifMatch) {
            $iface = ($ifMatch.Line -split ":")[1].Trim()
        }
    } catch { }

    foreach ($ssid in $ssids) {
        $profileXml = "<?xml version=""1.0""?>" +
            "<WLANProfile xmlns=""http://www.microsoft.com/networking/WLAN/profile/v1"">" +
            "<name>$ssid</name>" +
            "<SSIDConfig><SSID><name>$ssid</name></SSID></SSIDConfig>" +
            "<connectionType>ESS</connectionType>" +
            "<connectionMode>auto</connectionMode>" +
            "<MSM><security><authEncryption>" +
            "<authentication>open</authentication>" +
            "<encryption>none</encryption>" +
            "<useOneX>false</useOneX>" +
            "</authEncryption></security></MSM>" +
            "</WLANProfile>"

        $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$ssid.xml")
        try {
            [System.IO.File]::WriteAllText($tmpFile, $profileXml, [System.Text.Encoding]::ASCII)
            $null = cmd.exe /c "netsh wlan add profile filename=`"$tmpFile`" user=all 2>nul"
            $null = cmd.exe /c "netsh wlan set profileparameter name=`"$ssid`" connectionmode=auto autoswitch=Yes 2>nul"
            if ($iface) {
                $null = cmd.exe /c "netsh wlan set profileorder name=`"$ssid`" interface=`"$iface`" priority=1 2>nul"
            }
            $added++
        } catch { }
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    if ($added -gt 0) {
        Write-UniLog "Registered $added university network profile(s) for automatic Wi-Fi join." "Green"
    }
}

# 8. Wi-Fi Multi-Factor Quality Scoring & Network Scanning
function Get-CampusNetworks([string]$FilterMode = "campus") {
    $networks = @()
    $activeSSID = Get-ActiveSSID

    try {
        $lines = netsh wlan show networks mode=bssid
    } catch {
        return $networks
    }

    $currentSSID = ""
    $currentBSSID = ""
    $currentSignal = 0
    $currentBand = "2.4 GHz"
    $currentRadio = "802.11n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match "^SSID\s+\d+\s*:\s*(.*)$") {
            $currentSSID = $matches[1].Trim()
            continue
        }

        if ($trimmed -match "^BSSID\s+\d+\s*:\s*(.*)$") {
            $currentBSSID = $matches[1].Trim()
            continue
        }

        if ($trimmed -match "^Signal\s*:\s*(\d+)%") {
            $currentSignal = [int]$matches[1]
            continue
        }

        if ($trimmed -match "^Radio type\s*:\s*(.*)$") {
            $currentRadio = $matches[1].Trim()
            continue
        }

        if ($trimmed -match "^Band\s*:\s*(.*)$") {
            $currentBand = $matches[1].Trim()
            continue
        }

        if ($trimmed -match "^Channel\s*:\s*(\d+)") {
            $channel = [int]$matches[1]
            if ($channel -ge 36) {
                $currentBand = "5.0 GHz"
            }

            if (-not [string]::IsNullOrWhiteSpace($currentSSID)) {
                $include = $false
                if ($FilterMode -eq "all") {
                    $include = $true
                } elseif (Test-UniversityNetwork $currentSSID) {
                    $include = $true
                }

                if ($include) {
                    $is5GHz = ($currentBand -like "*5*" -or $channel -ge 36)
                    $rate = 130
                    if ($currentRadio -like "*ac*") {
                        $rate = 866
                    } elseif ($currentRadio -like "*ax*") {
                        $rate = 1201
                    } elseif ($is5GHz) {
                        $rate = 433
                    }

                    $isActive = ($currentSSID -eq $activeSSID)

                    # Multi-factor score calculation
                    $sigScore = [math]::Round($currentSignal * 0.35, 1)
                    $bandBonus = 0
                    if ($is5GHz -and $currentSignal -ge 20) {
                        $bandBonus = 30
                    }
                    $rateScore = [math]::Round(([math]::Min($rate, 866) / 866.0) * 35, 1)
                    $actBonus = 0
                    if ($isActive) {
                        $actBonus = 12
                    }

                    $totalScore = $sigScore + $bandBonus + $rateScore + $actBonus

                    $obj = [PSCustomObject]@{
                        Score    = [math]::Round($totalScore, 1)
                        IsActive = $isActive
                        SSID     = $currentSSID
                        BSSID    = $currentBSSID
                        Band     = if ($is5GHz) { "5.0 GHz" } else { "2.4 GHz" }
                        Rate     = "$rate Mbit/s"
                        Signal   = "$currentSignal%"
                    }
                    $networks += $obj
                }
            }
            continue
        }
    }

    return ($networks | Sort-Object -Property Score -Descending)
}

function Show-CampusScan {
    Write-UniLog "Scanning for available Wi-Fi networks..." "Cyan"
    $results = Get-CampusNetworks "campus"

    if (-not $results -or $results.Count -eq 0) {
        Write-Host "Notice: No university campus networks detected in range." -ForegroundColor Yellow
        Write-Host "Showing nearby Wi-Fi networks for diagnosis:`n" -ForegroundColor Gray
        $results = Get-CampusNetworks "all"
    } else {
        Write-Host "`nDetected Campus Networks:" -ForegroundColor Cyan
    }

    if (-not $results -or $results.Count -eq 0) {
        Write-Host "No Wi-Fi networks found."
        return
    }

    $activeItem = $results | Where-Object { $_.IsActive } | Select-Object -First 1
    $activeScore = if ($activeItem) { $activeItem.Score } else { 0 }

    Write-Host ("{0,-9} {1,-18} {2,-18} {3,-9} {4,-12} {5,-8} {6,-6}" -f "STATUS", "SSID", "BSSID", "BAND", "RATE", "SIGNAL", "SCORE")
    Write-Host "----------------------------------------------------------------------------------"

    foreach ($net in $results) {
        $status = "      "
        $suffix = ""
        if ($net.IsActive) {
            $status = "* ACTIVE"
        } elseif ($activeScore -gt 0 -and $net.Score -ge ($activeScore + 15)) {
            $status = "  BETTER"
            $suffix = " (+)"
        }

        $line = "{0,-9} {1,-18} {2,-18} {3,-9} {4,-12} {5,-8} {6,-6}{7}" -f $status, ($net.SSID -replace '^(.{18}).+$', '$1'), $net.BSSID, $net.Band, $net.Rate, $net.Signal, $net.Score, $suffix
        Write-Host $line
    }
    Write-Host ""
    Test-VersionNotification
}

function Optimize-Connection {
    Write-UniLog "Evaluating campus Wi-Fi networks for optimal bandwidth and speed..." "Cyan"
    $results = Get-CampusNetworks "campus"

    if (-not $results -or $results.Count -eq 0) {
        Write-UniLog "No university networks detected in range. Checking standard login..." "Yellow"
        Invoke-UniLogin
        return
    }

    $top = $results[0]
    $active = $results | Where-Object { $_.IsActive } | Select-Object -First 1

    $activeScore = if ($active) { $active.Score } else { 0 }
    $activeSSID = if ($active) { $active.SSID } else { "" }

    $threshold = $activeScore + 15

    if ($top.IsActive -or $top.SSID -eq $activeSSID) {
        Write-UniLog "Current connection '$activeSSID' is already the best available (Quality Score: $($top.Score))." "Green"
    } elseif ($top.Score -ge $threshold) {
        $diff = [math]::Round($top.Score - $activeScore, 1)
        Write-UniLog "Found significantly faster connection: '$($top.SSID)' (+$diff pts higher quality, $($top.Band), $($top.Rate))." "Green"
        Write-UniLog "Switching connection to '$($top.SSID)'..." "Cyan"

        $null = cmd.exe /c "netsh wlan connect name=`"$($top.SSID)`""
        Start-Sleep -Seconds 2
        Write-UniLog "[+] Connected to $($top.SSID)!" "Green"
    } else {
        Write-UniLog "Current connection '$activeSSID' is optimal (candidate difference is within 15-point stability margin)." "Yellow"
    }

    Write-UniLog "Probing captive portal..." "Cyan"
    Invoke-UniLogin
}

function Invoke-UniUninstall {
    Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow

    # Remove scheduled task
    $TaskName = "UniNetAutoConnect"
    $null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"

    # Remove WLAN profiles registered by 'uninet setup' / 'uninet trust'
    foreach ($ssid in @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")) {
        $null = cmd.exe /c "netsh wlan delete profile name=`"$ssid`" >nul 2>nul"
    }

    # Remove user-scoped config directory
    $UserDir = "$env:APPDATA\uninet"
    if (Test-Path $UserDir) {
        Remove-Item -Path $UserDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Remove from system PATH
    $InstallDir = "C:\ProgramData\uninet"
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

    # Schedule deferred cleanup of install directory after script exits
    $cleanupCmd = "ping 127.0.0.1 -n 2 >nul & rmdir /s /q `"$InstallDir`""
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cleanupCmd" -WindowStyle Hidden

    Write-Host "[+] UniNet has been completely removed from your Windows machine." -ForegroundColor Green
}

function Invoke-UniUpdate {
    Write-UniLog "Checking for updates..." "Cyan"

    $latest = ""
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "UniNet-Windows")
        $latest = ($wc.DownloadString("$RepoRawUrl/VERSION")).Trim()
    } catch {
        Write-Host "Error: Unable to check for updates. Please check your internet connection." -ForegroundColor Red
        return
    }

    if ($latest -eq $Version) {
        Write-Host "[+] UniNet is already up to date (v$Version)." -ForegroundColor Green
        return
    }

    Write-Host "Found newer version: v$latest (current: v$Version). Upgrading..." -ForegroundColor Cyan

    $installDir = "C:\ProgramData\uninet"
    $targetFile = "$installDir\uninet.ps1"
    $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "uninet_new.ps1")

    $downloadSuccess = $false
    $releaseAssetUrl = "https://github.com/dineTH2003-dev/uninet/releases/download/v$latest/uninet.ps1"
    try {
        $wc.DownloadFile($releaseAssetUrl, $tempFile)
        if ((Test-Path $tempFile) -and ((Get-Item $tempFile).Length -ge 500)) {
            $downloadSuccess = $true
        }
    } catch { }

    if (-not $downloadSuccess) {
        try {
            $wc.DownloadFile("$RepoRawUrl/bin/uninet.ps1", $tempFile)
        } catch {
            Write-Host "Error: Failed to download update from GitHub." -ForegroundColor Red
            return
        }
    }

    if (-not (Test-Path $tempFile) -or (Get-Item $tempFile).Length -lt 500) {
        Write-Host "Error: Downloaded file corrupted or invalid." -ForegroundColor Red
        return
    }
    try {
        # Replace installed script
        Copy-Item -Path $tempFile -Destination $targetFile -Force
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

        Write-Host "[+] Successfully updated UniNet to v$latest!" -ForegroundColor Green
    } catch {
        Write-Host "Error: Failed to apply update: $_" -ForegroundColor Red
    }
}

# 9. Command Router
switch ($Command.ToLower()) {
    "login"      { Invoke-UniLogin }
    "optimize"   { Optimize-Connection }
    "best"       { Optimize-Connection }
    "scan"       { Show-CampusScan }
    "status"     { Show-UniStatus }
    "setup"      { Invoke-UniSetup }
    "trust"      { Add-TrustedNetworks }
    "update"     { Invoke-UniUpdate }
    "uninstall"  { Invoke-UniUninstall }
    "help"       {
        Write-Host "UniNet Windows v$Version"
        Write-Host "Usage: .\uninet.ps1 [login | optimize | scan | status | setup | trust | update | uninstall]"
    }
    default      { Invoke-UniLogin }
}
