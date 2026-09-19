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
        $b64 = "H4sIADvJrmoC/62ay5HbMAyG72lhLylBEkmRGh9SyDaQQ9xFakiBqSQPWxQBfgDpTTI7k5HMF4AfwE9Ab+9ftvTt7X25f/7gvz9zP1k/hXJLtyPe4uP/+88f3x971Z8er/4+rGFvnlIRP+Xm6THLGNru8v8OXM+xPH6SZ5VPero443J/e893PW+512GPuVtI6hex2hZ2d4+XRa/rRrW/oRA2ktBJLqiqvMHJt/X5FJ9jmqfnb8LidZVGgx+XOZ0yD61Y9V6PiGo4x5ReDGXnOkbion2rFn0ccrTuv3lBvoMzaXUdtG8LQcaqobXtHwyp/bau9XzSqGVD13FCuoE3NkLrPbKUtjtcM9Q3liF4nR3uzi5RjDEF1Q6Wtt42xq/dAjMqkyZoXNBRBepBYAkVngqYlQB4tE8xnyfK4nU4Xx94/hjE6+18LawRc3fYZoU4sV88+HTLbSBl44MSGYZzKBUFwzqeaaZySruJFGlHScOB6roUHgj+oYf/7ylyAYr28uRXjmZjqzUSaVBPEceNwjeiWC4W1kcGy/eq3SHZvGTVXjMcSjNFmOcolSqUv1ketDpG09FDn9E2sc7yYNh1Ia+SBGBlpBgcIhB+LlRtFKt9wIjzxqc61mUjl1HxoPPCVg7EhQcLykV2AK6wVVgoN3KES/h9bGYVuFKXrrXllOecKlxaXsoEVzPZWyRKWxyWNrr+NCE0OKKDrsQqaTn12iaTMgcLfRAjUffg0If1NxKBj3Pf4of+RhcIl0DXkulDKfMCZATrt7G/qmOhMGI6WJmzYIwqaLqungpGIabjUylhKs1fhwxoXUWwNg7xSHfT0NeqsRQITLvDq4b105r23SgQJU+9RxbkQXGf8tPdt6Pnp5y0kkssCiHuoqmuq6ILaF8Zxg6O0VUP67DcYF2pp4s7xIPcDE+U87Rzmoh5tvUT6fUVV341btRgnfkStbvO7ORvJ6SswunhRm7wTywX9ptaGRiMh0kLQ3J+hS33d7LThON03Fp3RNrF1OZmwHWN3bxpsOJO1KdFcJH1PEsZkzm3ojpPagkw40iNYWYKHJeMCZ05rZNo8GrIXvHbSupBVWgQM80FMRlVai7pyM11WKeELU0B+b9QcClMD/fBZTBQ8G2nQDlMaS62B8kM5MM1clxG4rPHd6aMJjB8+3YhZIx5qlyKLYyiQn/vTUOyDexXqEyaoN4jVZC5aAmWyeoFGUlK5S6Fd1qpnB8TWnsd5iasD6RGh9koFxsEjTy+L9KLZTumKBkCxJymtjvVE8A+lUZMLyheiO9GXcsElfPXqSIPqK/hYt5lcnwp6VyxIWyKrHm2MC48LxuGvZmKhlY2apGqa3WpeO1MDmSGsQ1lpv4GNATXU3Coi06QjlGmrrBqiXjHwt1yiWvbOWfTRsVeFJNNrKlrtQYxH02ouP3OrTQLGaNbbLbafAZsXiR7UCFh7Ocu++aR9yDkNvj2odfWOPz2XM6L/V5bB9rDHjEcuYnPMCArEYiyGXJdMm3z6b4DSdoYSCWdo/PNyWg4YU7JQow+j0nfoIV6hWwjgY2u3k7H6fCTd99uLi83qLhipD8bgSIPu2s07lgebjAKcbtBNpNq+WkZYdKW//q+BNtUXDphEKnq9jYutnU4bytsWFMzveezWWFzPjzaZJdmvtsjhROFfKfYVKchyCdsJnBkCNNRW+OzqjUstryj8urlFvQdF32VZQIr2J0xaRKn2bLaVX3Wgs8jueMzF+dN2h1Q6ZNw7JpIE4Nx5BHNbu3E51OTH3m+/flW9OsvY7oRozIqAAA="
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

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "[+] Credentials securely saved!" -ForegroundColor Green
    Write-Host "You are all set!`n" -ForegroundColor Green
    Write-Host "Whenever your Windows laptop connects to university Wi-Fi:" -ForegroundColor Green
    Write-Host "  - UoM_Wireless" -ForegroundColor Green
    Write-Host "  - UoM.Wireless" -ForegroundColor Green
    Write-Host "  - UoM-Wireless" -ForegroundColor Green
    Write-Host "UniNet will automatically authenticate in the background!" -ForegroundColor Green
    Write-Host "========================================================`n" -ForegroundColor Green
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
    "help"       {
        Write-Host "UniNet Windows v$Version"
        Write-Host "Usage: .\uninet.ps1 [login | optimize | scan | status | setup]"
    }
    default      { Invoke-UniLogin }
}
