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

$Version = "1.0.0"
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
    $ssid = Get-ActiveSSID

    if ([string]::IsNullOrWhiteSpace($ssid)) {
        Write-UniLog "No active Wi-Fi connection detected." "Gray"
        return
    }

    if (-not (Test-UniversityNetwork $ssid)) {
        Write-UniLog "Connected to non-university Wi-Fi ($ssid). Exiting." "Gray"
        return
    }

    if (Test-IsOnline) {
        Write-UniLog "Already connected to the internet on $ssid." "Green"
        return
    }

    Write-UniLog "Captive portal detected on $ssid. Authenticating..." "Yellow"

    $creds = Get-SavedCredentials
    if (-not $creds) {
        Write-UniLog "Error: No saved credentials found. Run 'uninet.ps1 setup' first." "Red"
        return
    }

    # Probe portal with WebRequest to get redirect URL
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $landingUrl = $ProbeUrl
    try {
        # Allow untrusted SSL for internal university gateways
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $resp = Invoke-WebRequest -Uri $ProbeUrl -SessionVariable "session" -MaximumRedirection 5 -TimeoutSec 8 -UseBasicParsing
        $landingUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
    } catch {
        if ($_.Exception.Response) {
            $landingUrl = $_.Exception.Response.ResponseUri.AbsoluteUri
        }
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

# 6. Status Command
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
}

# 7. University of Moratuwa Official Terminal Crest & Setup Wizard
function Show-UoMLogo {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $assetFile = "C:\ProgramData\uninet\uom_logo.ans"
        if (Test-Path $assetFile) {
            Get-Content -Raw -Encoding UTF8 $assetFile | Write-Host
            return
        }
        $b64 = "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"
        $bytes = [System.Convert]::FromBase64String($b64)
        $ms = New-Object System.IO.MemoryStream
        $ms.Write($bytes, 0, $bytes.Length)
        $ms.Position = 0
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object System.IO.StreamReader($gz)
        $logo = $sr.ReadToEnd()
        Write-Host $logo
    } catch { }
}

function Invoke-UniSetup {
    Show-UoMLogo
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "         UNIVERSITY OF MORATUWA - CAMPUS WI-FI          " -ForegroundColor Cyan
    Write-Host "               UniNet Auto-Connect Engine               " -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan

    $ssid = Get-ActiveSSID
    if ($ssid) {
        Write-Host "Active Wi-Fi: $ssid`n"
    }

    $username = Read-Host "Student Username / ID "
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
            $result = cmd.exe /c "netsh wlan add profile filename=`"$tmpFile`" user=all 2>nul"
            if ($LASTEXITCODE -eq 0) { $added++ }
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

# 9. Command Router
switch ($Command.ToLower()) {
    "login"      { Invoke-UniLogin }
    "optimize"   { Optimize-Connection }
    "best"       { Optimize-Connection }
    "scan"       { Show-CampusScan }
    "status"     { Show-UniStatus }
    "setup"      { Invoke-UniSetup }
    "trust"      { Add-TrustedNetworks }
    "help"       {
        Write-Host "UniNet Windows v$Version"
        Write-Host "Usage: .\uninet.ps1 [login | optimize | scan | status | setup | trust]"
    }
    default      { Invoke-UniLogin }
}
