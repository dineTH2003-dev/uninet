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

# Ensure System.Security is loaded for DPAPI (ProtectedData) in Windows PowerShell 5.1
try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
} catch { }

$Version = "1.2.4"
$RepoRawUrl     = "https://raw.githubusercontent.com/dineTH2003-dev/uninet/main"
$ConfigDir      = "$env:APPDATA\uninet"
$CredsFile      = "$ConfigDir\credentials.json"
$SysCredsFile   = "C:\ProgramData\uninet\credentials.json"

# Probing endpoints with test harness override support
$ProbeUrl       = if ($env:UNINET_TEST_PROBE_URL) { $env:UNINET_TEST_PROBE_URL } else { "http://connectivitycheck.gstatic.com/generate_204" }
$ArubaProbeUrl  = if ($env:UNINET_TEST_ARUBA_PROBE_URL) { $env:UNINET_TEST_ARUBA_PROBE_URL } else { "http://connectivity-check.ubuntu.com./" }
$MatchPatterns  = @("uom_wireless", "uom.wireless", "uom-wireless")

# Structured failure and diagnostic state tracking
$global:LastAuthStatus = "UNKNOWN"
$global:LastAuthErrorDetail = ""

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
# Portal SSL: Strict certificate validation by default.
# Prevents Evil Twin rogue AP credential theft by rejecting untrusted certs.
# Bypasses are strictly disallowed; private institutional CAs must be installed
# in the Windows trust store or explicitly pinned via UNINET_PINNED_CERT_THUMBPRINT.
# ---------------------------------------------------------------------------
function Initialize-UniTlsCallback {
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            # 1. Standard certificate chain validated via Windows certificate store
            if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) {
                return $true
            }
            # 2. Local loopback testing ONLY when explicitly permitted by test environment
            if ($env:UNINET_ALLOW_TEST_CERT -eq "1" -and $sender -is [System.Net.HttpWebRequest]) {
                $reqHost = $sender.RequestUri.Host.ToLower()
                if ($reqHost -eq "127.0.0.1" -or $reqHost -eq "localhost") {
                    return $true
                }
            }
            # 3. Explicitly pinned institutional certificate thumbprint (if configured)
            # Enforce 40-character hex thumbprint AND strict hostname binding to connect.uom.lk
            if ($env:UNINET_PINNED_CERT_THUMBPRINT -and $certificate) {
                $cleanThumb = $env:UNINET_PINNED_CERT_THUMBPRINT.Trim()
                if ($cleanThumb -match '^[0-9A-Fa-f]{40}$') {
                    $reqHost = ""
                    if ($sender -is [System.Net.HttpWebRequest]) {
                        $reqHost = $sender.RequestUri.Host.ToLower()
                    }
                    $isHostAuthorized = ($reqHost -eq "connect.uom.lk") -or
                        ($env:UNINET_ALLOW_TEST_CERT -eq "1" -and ($reqHost -eq "127.0.0.1" -or $reqHost -eq "localhost"))
                    if ($isHostAuthorized -and ($certificate.GetCertHashString() -ieq $cleanThumb)) {
                        return $true
                    }
                }
            }
            # Reject all other invalid or untrusted certificates
            return $false
        }
    } catch { }
}
Initialize-UniTlsCallback

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
    # Test harness override for automated test suites
    if ($env:UNINET_TEST_SSID) {
        return $env:UNINET_TEST_SSID
    }

    # Method 1: Get-NetConnectionProfile — FASTEST, locale-independent, works without Location API
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        foreach ($p in $profiles) {
            if ($p.Name -and (Test-UniversityNetwork $p.Name)) {
                return $p.Name
            }
        }
    } catch { }

    # Method 2: netsh wlan show interfaces
    try {
        $lines = netsh wlan show interfaces 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*SSID\s*:' -and $line -notmatch 'BSSID') {
                $val = ($line -split ':', 2)[1].Trim()
                if ($val) { return $val }
            }
        }
    } catch { }

    # Method 3: Any active Wi-Fi profile from Get-NetConnectionProfile
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        foreach ($p in $profiles) {
            if ($p.InterfaceAlias -match 'Wi-?Fi|Wireless|WLAN' -and $p.Name) {
                return $p.Name
            }
        }
    } catch { }

    # Method 4: WMI fallback
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

    return ""
}

function Test-UniversityNetwork([string]$SSID) {
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $false }
    $patterns = if ($MatchPatterns) { $MatchPatterns } else { @("uom_wireless", "uom.wireless", "uom-wireless") }
    $lower = $SSID.ToLower()
    foreach ($pat in $patterns) {
        if ($lower -like "*$pat*") { return $true }
    }
    return $false
}

# Standard online check (gstatic) — reliable for Cisco/Ruijie portals
function Test-IsOnline {
    try {
        $targetProbe = if ($env:UNINET_TEST_PROBE_URL) { $env:UNINET_TEST_PROBE_URL } else { $ProbeUrl }
        $req = [System.Net.HttpWebRequest]::Create($targetProbe)
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
        $targetProbe = if ($env:UNINET_TEST_ARUBA_PROBE_URL) { $env:UNINET_TEST_ARUBA_PROBE_URL } else { $ArubaProbeUrl }
        $req = [System.Net.HttpWebRequest]::Create($targetProbe)
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

# Unified online probe consistent with the active network controller
function Test-NetworkOnline([string]$SSID = "") {
    if ([string]::IsNullOrWhiteSpace($SSID)) { $SSID = Get-ActiveSSID }
    if ($SSID -imatch 'uom\.wireless') {
        return (Test-ArubaOnline)
    }
    return (Test-IsOnline)
}

# ---------------------------------------------------------------------------
# SECURITY: Validate that portal action/redirect endpoints match approved
# institutional domains or local network gateway addresses before sending credentials.
# ---------------------------------------------------------------------------
function Test-TrustedAuthEndpoint([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $uri = [System.Uri]$Url

        # Scheme must be HTTP or HTTPS
        if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
            return $false
        }

        $reqHost = $uri.Host.ToLower()

        # Local test loopback is permitted on any port for mock testing
        if ($reqHost -eq "127.0.0.1" -or $reqHost -eq "localhost") {
            return $true
        }

        # Remote endpoints: restricted strictly to connect.uom.lk
        if ($reqHost -ne "connect.uom.lk") {
            return $false
        }

        # Port validation for connect.uom.lk: restricted strictly to standard web and portal ports
        $port = $uri.Port
        if ($port -ne 80 -and $port -ne 443 -and $port -ne 8443) {
            return $false
        }

        return $true
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# CREDENTIAL ENCRYPTION (DPAPI)
# User-scoped DPAPI protection with strict security boundaries on Windows
# ---------------------------------------------------------------------------
function Protect-Secret([string]$PlainText) {
    if ([string]::IsNullOrEmpty($PlainText)) { return "" }
    $osIsWindows = ([Environment]::OSVersion.Platform -eq "Win32NT")
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Convert]::ToBase64String($enc)
    } catch {
        if ($osIsWindows) {
            # On Windows, cryptographic failures must NEVER fall back to plaintext.
            throw [System.Security.SecurityException]::new("DPAPI encryption failed on Windows: $($_.Exception.Message)")
        }
        # Non-Windows test runner fallback ONLY when running on Linux/macOS
        return $PlainText
    }
}

function Unprotect-Secret([string]$ProtectedText) {
    if ([string]::IsNullOrEmpty($ProtectedText)) { return "" }
    $osIsWindows = ([Environment]::OSVersion.Platform -eq "Win32NT")
    try {
        $bytes = [System.Convert]::FromBase64String($ProtectedText)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch {
        if ($osIsWindows) {
            # On Windows, corrupted or invalid ciphertext must NEVER trigger a plaintext fallback.
            return $null
        }
        # Non-Windows test host fallback
        return $ProtectedText
    }
}

function Get-SavedCredentials {
    # Test harness credentials override for isolated automation
    if ($env:UNINET_TEST_CREDS_FILE -and (Test-Path $env:UNINET_TEST_CREDS_FILE)) {
        try {
            $json = Get-Content -Raw -Path $env:UNINET_TEST_CREDS_FILE -ErrorAction Stop | ConvertFrom-Json
            if ($json.username -and $json.password) {
                $decPass = Unprotect-Secret $json.password
                if (-not [string]::IsNullOrEmpty($decPass)) {
                    return [PSCustomObject]@{
                        username = $json.username
                        password = $decPass
                    }
                }
            }
        } catch { }
    }

    # User-scoped credential path (%APPDATA%\uninet\credentials.json)
    if ($CredsFile -and (Test-Path $CredsFile)) {
        try {
            $json = Get-Content -Raw -Path $CredsFile -ErrorAction Stop | ConvertFrom-Json
            if ($json.username -and $json.password) {
                $decPass = Unprotect-Secret $json.password
                if (-not [string]::IsNullOrEmpty($decPass)) {
                    return [PSCustomObject]@{
                        username = $json.username
                        password = $decPass
                    }
                }
            }
        } catch { }
    }

    # Legacy fallback: check system credentials if present from older versions
    if ($SysCredsFile -and (Test-Path $SysCredsFile)) {
        try {
            $json = Get-Content -Raw -Path $SysCredsFile -ErrorAction Stop | ConvertFrom-Json
            if ($json.username -and $json.password) {
                $decPass = Unprotect-Secret $json.password
                if (-not [string]::IsNullOrEmpty($decPass)) {
                    return [PSCustomObject]@{
                        username = $json.username
                        password = $decPass
                    }
                }
            }
        } catch { }
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
        catch [System.Net.WebException] {
            if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
                $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
                $_.Exception.Message -match 'trust relationship|SSL/TLS') {
                $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
                $global:LastAuthErrorDetail = "TLS validation failed for probe '$Uri'."
            } elseif ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                $global:LastAuthStatus = "AUTHENTICATION_TIMEOUT"
                $global:LastAuthErrorDetail = "Probe connection timed out for '$Uri'."
            }
            $resp = $_.Exception.Response
        }

        if ($resp) {
            $result.StatusCode = [int]$resp.StatusCode
            $result.Location   = $resp.Headers["Location"]
            try {
                $sc = $resp.Headers.GetValues("Set-Cookie")
                if ($sc) {
                    $result.SetCookies = $sc
                    foreach ($cookieStr in $sc) {
                        try {
                            $CookieJar.SetCookies($req.RequestUri, $cookieStr)
                        } catch { }
                    }
                }
            } catch { }
            $resp.Close()
        }
    } catch {
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
            $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
            $_.Exception.Message -match 'trust relationship|SSL/TLS') {
            $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
            $global:LastAuthErrorDetail = "TLS validation failed for probe '$Uri'."
        }
    }
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
            if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
                $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
                $_.Exception.Message -match 'trust relationship|SSL/TLS') {
                $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
                $global:LastAuthErrorDetail = "TLS validation failed for landing page '$Uri'."
            } elseif ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                $global:LastAuthStatus = "AUTHENTICATION_TIMEOUT"
                $global:LastAuthErrorDetail = "Probe connection timed out for landing page '$Uri'."
            }
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
    } catch {
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
            $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
            $_.Exception.Message -match 'trust relationship|SSL/TLS') {
            $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
            $global:LastAuthErrorDetail = "TLS validation failed for landing page '$Uri'."
        }
    }
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
    # Security gatekeeper: prevent credentials from leaking to rogue APs
    if (-not (Test-TrustedAuthEndpoint $ActionUrl)) {
        $global:LastAuthStatus = "INVALID_AUTH_ENDPOINT"
        $global:LastAuthErrorDetail = "Target authentication endpoint '$ActionUrl' rejected by institutional domain security policy."
        Write-UniLog "Security Warning: Target URL '$ActionUrl' is not a trusted university or gateway domain. POST aborted." "Red"
        return
    }

    try {
        # URL-encode each field safely — coerce nulls to empty string to prevent ArgumentNullException
        $pairs = @()
        foreach ($k in $Body.Keys) {
            $val = if ($null -ne $Body[$k]) { [string]$Body[$k] } else { "" }
            $pairs += [Uri]::EscapeDataString($k) + "=" + [Uri]::EscapeDataString($val)
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
        catch [System.Net.WebException] {
            if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
                $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
                $_.Exception.Message -match 'trust relationship|SSL/TLS') {
                $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
                $global:LastAuthErrorDetail = "TLS validation failed during POST to '$ActionUrl'."
            } elseif ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                $global:LastAuthStatus = "AUTHENTICATION_TIMEOUT"
                $global:LastAuthErrorDetail = "Authentication request timed out while POSTing to '$ActionUrl'."
            } elseif ($_.Exception.Response) {
                $resp = $_.Exception.Response
                $statusCode = [int]$resp.StatusCode
                if ($statusCode -eq 401 -or $statusCode -eq 403) {
                    $global:LastAuthStatus = "AUTHENTICATION_REJECTED"
                    $global:LastAuthErrorDetail = "Portal server returned HTTP $statusCode authentication rejection."
                }
            }
        }
        if ($resp) { $resp.Close() }
    } catch {
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure -or
            $_.Exception.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure -or
            $_.Exception.Message -match 'trust relationship|SSL/TLS') {
            $global:LastAuthStatus = "TLS_VALIDATION_FAILED"
            $global:LastAuthErrorDetail = "TLS validation failed during POST to '$ActionUrl'."
        } elseif ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            $global:LastAuthStatus = "AUTHENTICATION_TIMEOUT"
            $global:LastAuthErrorDetail = "Authentication request timed out while POSTing to '$ActionUrl'."
        }
    }
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

# Resolve relative URL against a base URL — mirrors Linux resolve_url() with full RFC 3986 compliance
function Resolve-PortalUrl([string]$Base, [string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target)) { return $Base }
    if ($Target -match '^https?://') { return $Target }
    try {
        $baseUri = [System.Uri]$Base
        return ([System.Uri]::new($baseUri, $Target)).AbsoluteUri
    } catch {
        try {
            $baseUri = [System.Uri]$Base
            if ($Target.StartsWith('//')) {
                return "$($baseUri.Scheme):$Target"
            }
            if ($Target.StartsWith('/')) {
                return "$($baseUri.Scheme)://$($baseUri.Authority)$Target"
            }
            if ($Target.StartsWith('?')) {
                return "$($baseUri.AbsoluteUri.Split('?')[0])$Target"
            }
            $baseDir = $baseUri.AbsoluteUri -replace '[^/]+$', ''
        } catch { return $Base }
    }
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
    $global:LastAuthStatus = "UNKNOWN"
    $global:LastAuthErrorDetail = ""

    # --- Step 1: Detect active Wi-Fi or auto-connect to campus network ---
    $ssid = Get-ActiveSSID

    # If not connected or on non-campus network, proactively scan and connect!
    if ([string]::IsNullOrWhiteSpace($ssid) -or -not (Test-UniversityNetwork $ssid)) {
        Write-UniLog "Checking for available campus Wi-Fi networks..." "Cyan"
        $campus = Get-CampusNetworks "campus"
        if ($campus -and $campus.Count -gt 0) {
            $best = $campus[0]
            Write-UniLog "Detected campus network '$($best.SSID)' (Signal: $($best.Signal)). Connecting..." "Green"
            $null = cmd.exe /c "netsh wlan connect name=`"$($best.SSID)`""
            # Wait up to 10 seconds for association
            for ($wait = 0; $wait -lt 10; $wait++) {
                Start-Sleep -Seconds 1
                $ssid = Get-ActiveSSID
                if ($ssid -and (Test-UniversityNetwork $ssid)) { break }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ssid)) {
        $global:LastAuthStatus = "NETWORK_UNAVAILABLE"
        $global:LastAuthErrorDetail = "No active Wi-Fi connection detected and no campus network in range."
        Write-UniLog "No active Wi-Fi connection detected and no campus network in range." "Gray"
        return
    }

    if (-not (Test-UniversityNetwork $ssid)) {
        $global:LastAuthStatus = "WRONG_SSID"
        $global:LastAuthErrorDetail = "Connected network '$ssid' is not a recognized university network."
        Write-UniLog "Connected to non-university Wi-Fi ($ssid). Exiting." "Gray"
        return
    }

    # --- Step 2: Wait for DHCP lease and default gateway (up to 8s) ---
    if (-not $env:UNINET_TEST_SSID) {
        Write-UniLog "Verifying network gateway on $ssid..." "Cyan"
        for ($w = 0; $w -lt 8; $w++) {
            $hasRoute = $false
            try {
                $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
                if ($routes) { $hasRoute = $true; break }
            } catch { }
            Start-Sleep -Seconds 1
        }
        # Buffer for DNS resolution to initialize
        Start-Sleep -Seconds 1
    }

    $creds = Get-SavedCredentials
    if (-not $creds) {
        $global:LastAuthStatus = "CREDENTIALS_MISSING"
        $global:LastAuthErrorDetail = "No saved credentials found. Run 'uninet setup' first."
        Write-UniLog "Error: No saved credentials found. Run 'uninet setup' first." "Red"
        return
    }

    # --- Step 3: Portal Probe and Authentication with Retry Loop ---
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # Check if already online using SSID-aware probe
        if (Test-NetworkOnline -SSID $ssid) {
            $global:LastAuthStatus = "SUCCESS"
            $global:LastAuthErrorDetail = ""
            Write-UniLog "Already connected to the internet on $ssid." "Green"
            return
        } else {
            Write-UniLog "Captive portal detected on $ssid (Attempt $attempt/$maxAttempts). Authenticating..." "Yellow"
        }

        # Choose starting probe URL
        $targetProbe = if ($env:UNINET_TEST_PROBE_URL) { $env:UNINET_TEST_PROBE_URL } else { $ProbeUrl }
        $targetAruba = if ($env:UNINET_TEST_ARUBA_PROBE_URL) { $env:UNINET_TEST_ARUBA_PROBE_URL } else { $ArubaProbeUrl }
        $activeProbeUrl = if ($ssid -imatch 'uom\.wireless') { $targetAruba } else { $targetProbe }

        # Persistent cookie jar
        $cookieJar = New-Object System.Net.CookieContainer

        # STEP 1: Probe WITHOUT redirect to capture Location header and gateway params
        $probe1 = Invoke-NoFollowProbe -Uri $activeProbeUrl -CookieJar $cookieJar
        if ($global:LastAuthStatus -eq "TLS_VALIDATION_FAILED") {
            Write-UniLog "Security Alert: TLS validation failed during initial portal probe. Aborting." "Red"
            return
        }
        $locationHeader = $probe1.Location

        # Resolve relative Location header against active probe URL
        $resolvedLocation = if ($locationHeader) { Resolve-PortalUrl -Base $activeProbeUrl -Target $locationHeader } else { "" }

        # Security gatekeeper: validate redirect destination before following!
        if ($resolvedLocation) {
            if (-not (Test-TrustedAuthEndpoint $resolvedLocation)) {
                $global:LastAuthStatus = "UNTRUSTED_REDIRECT"
                $global:LastAuthErrorDetail = "Probe redirect target '$resolvedLocation' rejected by institutional domain security policy."
                Write-UniLog "Security Alert: Probe redirected to untrusted endpoint '$resolvedLocation'. Aborting login." "Red"
                return
            }
        }

        # Extract Aruba gateway session parameters
        $arubaMac      = ""
        $arubaIp       = ""
        $arubaEssid    = ""
        $arubaApname   = ""
        $arubaApgroup  = ""
        $arubaRedirUrl = ""

        $srcUrl = if ($resolvedLocation) { $resolvedLocation } else { $activeProbeUrl }
        if ($srcUrl -match '\?') {
            $arubaMac      = Get-QueryParam -Url $srcUrl -Name "mac"
            $arubaMac      = $arubaMac -replace '%3[Aa]', ':'
            $arubaIp       = Get-QueryParam -Url $srcUrl -Name "ip"
            $arubaEssid    = Get-QueryParam -Url $srcUrl -Name "essid"
            $arubaApname   = Get-QueryParam -Url $srcUrl -Name "apname"
            $arubaApgroup  = Get-QueryParam -Url $srcUrl -Name "apgroup"
            $arubaRedirUrl = Get-QueryParam -Url $srcUrl -Name "url"
        }

        # STEP 2: Follow redirects to landing page, get form HTML (ALWAYS using absolute URL)
        $followUrl = if ($resolvedLocation) { $resolvedLocation } else { $activeProbeUrl }
        $probe2    = Invoke-FollowProbe -Uri $followUrl -CookieJar $cookieJar
        if ($global:LastAuthStatus -eq "TLS_VALIDATION_FAILED") {
            Write-UniLog "Security Alert: TLS validation failed while fetching portal landing page. Aborting." "Red"
            return
        }
        $formHtml  = $probe2.Body
        $portalBaseUrl = $probe2.EffectiveUrl
        if ([string]::IsNullOrWhiteSpace($portalBaseUrl)) { $portalBaseUrl = $followUrl }

        # Handle HTML meta-refresh redirect if present
        if ($formHtml -match '(?i)<meta[^>]+http-equiv=["\x27]refresh["\x27][^>]*url=([^">\x27\s]+)') {
            $metaUrl = $matches[1].Trim('"', "'")
            $resolved = Resolve-PortalUrl -Base $portalBaseUrl -Target $metaUrl
            if ($resolved -and $resolved -ne $portalBaseUrl) {
                if (-not (Test-TrustedAuthEndpoint $resolved)) {
                    $global:LastAuthStatus = "UNTRUSTED_REDIRECT"
                    $global:LastAuthErrorDetail = "Meta-refresh redirect target '$resolved' rejected by institutional domain security policy."
                    Write-UniLog "Security Alert: Meta-refresh redirected to untrusted endpoint '$resolved'. Aborting login." "Red"
                    return
                }
                $probe3 = Invoke-FollowProbe -Uri $resolved -CookieJar $cookieJar
                if ($probe3.Body) {
                    $formHtml      = $probe3.Body
                    $portalBaseUrl = $probe3.EffectiveUrl
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($formHtml)) {
            $global:LastAuthStatus = "PORTAL_REDIRECT_ERROR"
            $global:LastAuthErrorDetail = "Unable to fetch captive portal form content."
        }

        # STEP 3: Parse HTML form action and hidden fields
        $rawAction = Get-FormActionUrl -Html $formHtml
        $actionUrl = Resolve-PortalUrl -Base $portalBaseUrl -Target $rawAction
        if ([string]::IsNullOrWhiteSpace($actionUrl)) { $actionUrl = $portalBaseUrl }

        $postBody = Get-HiddenFormFields -Html $formHtml

        # STEP 4: Credential injection
        $hasUsernameField = $formHtml -imatch 'name=["\x27]?username'
        $hasUserField     = $formHtml -imatch 'name=["\x27]?user["\x27\s>]'
        $hasPasswordField = $formHtml -imatch 'name=["\x27]?password'
        $hasPassField     = $formHtml -imatch 'name=["\x27]?pass["\x27\s>]'

        if ($hasUsernameField) { $postBody["username"] = $creds.username }
        if ($hasUserField)     { $postBody["user"]     = $creds.username }
        if (-not $hasUsernameField -and -not $hasUserField) {
            $postBody["username"] = $creds.username
            $postBody["user"]     = $creds.username
        }

        if ($hasPasswordField)          { $postBody["password"] = $creds.password }
        elseif ($hasPassField)          { $postBody["pass"]     = $creds.password }
        else                            { $postBody["password"] = $creds.password }

        # STEP 5: Vendor-specific payload injection
        # Cisco / NEC WebAuth
        if ($actionUrl -like "*/login.html*" -or $formHtml -imatch 'name=["\x27]?buttonClicked') {
            $postBody["buttonClicked"] = "4"
            $postBody["err_flag"]      = "0"
            Write-UniLog "Detected Cisco/NEC WebAuth portal (UoM_Wireless). Injecting buttonClicked=4..." "Cyan"
        }

        # Aruba Networks
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

        # Ruijie Networks
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

        # STEP 6: POST with full cookie jar and Referer header
        Invoke-PortalPost -ActionUrl $actionUrl -Body $postBody -CookieJar $cookieJar -Referer $portalBaseUrl

        if ($global:LastAuthStatus -eq "INVALID_AUTH_ENDPOINT" -or $global:LastAuthStatus -eq "TLS_VALIDATION_FAILED") {
            return
        }

        # STEP 7: Verify connection
        Start-Sleep -Seconds 1
        if (Test-NetworkOnline -SSID $ssid) {
            $global:LastAuthStatus = "SUCCESS"
            $global:LastAuthErrorDetail = ""
            Write-UniLog "[+] Successfully connected! Internet is now active on $ssid." "Green"
            return
        }
        Start-Sleep -Seconds 2
        if (Test-NetworkOnline -SSID $ssid) {
            $global:LastAuthStatus = "SUCCESS"
            $global:LastAuthErrorDetail = ""
            Write-UniLog "[+] Successfully connected! Internet is now active on $ssid." "Green"
            return
        }

        if ($attempt -lt $maxAttempts) {
            Write-UniLog "Verification pending. Retrying in 2 seconds..." "Yellow"
            Start-Sleep -Seconds 2
        }
    }

    if ($global:LastAuthStatus -eq "UNKNOWN") {
        $global:LastAuthStatus = "CONNECTIVITY_VERIFICATION_FAILED"
        $global:LastAuthErrorDetail = "Verification probe failed to confirm internet access after $maxAttempts attempts."
    }
    Write-UniLog "Notice: Login credentials submitted. Status: $global:LastAuthStatus" "Yellow"
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
        if ($latest) {
            $isNewer = $false
            try {
                if ([version]$latest -gt [version]$Version) { $isNewer = $true }
            } catch {
                if ($latest -ne $Version) { $isNewer = $true }
            }
            if ($isNewer) {
                Write-Host "[*] A new version of UniNet is available (v$latest)." -ForegroundColor Yellow
                Write-Host "    Run 'uninet update' to upgrade automatically.`n" -ForegroundColor Yellow
            }
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
        Write-Host "Internet:       ONLINE (Direct Internet Access confirmed)" -ForegroundColor Green
    } else {
        Write-Host "Internet:       CAPTIVE PORTAL / OFFLINE" -ForegroundColor Yellow
    }
    if ($global:LastAuthStatus -and $global:LastAuthStatus -ne "UNKNOWN") {
        Write-Host "Last Auth:      $global:LastAuthStatus" -ForegroundColor $(if ($global:LastAuthStatus -eq "SUCCESS") { "Green" } else { "Yellow" })
        if ($global:LastAuthErrorDetail) {
            Write-Host "Diagnostics:    $global:LastAuthErrorDetail" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Test-VersionNotification
}

# ===========================================================================
# TASK SCHEDULER — PER-USER INTERACTIVE REGISTRATION
# ===========================================================================
function Register-UniScheduledTask {
    param([string]$InstallDir = "C:\ProgramData\uninet")
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ([string]::IsNullOrWhiteSpace($currentUser)) {
            $currentUser = "$env:USERDOMAIN\$env:USERNAME"
        }
        $userClean = $env:USERNAME
        if (-not $userClean) { $userClean = ($currentUser -split '\\')[-1] }
        $taskName  = "UniNetAutoConnect_$userClean"
        $vbsDest   = "$InstallDir\uninet_silent.vbs"
        $action    = "wscript.exe"
        $arguments = "//nologo `"$vbsDest`""

        # Check if vbs launcher exists
        if (-not (Test-Path $vbsDest)) { return $false }

        # Remove any legacy group task or previous per-user task
        $null = cmd.exe /c "schtasks /delete /tn `"UniNetAutoConnect`" /f >nul 2>nul"
        $null = cmd.exe /c "schtasks /delete /tn `"$taskName`" /f >nul 2>nul"

        $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;Query Id="1" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;&lt;Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;*[System[(EventID=8001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5S</Delay>
      <UserId>$currentUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$currentUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$action</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        $tmpXml = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "uninet_task_$userClean.xml")
        [System.IO.File]::WriteAllText($tmpXml, $taskXml, [System.Text.Encoding]::Unicode)
        $null = cmd.exe /c "schtasks /create /tn `"$taskName`" /xml `"$tmpXml`" /f >nul 2>nul"
        Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
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

    # Restrict ACL on user config directory
    try {
        $acl = Get-Acl $ConfigDir
        $acl.SetAccessRuleProtection($true, $false)
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $userRule  = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($userRule)
        $acl.AddAccessRule($adminRule)
        Set-Acl -Path $ConfigDir -AclObject $acl
    } catch { }

    # Save credentials encrypted with DPAPI (CurrentUser scope)
    try {
        $encPass = Protect-Secret $plainPass
        if ([string]::IsNullOrEmpty($encPass)) {
            Write-Host "Error: Failed to encrypt credentials. Setup aborted." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host "Security Error: Credential protection failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Credentials were NOT stored to prevent plaintext exposure." -ForegroundColor Yellow
        return
    }

    $isEncrypted = ($encPass -ne $plainPass)
    if ([Environment]::OSVersion.Platform -eq "Win32NT" -and -not $isEncrypted) {
        Write-Host "Security Error: DPAPI encryption was bypassed on Windows. Setup aborted." -ForegroundColor Red
        return
    }

    $data = @{ username = $username; password = $encPass; encrypted = $isEncrypted } | ConvertTo-Json

    Set-Content -Path $CredsFile -Value $data -Encoding UTF8

    # Security: Remove any legacy shared credentials file in ProgramData
    Remove-Item -Path $SysCredsFile -Force -ErrorAction SilentlyContinue

    # Register per-user auto-connect task in Task Scheduler
    Register-UniScheduledTask

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
        # Generate hex encoding of SSID for WLANProfile schema compliance
        $hexChars = ($ssid.ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ''

        $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssid</name>
    <SSIDConfig>
        <SSID>
            <hex>$hexChars</hex>
            <name>$ssid</name>
        </SSID>
        <nonBroadcast>false</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <autoSwitch>true</autoSwitch>
    <MSM>
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
    </MSM>
</WLANProfile>
"@

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
        Write-UniLog "Registered $added university network profile(s) for automatic Wi-Fi join with priority 1." "Green"
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
    if ($env:USERNAME) {
        $null = cmd.exe /c "schtasks /delete /tn `"UniNetAutoConnect_$($env:USERNAME)`" /f >nul 2>nul"
    }
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

    $isNewer = $false
    try {
        if ([version]$latest -gt [version]$Version) { $isNewer = $true }
    } catch {
        if ($latest -ne $Version) { $isNewer = $true }
    }
    if (-not $isNewer) { Write-Host "[+] UniNet is already up to date (v$Version)." -ForegroundColor Green; return }

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
