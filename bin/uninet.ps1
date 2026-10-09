# ==============================================================================
# UniNet - Windows University Wi-Fi Auto-Connect Engine (PowerShell)
#
# Supported Networks:
#   - UoM_Wireless  (Cisco / NEC WebAuth)
#   - UoM.Wireless  (Aruba Networks Controller)
#   - UoM-Wireless  (Ruijie Networks Portal)
#
# Zero Python. 100% native PowerShell 5.1+ / 7+ on Windows 10 & 11.
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Position=0)]
    [string]$Command = "login",

    [switch]$Quiet
)

# ---------------------------------------------------------------------------
# FIX 6: Use Continue (not Stop) as default — risky calls use explicit try/catch
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Continue"

$Version = "1.2.2"
$RepoRawUrl     = "https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"
$ConfigDir      = "$env:APPDATA\uninet"
$CredsFile      = "$ConfigDir\credentials.json"
$SysCredsFile   = "C:\ProgramData\uninet\credentials.json"
$ProbeUrl       = "http://connectivitycheck.gstatic.com/generate_204"
# FIX 3: Secondary probe that Aruba actually intercepts (gstatic is whitelisted by Aruba)
$ArubaProbeUrl  = "http://connectivity-check.ubuntu.com./"
$MatchPatterns  = @("uom_wireless", "uom.wireless", "uom-wireless")

# ---------------------------------------------------------------------------
# FIX 8: Enable TLS 1.2/1.3 at startup — required for GitHub raw on old PS/Windows
# ---------------------------------------------------------------------------
try {
    # 3072 = TLS 1.2, 12288 = TLS 1.3
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
} catch {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch { }
}

# ---------------------------------------------------------------------------
# Portal SSL: accept self-signed certs on internal university gateways (ICertificatePolicy)
# ---------------------------------------------------------------------------
try {
    if (-not ([System.Management.Automation.PSTypeName]'UniNetCertPolicy').Type) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class UniNetCertPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) { return true; }
}
'@ -ErrorAction SilentlyContinue
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object UniNetCertPolicy
} catch { }

# ===========================================================================
# UTILITY FUNCTIONS
# ===========================================================================

function Write-UniLog([string]$Message, [string]$Color = "Cyan") {
    if (-not $Quiet) {
        Write-Host "[UniNet] $Message" -ForegroundColor $Color
    }
}

# ---------------------------------------------------------------------------
# FIX 10: Locale-safe SSID extraction — netsh labels change in non-English Windows
# ---------------------------------------------------------------------------
function Get-ActiveSSID {
    # Method 1: netsh (works on English + most Western locales)
    try {
        $lines = netsh wlan show interfaces 2>$null
        # Match line containing "SSID" but NOT "BSSID" — works even if label differs slightly
        foreach ($line in $lines) {
            if ($line -match '^\s*SSID\s*:' -and $line -notmatch 'BSSID') {
                return ($line -split ':', 2)[1].Trim()
            }
        }
    } catch { }

    # Method 2: WMI — locale-independent, works on any Windows language
    try {
        $adapters = Get-WmiObject -Class Win32_NetworkAdapter -Filter "NetConnectionStatus=2" -ErrorAction SilentlyContinue
        foreach ($a in $adapters) {
            if ($a.Name -match 'Wi-?Fi|Wireless|WLAN|802\.11') {
                $ssidRaw = (netsh wlan show interfaces name="$($a.NetConnectionID)" 2>$null) |
                           Where-Object { $_ -match 'SSID' -and $_ -notmatch 'BSSID' } |
                           Select-Object -First 1
                if ($ssidRaw) { return ($ssidRaw -split ':', 2)[1].Trim() }
            }
        }
    } catch { }

    # Method 3: Get-NetConnectionProfile — PS3+ Windows 8+
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        foreach ($p in $profiles) {
            if ($p.InterfaceAlias -match 'Wi-?Fi|Wireless|WLAN') {
                return $p.Name
            }
        }
    } catch { }

    return ""
}

function Test-UniversityNetwork([string]$SSID) {
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $false }
    $lower = $SSID.ToLower()
    foreach ($pat in $MatchPatterns) {
        if ($lower -like "*$pat*") { return $true }
    }
    return $false
}

# Standard online check (gstatic) — reliable for Cisco/Ruijie portals
function Test-IsOnline {
    try {
        $req = [System.Net.HttpWebRequest]::Create($ProbeUrl)
        $req.Timeout = 4000
        $req.Method  = "GET"
        $req.AllowAutoRedirect = $false
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] { $resp = $_.Exception.Response }
        if ($resp) {
            $code = [int]$resp.StatusCode
            $resp.Close()
            return ($code -eq 204)
        }
    } catch { }
    return $false
}

# FIX 3: Aruba-specific secondary probe — Aruba intercepts this; gstatic it whitelists
function Test-ArubaOnline {
    try {
        $req = [System.Net.HttpWebRequest]::Create($ArubaProbeUrl)
        $req.Timeout = 4000
        $req.Method  = "GET"
        $req.AllowAutoRedirect = $false
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] { $resp = $_.Exception.Response }
        if ($resp) {
            $code = [int]$resp.StatusCode
            $resp.Close()
            # 204/200 = truly online; 302 = portal still blocking
            return ($code -eq 204 -or $code -eq 200)
        }
    } catch { }
    return $false
}

function Get-SavedCredentials {
    # FIX 7: Check ProgramData FIRST — Task Scheduler runs without user APPDATA context
    $files = @($SysCredsFile, $CredsFile)
    foreach ($f in $files) {
        if (Test-Path $f) {
            try {
                $json = Get-Content -Raw -Path $f -ErrorAction Stop | ConvertFrom-Json
                if ($json.username -and $json.password) { return $json }
            } catch { }
        }
    }
    return $null
}

# ===========================================================================
# PORTAL HTTP HELPERS
# FIX 2 + FIX 5: Two-step redirect capture with persistent cookie jar
# ===========================================================================

# Step-1 probe: raw request WITHOUT following redirects.
# Returns Location header (contains Aruba session params) and any Set-Cookie values.
function Invoke-NoFollowProbe {
    param(
        [string]$Uri,
        [System.Net.CookieContainer]$CookieJar
    )
    $result = [PSCustomObject]@{ StatusCode = 0; Location = ""; SetCookies = @() }
    try {
        $req = [System.Net.HttpWebRequest]::Create([System.Uri]$Uri)
        $req.Method             = "GET"
        $req.AllowAutoRedirect  = $false
        $req.Timeout            = 8000
        $req.CookieContainer    = $CookieJar
        $req.UserAgent          = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $req.Headers.Add("Accept", "text/html,application/xhtml+xml,*/*")

        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] { $resp = $_.Exception.Response }

        if ($resp) {
            $result.StatusCode = [int]$resp.StatusCode
            $result.Location   = $resp.Headers["Location"]
            try {
                $sc = $resp.Headers.GetValues("Set-Cookie")
                if ($sc) { $result.SetCookies = $sc }
            } catch { }
            $resp.Close()
        }
    } catch { }
    return $result
}

# Step-2 probe: follow all redirects, return landing page HTML + effective URL.
function Invoke-FollowProbe {
    param(
        [string]$Uri,
        [System.Net.CookieContainer]$CookieJar
    )
    $result = [PSCustomObject]@{ StatusCode = 0; EffectiveUrl = $Uri; Body = "" }
    try {
        $req = [System.Net.HttpWebRequest]::Create([System.Uri]$Uri)
        $req.Method                      = "GET"
        $req.AllowAutoRedirect           = $true
        $req.MaximumAutomaticRedirections = 8
        $req.Timeout                     = 10000
        $req.CookieContainer             = $CookieJar
        $req.UserAgent                   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        $req.Headers.Add("Accept", "text/html,application/xhtml+xml,*/*")

        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] {
            if ($_.Exception.Response) { $resp = $_.Exception.Response }
        }

        if ($resp) {
            $result.StatusCode   = [int]$resp.StatusCode
            $result.EffectiveUrl = $resp.ResponseUri.AbsoluteUri
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $result.Body = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
            $resp.Close()
        }
    } catch { }
    return $result
}

# POST credentials to portal action URL with full cookie jar.
function Invoke-PortalPost {
    param(
        [string]$ActionUrl,
        [hashtable]$Body,
        [System.Net.CookieContainer]$CookieJar,
        [string]$Referer = ""
    )
    try {
        # URL-encode each field manually — no dependency on Invoke-WebRequest
        $pairs = @()
        foreach ($k in $Body.Keys) {
            $pairs += [Uri]::EscapeDataString($k) + "=" + [Uri]::EscapeDataString($Body[$k])
        }
        $encoded   = $pairs -join "&"
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($encoded)

        $req = [System.Net.HttpWebRequest]::Create([System.Uri]$ActionUrl)
        $req.Method          = "POST"
        $req.ContentType     = "application/x-www-form-urlencoded"
        $req.ContentLength   = $bodyBytes.Length
        $req.AllowAutoRedirect = $true
        $req.MaximumAutomaticRedirections = 5
        $req.Timeout         = 12000
        $req.CookieContainer = $CookieJar
        $req.UserAgent       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        if ($Referer) { $req.Referer = $Referer }
        $req.Headers.Add("Accept", "text/html,application/xhtml+xml,*/*")

        $stream = $req.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] { $resp = $_.Exception.Response }
        if ($resp) { $resp.Close() }
    } catch { }
}

# ===========================================================================
# HTML PARSING HELPERS
# FIX 4: Read actual form fields instead of blind guessing
# ===========================================================================

# Extract all hidden <input> fields from portal HTML — returns hashtable name→value
function Get-HiddenFormFields([string]$Html) {
    $fields = @{}
    if ([string]::IsNullOrWhiteSpace($Html)) { return $fields }
    try {
        $tagRegex   = [regex]'(?i)<input[^>]+>'
        $nameRegex  = [regex]'(?i)name=["\x27]([^">\s\x27]+)["\x27]'
        $valueRegex = [regex]'(?i)value=["\x27]([^"\x27]*)["\x27]'
        $typeRegex  = [regex]'(?i)type=["\x27]?hidden["\x27]?'

        foreach ($m in $tagRegex.Matches($Html)) {
            $tag = $m.Value
            if (-not $typeRegex.IsMatch($tag)) { continue }
            $nm = $nameRegex.Match($tag)
            $vm = $valueRegex.Match($tag)
            if ($nm.Success) {
                $fields[$nm.Groups[1].Value] = if ($vm.Success) { $vm.Groups[1].Value } else { "" }
            }
        }
    } catch { }
    return $fields
}

# Extract form action URL from HTML
function Get-FormActionUrl([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    try {
        $m = [regex]::Match($Html, '(?i)<form[^>]+action=["\x27]([^"\x27]*)["\x27]')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ""
}

# Resolve relative URL against a base URL — mirrors Linux resolve_url()
function Resolve-PortalUrl([string]$Base, [string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target)) { return $Base }
    if ($Target -match '^https?://') { return $Target }
    try {
        $baseUri = [System.Uri]$Base
        if ($Target.StartsWith('/')) {
            return "$($baseUri.Scheme)://$($baseUri.Authority)$Target"
        }
        $baseDir = $baseUri.AbsoluteUri -replace '[^/]+$', ''
        return "$baseDir$Target"
    } catch { return $Base }
}

# Extract a named query parameter from a URL string
function Get-QueryParam([string]$Url, [string]$Name) {
    try {
        $uri = [System.Uri]$Url
        $query = $uri.Query.TrimStart('?')
        foreach ($pair in $query -split '&') {
            $kv = $pair -split '=', 2
            if ($kv[0] -ieq $Name) {
                return [Uri]::UnescapeDataString($kv[1])
            }
        }
    } catch { }
    return ""
}

# ===========================================================================
# CORE LOGIN — FIX 2, 3, 4, 5 applied here
# ===========================================================================
function Invoke-UniLogin {
    # --- Wait for SSID + verify university network ---
    $ssid = ""
    for ($i = 0; $i -lt 5; $i++) {
        $ssid = Get-ActiveSSID
        if ($ssid -and (Test-UniversityNetwork $ssid)) { break }
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

    # Allow DHCP stack to settle
    Start-Sleep -Seconds 2

    # --- FIX 3: Aruba-aware online check ---
    if (Test-IsOnline) {
        if ($ssid -imatch 'uom\.wireless') {
            # gstatic is whitelisted by Aruba — confirm with secondary probe
            if (Test-ArubaOnline) {
                Write-UniLog "Already connected to the internet on $ssid." "Green"
                return
            }
            # ArubaOnline returned false → portal is still blocking → fall through to auth
            Write-UniLog "Captive portal detected on $ssid (Aruba). Authenticating..." "Yellow"
        } else {
            Write-UniLog "Already connected to the internet on $ssid." "Green"
            return
        }
    } else {
        Write-UniLog "Captive portal detected on $ssid. Authenticating..." "Yellow"
    }

    $creds = Get-SavedCredentials
    if (-not $creds) {
        Write-UniLog "Error: No saved credentials found. Run 'uninet setup' first." "Red"
        return
    }

    # Choose starting probe URL — Aruba intercepts ubuntu check, Cisco/Ruijie intercept gstatic
    $activeProbeUrl = if ($ssid -imatch 'uom\.wireless') { $ArubaProbeUrl } else { $ProbeUrl }

    # FIX 5: Persistent cookie jar — shared across ALL requests in this login session
    $cookieJar = New-Object System.Net.CookieContainer

    # --- FIX 2, STEP 1: Probe WITHOUT redirect — capture Location header ---
    # The Location header from captive portals contains session params (mac, ip, essid, etc.)
    $probe1 = Invoke-NoFollowProbe -Uri $activeProbeUrl -CookieJar $cookieJar
    $locationHeader = $probe1.Location

    # Extract Aruba gateway session parameters from the redirect URL
    # The Aruba controller embeds mac, ip, essid, apname, apgroup in the Location query string
    $arubaMac      = ""
    $arubaIp       = ""
    $arubaEssid    = ""
    $arubaApname   = ""
    $arubaApgroup  = ""
    $arubaRedirUrl = ""

    $srcUrl = if ($locationHeader) { $locationHeader } else { $activeProbeUrl }
    if ($srcUrl -match '\?') {
        $arubaMac      = Get-QueryParam -Url $srcUrl -Name "mac"
        # Aruba encodes colons in MAC as %3A
        $arubaMac      = $arubaMac -replace '%3[Aa]', ':'
        $arubaIp       = Get-QueryParam -Url $srcUrl -Name "ip"
        $arubaEssid    = Get-QueryParam -Url $srcUrl -Name "essid"
        $arubaApname   = Get-QueryParam -Url $srcUrl -Name "apname"
        $arubaApgroup  = Get-QueryParam -Url $srcUrl -Name "apgroup"
        $arubaRedirUrl = Get-QueryParam -Url $srcUrl -Name "url"
    }

    # --- FIX 2, STEP 2: Follow redirects to landing page, get form HTML ---
    $followUrl = if ($locationHeader) { $locationHeader } else { $activeProbeUrl }
    $probe2    = Invoke-FollowProbe -Uri $followUrl -CookieJar $cookieJar
    $formHtml  = $probe2.Body
    $portalBaseUrl = $probe2.EffectiveUrl
    if ([string]::IsNullOrWhiteSpace($portalBaseUrl)) { $portalBaseUrl = $followUrl }

    # Handle HTML meta-refresh redirect if portal uses it
    if ($formHtml -match '(?i)<meta[^>]+http-equiv=["\x27]refresh["\x27][^>]*url=([^">\x27\s]+)') {
        $metaUrl = $matches[1].Trim('"', "'")
        $resolved = Resolve-PortalUrl -Base $portalBaseUrl -Target $metaUrl
        if ($resolved -and $resolved -ne $portalBaseUrl) {
            $probe3 = Invoke-FollowProbe -Uri $resolved -CookieJar $cookieJar
            if ($probe3.Body) {
                $formHtml      = $probe3.Body
                $portalBaseUrl = $probe3.EffectiveUrl
            }
        }
    }

    # --- FIX 4, STEP 3: Parse HTML form — extract action URL and hidden fields ---
    $rawAction = Get-FormActionUrl -Html $formHtml
    $actionUrl = Resolve-PortalUrl -Base $portalBaseUrl -Target $rawAction
    if ([string]::IsNullOrWhiteSpace($actionUrl)) { $actionUrl = $portalBaseUrl }

    # Start payload with all hidden form fields (CSRF tokens, session IDs, etc.)
    $postBody = Get-HiddenFormFields -Html $formHtml

    # --- FIX 4, STEP 4: Smart credential injection — read actual field names from HTML ---
    $hasUsernameField = $formHtml -imatch 'name=["\x27]?username'
    $hasUserField     = $formHtml -imatch 'name=["\x27]?user["\x27\s>]'
    $hasPasswordField = $formHtml -imatch 'name=["\x27]?password'
    $hasPassField     = $formHtml -imatch 'name=["\x27]?pass["\x27\s>]'

    if ($hasUsernameField) { $postBody["username"] = $creds.username }
    if ($hasUserField)     { $postBody["user"]     = $creds.username }
    # Fallback: inject both if neither detected
    if (-not $hasUsernameField -and -not $hasUserField) {
        $postBody["username"] = $creds.username
        $postBody["user"]     = $creds.username
    }

    if ($hasPasswordField)          { $postBody["password"] = $creds.password }
    elseif ($hasPassField)          { $postBody["pass"]     = $creds.password }
    else                            { $postBody["password"] = $creds.password }

    # --- FIX 4, STEP 5: Vendor-specific payload injection ---

    # --- Cisco / NEC WebAuth (UoM_Wireless) ---
    # The Cisco portal's loginscript.js requires buttonClicked=4 to be accepted.
    # Without it, the form is treated as a cancel action.
    if ($actionUrl -like "*/login.html*" -or $formHtml -imatch 'name=["\x27]?buttonClicked') {
        # Force to 4 — override any 0 value extracted from hidden fields
        $postBody["buttonClicked"] = "4"
        $postBody["err_flag"]      = "0"
        Write-UniLog "Detected Cisco/NEC WebAuth portal (UoM_Wireless). Injecting buttonClicked=4..." "Cyan"
    }

    # --- Aruba Networks (UoM.Wireless) ---
    # Aruba controller requires: cmd=authenticate, user, password, mac, ip, essid, apname, apgroup, url
    if ($actionUrl -like "*cgi-bin/login*" -or $ssid -imatch 'uom\.wireless') {
        if ($actionUrl -notlike "*cgi-bin/login*") {
            $actionUrl = "https://connect.uom.lk/cgi-bin/login"
        }
        $postBody["cmd"]  = "authenticate"
        $postBody["user"] = $creds.username
        if ($arubaMac)      { $postBody["mac"]      = $arubaMac }
        if ($arubaIp)       { $postBody["ip"]        = $arubaIp }
        if ($arubaEssid)    { $postBody["essid"]     = $arubaEssid }
        if ($arubaApname)   { $postBody["apname"]    = $arubaApname }
        if ($arubaApgroup)  { $postBody["apgroup"]   = $arubaApgroup }
        if ($arubaRedirUrl) { $postBody["url"]       = $arubaRedirUrl }
        $postBody["Login"] = "Log In"
        Write-UniLog "Detected Aruba Networks portal (UoM.Wireless). Injecting Aruba session params..." "Cyan"
    }

    # --- Ruijie Networks (UoM-Wireless) ---
    # Ruijie portal runs on :8443; action must be /login not /index.html
    if ($actionUrl -like "*:8443*" -or $portalBaseUrl -like "*:8443*" -or $ssid -imatch 'uom-wireless') {
        if ($actionUrl -like "*/index.html") {
            $actionUrl = $actionUrl -replace '/index\.html$', '/login'
        } elseif ($actionUrl -match 'connect\.uom\.lk:8443/?$') {
            $actionUrl = "https://connect.uom.lk:8443/login"
        }
        if (-not $postBody.ContainsKey("username")) { $postBody["username"] = $creds.username }
        if (-not $postBody.ContainsKey("password")) { $postBody["password"] = $creds.password }
        Write-UniLog "Detected Ruijie Networks portal (UoM-Wireless). Submitting to $actionUrl..." "Cyan"
    }

    Write-UniLog "Submitting login credentials for $($creds.username)..." "Cyan"

    # --- STEP 6: POST with full cookie jar and Referer header ---
    Invoke-PortalPost -ActionUrl $actionUrl -Body $postBody -CookieJar $cookieJar -Referer $portalBaseUrl

    # --- STEP 7: Verify connection with grace period ---
    Start-Sleep -Seconds 1
    if (Test-IsOnline) {
        Write-UniLog "[+] Successfully connected! Internet is now active on $ssid." "Green"
        return
    }
    # 2-second gateway settling grace period (same as Linux)
    Start-Sleep -Seconds 2
    if (Test-IsOnline) {
        Write-UniLog "[+] Successfully connected! Internet is now active on $ssid." "Green"
        return
    }
    Write-UniLog "Notice: Credentials submitted. Verifying connection status..." "Yellow"
}

# ===========================================================================
# STATUS & VERSION CHECK
# ===========================================================================
function Test-VersionNotification {
    if (-not (Test-IsOnline)) { return }
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "UniNet-Windows/$Version")
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

# ===========================================================================
# SETUP — FIX 1: PSCredential instead of unsafe unmanaged memory APIs
# ===========================================================================
function Invoke-UniSetup {
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "         UNIVERSITY OF MORATUWA - CAMPUS WI-FI          " -ForegroundColor Cyan
    Write-Host "               UniNet Auto-Connect Engine               " -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan

    $ssid = Get-ActiveSSID
    if ($ssid) { Write-Host "Active Wi-Fi: $ssid`n" }

    $username = Read-Host "Student Username      "
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "Error: Username cannot be empty." -ForegroundColor Red
        return
    }

    $securePass = Read-Host "Network Password      " -AsSecureString

    # PSCredential.GetNetworkCredential() is the standard way to extract a plain-text password
    $credential = New-Object System.Management.Automation.PSCredential("uom", $securePass)
    $plainPass  = $credential.GetNetworkCredential().Password

    if ([string]::IsNullOrWhiteSpace($plainPass)) {
        Write-Host "Error: Password cannot be empty." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    $data = @{ username = $username; password = $plainPass } | ConvertTo-Json

    Set-Content -Path $CredsFile -Value $data -Encoding UTF8

    # FIX 7: Always write to ProgramData — Task Scheduler reads from here
    $sysDir = "C:\ProgramData\uninet"
    if (-not (Test-Path $sysDir)) {
        New-Item -ItemType Directory -Path $sysDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-Content -Path "$sysDir\credentials.json" -Value $data -Encoding UTF8 -ErrorAction SilentlyContinue

    # Attempt login immediately if on campus Wi-Fi
    if ($ssid -and (Test-UniversityNetwork $ssid)) {
        if (-not (Test-IsOnline)) { Invoke-UniLogin }
    }

    Add-TrustedNetworks

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "[+] Credentials securely saved!" -ForegroundColor Green
    Write-Host "You are all set!`n" -ForegroundColor Green
    Write-Host "UniNet will now automatically authenticate whenever you" -ForegroundColor Green
    Write-Host "connect to any of these university networks:" -ForegroundColor Green
    Write-Host "  - UoM_Wireless   (Cisco / NEC WebAuth)" -ForegroundColor Green
    Write-Host "  - UoM.Wireless   (Aruba Networks)" -ForegroundColor Green
    Write-Host "  - UoM-Wireless   (Ruijie Networks)" -ForegroundColor Green
    Write-Host "========================================================`n" -ForegroundColor Green
}

# ===========================================================================
# TRUST — register open WLAN profiles for auto-join
# ===========================================================================
function Add-TrustedNetworks {
    $ssids  = @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")
    $added  = 0

    $iface = ""
    try {
        $ifLines = netsh wlan show interfaces 2>$null
        $ifMatch = $ifLines | Where-Object { $_ -match '^\s*Name\s*:' } | Select-Object -First 1
        if ($ifMatch) { $iface = ($ifMatch -split ':', 2)[1].Trim() }
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
            Set-Content -Path $tmpFile -Value $profileXml -Encoding ASCII
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

# ===========================================================================
# SCAN & OPTIMIZE — unchanged, already working
# ===========================================================================
function Get-CampusNetworks([string]$FilterMode = "campus") {
    $networks    = @()
    $activeSSID  = Get-ActiveSSID

    try { $lines = netsh wlan show networks mode=bssid 2>$null } catch { return $networks }

    $currentSSID   = ""
    $currentBSSID  = ""
    $currentSignal = 0
    $currentBand   = "2.4 GHz"
    $currentRadio  = "802.11n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match "^SSID\s+\d+\s*:\s*(.*)$")         { $currentSSID   = $matches[1].Trim(); continue }
        if ($trimmed -match "^BSSID\s+\d+\s*:\s*(.*)$")        { $currentBSSID  = $matches[1].Trim(); continue }
        if ($trimmed -match "^Signal\s*:\s*(\d+)%")            { $currentSignal = [int]$matches[1];   continue }
        if ($trimmed -match "^Radio type\s*:\s*(.*)$")         { $currentRadio  = $matches[1].Trim(); continue }
        if ($trimmed -match "^Band\s*:\s*(.*)$")               { $currentBand   = $matches[1].Trim(); continue }

        if ($trimmed -match "^Channel\s*:\s*(\d+)") {
            $channel = [int]$matches[1]
            if ($channel -ge 36) { $currentBand = "5.0 GHz" }

            if (-not [string]::IsNullOrWhiteSpace($currentSSID)) {
                $include = ($FilterMode -eq "all") -or (Test-UniversityNetwork $currentSSID)
                if ($include) {
                    $is5GHz  = ($currentBand -like "*5*" -or $channel -ge 36)
                    $rate    = 130
                    if ($currentRadio -like "*ac*") { $rate = 866 }
                    elseif ($currentRadio -like "*ax*") { $rate = 1201 }
                    elseif ($is5GHz) { $rate = 433 }

                    $isActive  = ($currentSSID -eq $activeSSID)
                    $sigScore  = [math]::Round($currentSignal * 0.35, 1)
                    $bandBonus = if ($is5GHz -and $currentSignal -ge 20) { 30 } else { 0 }
                    $rateScore = [math]::Round(([math]::Min($rate, 866) / 866.0) * 35, 1)
                    $actBonus  = if ($isActive) { 12 } else { 0 }

                    $networks += [PSCustomObject]@{
                        Score    = [math]::Round($sigScore + $bandBonus + $rateScore + $actBonus, 1)
                        IsActive = $isActive
                        SSID     = $currentSSID
                        BSSID    = $currentBSSID
                        Band     = if ($is5GHz) { "5.0 GHz" } else { "2.4 GHz" }
                        Rate     = "$rate Mbit/s"
                        Signal   = "$currentSignal%"
                    }
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
    if (-not $results -or $results.Count -eq 0) { Write-Host "No Wi-Fi networks found."; return }

    $activeItem  = $results | Where-Object { $_.IsActive } | Select-Object -First 1
    $activeScore = if ($activeItem) { $activeItem.Score } else { 0 }

    Write-Host ("{0,-9} {1,-18} {2,-18} {3,-9} {4,-12} {5,-8} {6,-6}" -f "STATUS","SSID","BSSID","BAND","RATE","SIGNAL","SCORE")
    Write-Host "----------------------------------------------------------------------------------"
    foreach ($net in $results) {
        $status = "      "
        $suffix = ""
        if ($net.IsActive) { $status = "* ACTIVE" }
        elseif ($activeScore -gt 0 -and $net.Score -ge ($activeScore + 15)) { $status = "  BETTER"; $suffix = " (+)" }
        $line = "{0,-9} {1,-18} {2,-18} {3,-9} {4,-12} {5,-8} {6,-6}{7}" -f `
            $status, ($net.SSID -replace '^(.{18}).+$','$1'), $net.BSSID, $net.Band, $net.Rate, $net.Signal, $net.Score, $suffix
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
        Invoke-UniLogin; return
    }
    $top         = $results[0]
    $active      = $results | Where-Object { $_.IsActive } | Select-Object -First 1
    $activeScore = if ($active) { $active.Score } else { 0 }
    $activeSSID  = if ($active) { $active.SSID  } else { "" }

    if ($top.IsActive -or $top.SSID -eq $activeSSID) {
        Write-UniLog "Current connection '$activeSSID' is already the best available (Score: $($top.Score))." "Green"
    } elseif ($top.Score -ge ($activeScore + 15)) {
        $diff = [math]::Round($top.Score - $activeScore, 1)
        Write-UniLog "Found faster connection: '$($top.SSID)' (+$diff pts, $($top.Band), $($top.Rate))." "Green"
        Write-UniLog "Switching to '$($top.SSID)'..." "Cyan"
        $null = cmd.exe /c "netsh wlan connect name=`"$($top.SSID)`""
        Start-Sleep -Seconds 2
        Write-UniLog "[+] Connected to $($top.SSID)!" "Green"
    } else {
        Write-UniLog "Current connection '$activeSSID' is optimal (within 15-point stability margin)." "Yellow"
    }
    Write-UniLog "Probing captive portal..." "Cyan"
    Invoke-UniLogin
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
function Invoke-UniUninstall {
    Write-Host "Uninstalling UniNet for Windows..." -ForegroundColor Yellow
    $TaskName   = "UniNetAutoConnect"
    $InstallDir = "C:\ProgramData\uninet"

    $null = cmd.exe /c "schtasks /delete /tn `"$TaskName`" /f >nul 2>nul"
    foreach ($ssid in @("UoM_Wireless", "UoM.Wireless", "UoM-Wireless")) {
        $null = cmd.exe /c "netsh wlan delete profile name=`"$ssid`" >nul 2>nul"
    }

    $UserDir = "$env:APPDATA\uninet"
    if (Test-Path $UserDir) { Remove-Item -Path $UserDir -Recurse -Force -ErrorAction SilentlyContinue }

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

    $cleanupCmd = "ping 127.0.0.1 -n 2 >nul & rmdir /s /q `"$InstallDir`""
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cleanupCmd" -WindowStyle Hidden
    Write-Host "[+] UniNet has been completely removed from your Windows machine." -ForegroundColor Green
}

# ===========================================================================
# UPDATE
# ===========================================================================
function Invoke-UniUpdate {
    Write-UniLog "Checking for updates..." "Cyan"
    $latest = ""
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "UniNet-Windows/$Version")
        $latest = ($wc.DownloadString("$RepoRawUrl/VERSION")).Trim()
    } catch {
        Write-Host "Error: Unable to check for updates. Please check your internet connection." -ForegroundColor Red
        return
    }

    if (-not $latest) { Write-Host "Error: Empty version response." -ForegroundColor Red; return }
    if ($latest -eq $Version) { Write-Host "[+] UniNet is already up to date (v$Version)." -ForegroundColor Green; return }

    Write-Host "Found newer version: v$latest (current: v$Version). Upgrading..." -ForegroundColor Cyan

    $installDir  = "C:\ProgramData\uninet"
    $targetCore  = "$installDir\uninet_core.ps1"
    $tempFile    = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "uninet_new.ps1")

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "UniNet-Windows/$Version")

    $ok = $false
    foreach ($url in @(
        "https://github.com/dineTH2003-dev/uninet/releases/download/v$latest/uninet.ps1",
        "$RepoRawUrl/bin/uninet.ps1"
    )) {
        try {
            $wc.DownloadFile($url, $tempFile)
            if ((Test-Path $tempFile) -and ((Get-Item $tempFile).Length -ge 500)) { $ok = $true; break }
        } catch { }
    }

    if (-not $ok) { Write-Host "Error: Failed to download update from GitHub." -ForegroundColor Red; return }

    try {
        if (Test-Path $targetCore) { Copy-Item -Path $tempFile -Destination $targetCore -Force }
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Successfully updated UniNet to v$latest!" -ForegroundColor Green
    } catch {
        Write-Host "Error: Failed to apply update: $_" -ForegroundColor Red
    }
}

# ===========================================================================
# COMMAND ROUTER
# ===========================================================================
switch ($Command.ToLower()) {
    "login"     { Invoke-UniLogin }
    "optimize"  { Optimize-Connection }
    "best"      { Optimize-Connection }
    "scan"      { Show-CampusScan }
    "status"    { Show-UniStatus }
    "setup"     { Invoke-UniSetup }
    "trust"     { Add-TrustedNetworks }
    "update"    { Invoke-UniUpdate }
    "uninstall" { Invoke-UniUninstall }
    "help"      {
        Write-Host "UniNet Windows v$Version"
        Write-Host "Usage: uninet [login | optimize | scan | status | setup | trust | update | uninstall]"
    }
    default     { Invoke-UniLogin }
}
