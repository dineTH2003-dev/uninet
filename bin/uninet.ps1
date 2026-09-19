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
$MatchPatterns = @("uom_wireless", "uom.wireless", "uom-wireless", "uom", "wireless", "campus", "eduroam")

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
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
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
        Write-UniLog "✔ Successfully connected! Internet is now active on $ssid." "Green"
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

# 7. Setup Wizard
function Invoke-UniSetup {
    Write-Host "`n================================================" -ForegroundColor Cyan
    Write-Host "        UniNet Windows Fast Setup Wizard        " -ForegroundColor Cyan
    Write-Host "================================================`n" -ForegroundColor Cyan

    $ssid = Get-ActiveSSID
    if (-not $ssid) { $ssid = "UoM_Wireless" }
    Write-Host "Detected Wi-Fi: $ssid`n"

    $username = Read-Host "Student Username / ID"
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "Error: Username cannot be empty." -ForegroundColor Red
        return
    }

    $password = Read-Host "Password" -AsSecureString
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

    Write-Host "`n✔ Credentials saved locally in $CredsFile" -ForegroundColor Green
    Write-Host "`nTesting connection now..."
    Invoke-UniLogin
}

# 8. Command Router
switch ($Command.ToLower()) {
    "login"   { Invoke-UniLogin }
    "status"  { Show-UniStatus }
    "setup"   { Invoke-UniSetup }
    "help"    {
        Write-Host "UniNet Windows v$Version"
        Write-Host "Usage: .\uninet.ps1 [status | login | setup]"
    }
    default   { Invoke-UniLogin }
}
