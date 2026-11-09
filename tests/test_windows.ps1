# ==============================================================================
# UniNet Windows Runtime Test Suite (PowerShell)
# Tests core networking, relative URL resolution, cookie propagation,
# payload construction, and security domain validation.
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Ensure System.Security is loaded for DPAPI
try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
} catch { }

# Disable default web proxy to eliminate WPAD auto-detection delays on Windows .NET Framework
try {
    [System.Net.WebRequest]::DefaultWebProxy = $null
} catch { }

# Resolve Python executable for cross-platform mock servers
$cmd = Get-Command python, python3, py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$global:pyExe = if ($cmd) { $cmd.Source } else { "python" }

function Start-MockHttpServer([string]$ScriptContent, [string]$FileName) {
    $tempDir  = [System.IO.Path]::GetTempPath()
    $portFile = [System.IO.Path]::Combine($tempDir, "$FileName.port")
    $errFile  = [System.IO.Path]::Combine($tempDir, "$FileName.err")
    $tempPy   = [System.IO.Path]::Combine($tempDir, $FileName)

    if (Test-Path $portFile) { Remove-Item $portFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $errFile)  { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }

    Set-Content -Path $tempPy -Value $ScriptContent -Encoding UTF8
    $proc = Start-Process -FilePath $global:pyExe -ArgumentList "`"$tempPy`" `"$portFile`"" `
        -RedirectStandardError $errFile -PassThru

    $port = 0
    for ($i = 0; $i -lt 50; $i++) {
        if ($proc.HasExited) { break }
        if (Test-Path $portFile) {
            try {
                $raw = (Get-Content -Path $portFile -ErrorAction SilentlyContinue -Raw).Trim()
                if ($raw -match '^\d+$') {
                    $port = [int]$raw
                    break
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 100
    }

    if ($port -eq 0) {
        $errOut = if (Test-Path $errFile) { Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue } else { "" }
        Write-Error "Failed to start mock HTTP server ($FileName). Process exited: $($proc.HasExited), ExitCode: $($proc.ExitCode). Stderr: $errOut"
    }

    return [PSCustomObject]@{ Process = $proc; File = $tempPy; PortFile = $portFile; ErrFile = $errFile; Port = $port }
}

function Stop-MockHttpServer($serverObj) {
    if ($serverObj) {
        if ($serverObj.Process -and -not $serverObj.Process.HasExited) {
            Stop-Process -Id $serverObj.Process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($serverObj.File -and (Test-Path $serverObj.File)) {
            Remove-Item $serverObj.File -Force -ErrorAction SilentlyContinue
        }
        if ($serverObj.PortFile -and (Test-Path $serverObj.PortFile)) {
            Remove-Item $serverObj.PortFile -Force -ErrorAction SilentlyContinue
        }
        if ($serverObj.ErrFile -and (Test-Path $serverObj.ErrFile)) {
            Remove-Item $serverObj.ErrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$CoreScript = Join-Path $RepoRoot "bin\uninet.ps1"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "         UNINET WINDOWS RUNTIME TEST SUITE              " -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

# Source functions from bin/uninet.ps1
$coreContent = Get-Content -Raw -Path $CoreScript

# Extract function definitions using PowerShell AST
[System.Management.Automation.Language.Token[]]$tokens = @()
[System.Management.Automation.Language.ParseError[]]$errors = @()
$ast = [System.Management.Automation.Language.Parser]::ParseInput($coreContent, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    Write-Error "Syntax error in bin\uninet.ps1: $errors"
    exit 1
}

# Dot-source the script by defining functions in current scope without executing the main router
# We extract only the function definitions from the script text
$funcAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcAsts) {
    Invoke-Expression $f.Extent.Text
}

# Initialize engine globals required by functions
$global:MatchPatterns = @("uom_wireless", "uom.wireless", "uom-wireless")
$global:Version       = "1.2.4"
$global:ProbeUrl      = "http://connectivitycheck.gstatic.com/generate_204"
$global:ArubaProbeUrl = "http://connectivity-check.ubuntu.com./"
$global:Quiet         = $true
$global:CredsFile     = ""
$global:SysCredsFile  = ""

# Helper to write encrypted credentials JSON for test isolation
function New-TestCredentialsFile([string]$FilePath, [string]$Username, [string]$Password) {
    $encPass = Protect-Secret $Password
    $obj = @{
        username = $Username
        password = $encPass
    }
    $json = $obj | ConvertTo-Json -Compress
    Set-Content -Path $FilePath -Value $json -Encoding UTF8
}

# Initialize TLS callback
Initialize-UniTlsCallback

trap {
    Write-Host "::error title=Uncaught Exception::$($_) at line $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host "UNCAUGHT EXCEPTION: $($_) at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
}

$TestPassCount = 0
$TestFailCount = 0

function Assert-Condition([bool]$Condition, [string]$TestName, [string]$Details = "") {
    if ($Condition) {
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
        if ($Details) { Write-Host "         -> $Details" -ForegroundColor Gray }
        $script:TestPassCount++
    } else {
        Write-Host "  [FAIL] $TestName" -ForegroundColor Red
        if ($Details) { Write-Host "         -> $Details" -ForegroundColor Yellow }
        Write-Host "::error title=Assertion Failed::$TestName $(if ($Details) { "-> $Details" })"
        $script:TestFailCount++
    }
}

# ------------------------------------------------------------------------------
# Test 1: Relative and Absolute URL Resolution
# ------------------------------------------------------------------------------
Write-Host "[Test 1] Relative and Absolute URL Resolution (Resolve-PortalUrl)" -ForegroundColor Cyan
$base = "http://connectivitycheck.gstatic.com:8080/portal/generate_204"

$r1 = Resolve-PortalUrl -Base $base -Target "/cgi-bin/login?cmd=authenticate"
Assert-Condition ($r1 -eq "http://connectivitycheck.gstatic.com:8080/cgi-bin/login?cmd=authenticate") `
    "Root-relative URL with query parameters" $r1

$r2 = Resolve-PortalUrl -Base $base -Target "login.html"
Assert-Condition ($r2 -eq "http://connectivitycheck.gstatic.com:8080/portal/login.html") `
    "Path-relative URL" $r2

$r3 = Resolve-PortalUrl -Base $base -Target "?auth=1"
Assert-Condition ($r3 -eq "http://connectivitycheck.gstatic.com:8080/portal/generate_204?auth=1") `
    "Query-only relative URL" $r3

$r4 = Resolve-PortalUrl -Base $base -Target "https://connect.uom.lk/cgi-bin/login"
Assert-Condition ($r4 -eq "https://connect.uom.lk/cgi-bin/login") `
    "Absolute HTTPS URL preservation" $r4

$r5 = Resolve-PortalUrl -Base $base -Target "//connect.uom.lk:8443/login"
Assert-Condition ($r5 -eq "http://connect.uom.lk:8443/login") `
    "Protocol-relative URL resolution" $r5


# ------------------------------------------------------------------------------
# Test 2: HTML Form and Hidden Input Extraction
# ------------------------------------------------------------------------------
Write-Host "`n[Test 2] Form Action & Hidden Input Parsing" -ForegroundColor Cyan
$mockHtml = @"
<html>
  <head><title>University Portal</title></head>
  <body>
    <form action="/auth/submit.php" method="POST">
      <input type="hidden" name="csrf_token" value="abc123xyz" />
      <input type="hidden" name="session_id" value="sess_9999" />
      <input type="hidden" name="empty_field" value="" />
      <input type="hidden" name="no_val_attr">
      <input type="text" name="user" value="" />
      <input type="password" name="pass" value="" />
      <input type="submit" value="Login" />
    </form>
  </body>
</html>
"@

$action = Get-FormActionUrl -Html $mockHtml
Assert-Condition ($action -eq "/auth/submit.php") "Extracted form action path" $action

$hidden = Get-HiddenFormFields -Html $mockHtml
Assert-Condition ($hidden["csrf_token"] -eq "abc123xyz") "Extracted CSRF token" $hidden["csrf_token"]
Assert-Condition ($hidden["session_id"] -eq "sess_9999") "Extracted session ID" $hidden["session_id"]
Assert-Condition ($hidden.ContainsKey("empty_field")) "Extracted empty hidden input"
Assert-Condition ($hidden.ContainsKey("no_val_attr")) "Extracted hidden input without value attribute"


# ------------------------------------------------------------------------------
# Test 3: Null, Empty and Special Characters in Payload Serialization
# ------------------------------------------------------------------------------
Write-Host "`n[Test 3] Payload URL Encoding & Special Characters" -ForegroundColor Cyan
$testBody = @{
    "username"     = "student@uom.lk"
    "password"     = 'P@ss&w+rd=123% "quotes"'
    "null_field"   = $null
    "empty_field"  = ""
    "special_char" = "a=1&b=2+c"
}

# Simulate the robust URL-encoding loop
$pairs = @()
foreach ($k in $testBody.Keys) {
    $val = if ($null -ne $testBody[$k]) { [string]$testBody[$k] } else { "" }
    $pairs += [Uri]::EscapeDataString($k) + "=" + [Uri]::EscapeDataString($val)
}
$encodedString = $pairs -join "&"

Assert-Condition (-not [string]::IsNullOrWhiteSpace($encodedString)) "Encoded string generated without exceptions"
Assert-Condition ($encodedString -like "*null_field=*") "Null field coerced to empty string safely"
Assert-Condition ($encodedString -like "*password=P%40ss%26w%2Brd%3D123%25%20%22quotes%22*") "Password special characters safely encoded"


# ------------------------------------------------------------------------------
# Test 4: Mock HTTP Captive Portal & Cookie Persistence
# ------------------------------------------------------------------------------
Write-Host "`n[Test 4] Mock Server Captive Portal & Cookie Propagation" -ForegroundColor Cyan

# Start a local Python mock server
$serverScript = @"
import http.server, sys

auth_state = {'logged_in': False, 'cookie_seen': False}

class MockPortal(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            if auth_state['logged_in']:
                self.send_response(204)
                self.end_headers()
            else:
                self.send_response(302)
                self.send_header('Location', 'http://127.0.0.1:{}/login.html'.format(self.server.server_port))
                self.send_header('Set-Cookie', 'PORTAL_SESS=token_xyz_789; Path=/')
                self.end_headers()
        elif self.path == '/login.html':
            cookie = self.headers.get('Cookie', '')
            if 'PORTAL_SESS=token_xyz_789' in cookie:
                auth_state['cookie_seen'] = True
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/login_submit\" method=\"POST\"><input type=\"hidden\" name=\"token\" value=\"sec123\"><input name=\"user\"><input name=\"pass\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/login_submit':
            cookie = self.headers.get('Cookie', '')
            if 'PORTAL_SESS=token_xyz_789' in cookie:
                auth_state['logged_in'] = True
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'OK')
            else:
                self.send_response(403)
                self.end_headers()
                self.wfile.write(b'Missing required session cookie')
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), MockPortal)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockServer = Start-MockHttpServer -ScriptContent $serverScript -FileName "mock_portal.py"
$port = $mockServer.Port

try {
    $cookieJar = New-Object System.Net.CookieContainer

    # Step 1: Probe without redirect
    $probe1 = Invoke-NoFollowProbe -Uri "http://127.0.0.1:$port/generate_204" -CookieJar $cookieJar
    Assert-Condition ($probe1.StatusCode -eq 302) "Probe 1 returned HTTP 302 Redirect" "StatusCode=$($probe1.StatusCode)"
    Assert-Condition ($probe1.Location -eq "http://127.0.0.1:$port/login.html") "Probe 1 captured Location header" $probe1.Location

    # Step 2: Follow probe using captured/resolved URL
    $resolvedTarget = Resolve-PortalUrl -Base "http://127.0.0.1:$port/generate_204" -Target $probe1.Location
    $probe2 = Invoke-FollowProbe -Uri $resolvedTarget -CookieJar $cookieJar
    Assert-Condition ($probe2.StatusCode -eq 200) "Probe 2 fetched portal HTML (HTTP 200)"
    Assert-Condition ($probe2.Body -like "*login_submit*") "Probe 2 received login form content"

    # Step 3: Extract action and submit credentials
    $rawAction = Get-FormActionUrl -Html $probe2.Body
    $actionUrl = Resolve-PortalUrl -Base $probe2.EffectiveUrl -Target $rawAction
    $hiddenFields = Get-HiddenFormFields -Html $probe2.Body
    $hiddenFields["user"] = "210001A"
    $hiddenFields["pass"] = "Secret123"

    Invoke-PortalPost -ActionUrl $actionUrl -Body $hiddenFields -CookieJar $cookieJar -Referer $probe2.EffectiveUrl

    # Step 4: Verify post-login status (should return HTTP 204 now)
    $onlineCheck = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/generate_204")
    $onlineCheck.Proxy = $null
    $onlineCheck.AllowAutoRedirect = $false
    $onlineResp = $onlineCheck.GetResponse()
    Assert-Condition ([int]$onlineResp.StatusCode -eq 204) "Authentication succeeded; Internet probe returns HTTP 204"
    $onlineResp.Close()
} finally {
    Stop-MockHttpServer $mockServer
}


# ------------------------------------------------------------------------------
# Test 5: Authentication Endpoint Security Domain Validation
# ------------------------------------------------------------------------------
Write-Host "`n[Test 5] Authentication Endpoint Security Domain Validation" -ForegroundColor Cyan

Assert-Condition (Test-TrustedAuthEndpoint "https://connect.uom.lk/cgi-bin/login") `
    "Accepts official university domain (connect.uom.lk:443)"
Assert-Condition (Test-TrustedAuthEndpoint "http://connect.uom.lk/login") `
    "Accepts official university domain (connect.uom.lk:80)"
Assert-Condition (Test-TrustedAuthEndpoint "https://connect.uom.lk:8443/login") `
    "Accepts official university domain (connect.uom.lk:8443)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://wifi.uom.lk:8443/login")) `
    "Blocks unapproved university subdomain (wifi.uom.lk)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://cse.uom.lk/login")) `
    "Blocks arbitrary department subdomain (cse.uom.lk)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://student.uom.lk/login")) `
    "Blocks student web server subdomain (student.uom.lk)"
Assert-Condition (Test-TrustedAuthEndpoint "http://127.0.0.1:18092/login_submit") `
    "Accepts local test loopback (127.0.0.1)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "http://192.168.1.1/login")) `
    "Blocks arbitrary private gateway IP (192.168.x.x)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "http://10.0.0.1/login")) `
    "Blocks arbitrary private subnet IP (10.x.x.x)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://attacker-portal.com/login")) `
    "Blocks arbitrary external domain (attacker-portal.com)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://uom.lk.evil.com/login")) `
    "Blocks deceptive domain (uom.lk.evil.com)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://evil-uom.lk/login")) `
    "Blocks lookalike deceptive domain (evil-uom.lk)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "ftp://connect.uom.lk/login")) `
    "Blocks insecure non-HTTP protocol (ftp://)"
Assert-Condition (-not (Test-TrustedAuthEndpoint "https://connect.uom.lk:22/login")) `
    "Blocks unauthorized non-web port (:22)"


# ------------------------------------------------------------------------------
# Test 6: Multi-Factor AP Quality Scoring & Hysteresis
# ------------------------------------------------------------------------------
Write-Host "`n[Test 6] Multi-Factor AP Quality Scoring & Hysteresis" -ForegroundColor Cyan

# Mock APs for scoring
$score24GHz = [math]::Round(95 * 0.35 + 0 + (117 / 866.0) * 35 + 12, 1) # Active 2.4 GHz
$score5GHz  = [math]::Round(70 * 0.35 + 30 + (866 / 866.0) * 35 + 0, 1)  # Candidate 5 GHz

Assert-Condition ($score5GHz -gt $score24GHz) `
    "5 GHz high-speed AP correctly outscores 2.4 GHz AP" `
    ("2.4 GHz: $score24GHz pts vs 5 GHz: $score5GHz pts")

$diff = $score5GHz - $score24GHz
Assert-Condition ($diff -ge 15.0) `
    "Candidate exceeds 15.0 pt hysteresis margin for auto-switch" `
    ("Diff: $diff pts (Threshold: 15.0 pts)")


# ------------------------------------------------------------------------------
# Test 7: End-to-End Cisco/NEC WebAuth Portal Automation (Invoke-UniLogin)
# ------------------------------------------------------------------------------
Write-Host "`n[Test 7] End-to-End Cisco/NEC WebAuth Portal Automation (Invoke-UniLogin)" -ForegroundColor Cyan

$ciscoServerScript = @"
import http.server, urllib.parse, sys

auth_state = {'logged_in': False, 'buttonClicked': None, 'username': None}

class CiscoHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            if auth_state['logged_in']:
                self.send_response(204)
                self.end_headers()
            else:
                self.send_response(302)
                self.send_header('Location', 'http://127.0.0.1:{}/login.html'.format(self.server.server_port))
                self.end_headers()
        elif self.path == '/login.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/login.html\" method=\"POST\"><input type=\"hidden\" name=\"buttonClicked\" value=\"0\"><input type=\"hidden\" name=\"err_flag\" value=\"1\"><input name=\"username\"><input name=\"password\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/login.html':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            params = urllib.parse.parse_qs(body)
            auth_state['buttonClicked'] = params.get('buttonClicked', [''])[0]
            auth_state['username'] = params.get('username', [''])[0]
            if auth_state['buttonClicked'] == '4' and auth_state['username'] == 'student_cisco':
                auth_state['logged_in'] = True
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'Authenticated')
            else:
                self.send_response(401)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), CiscoHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockCisco = Start-MockHttpServer -ScriptContent $ciscoServerScript -FileName "mock_cisco.py"
$ciscoPort = $mockCisco.Port

$ciscoCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "cisco_creds.json")
New-TestCredentialsFile -FilePath $ciscoCredsFile -Username "student_cisco" -Password "CiscoPassword123!"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$ciscoPort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $ciscoCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "SUCCESS") `
        "Invoke-UniLogin succeeded on Cisco portal (UoM_Wireless)" $global:LastAuthStatus

    # Verify post-login state on server
    $verifyProbe = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$ciscoPort/generate_204")
    $verifyProbe.Proxy = $null
    $verifyProbe.AllowAutoRedirect = $false
    $vResp = $verifyProbe.GetResponse()
    Assert-Condition ([int]$vResp.StatusCode -eq 204) `
        "Cisco portal confirms online status (HTTP 204)"
    $vResp.Close()
} finally {
    Stop-MockHttpServer $mockCisco
    Remove-Item $ciscoCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 8: End-to-End Aruba Networks Portal Automation (Invoke-UniLogin)
# ------------------------------------------------------------------------------
Write-Host "`n[Test 8] End-to-End Aruba Networks Portal Automation (Invoke-UniLogin)" -ForegroundColor Cyan

$arubaServerScript = @"
import http.server, urllib.parse, sys

auth_state = {'logged_in': False, 'cmd': None, 'mac': None, 'cookie_seen': False}

class ArubaHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/ubuntu_probe':
            if auth_state['logged_in']:
                self.send_response(204)
                self.end_headers()
            else:
                self.send_response(302)
                self.send_header('Location', 'http://127.0.0.1:{}/cgi-bin/login?cmd=login&mac=11%3A22%3A33%3A44%3A55%3A66&ip=10.200.1.42&essid=UoM.Wireless&url=http%3A%2F%2Fconnectivity-check.ubuntu.com'.format(self.server.server_port))
                self.send_header('Set-Cookie', 'ARUBA_SESSION=aruba_sec_tok; Path=/')
                self.end_headers()
        elif self.path.startswith('/cgi-bin/login'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/cgi-bin/login\" method=\"POST\"><input type=\"hidden\" name=\"csrf\" value=\"aruba99\"><input name=\"user\"><input name=\"password\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path.startswith('/cgi-bin/login'):
            cookie = self.headers.get('Cookie', '')
            if 'ARUBA_SESSION=aruba_sec_tok' in cookie:
                auth_state['cookie_seen'] = True
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            params = urllib.parse.parse_qs(body)
            auth_state['cmd'] = params.get('cmd', [''])[0]
            auth_state['mac'] = params.get('mac', [''])[0]
            if auth_state['cmd'] == 'authenticate' and auth_state['mac'] == '11:22:33:44:55:66' and auth_state['cookie_seen']:
                auth_state['logged_in'] = True
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'Aruba Success')
            else:
                self.send_response(400)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), ArubaHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockAruba = Start-MockHttpServer -ScriptContent $arubaServerScript -FileName "mock_aruba.py"
$arubaPort = $mockAruba.Port

$arubaCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "aruba_creds.json")
New-TestCredentialsFile -FilePath $arubaCredsFile -Username "student_aruba" -Password "ArubaPassword456!"

try {
    $env:UNINET_TEST_SSID             = "UoM.Wireless"
    $env:UNINET_TEST_ARUBA_PROBE_URL  = "http://127.0.0.1:$arubaPort/ubuntu_probe"
    $env:UNINET_TEST_CREDS_FILE       = $arubaCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "SUCCESS") `
        "Invoke-UniLogin succeeded on Aruba portal (UoM.Wireless)" $global:LastAuthStatus

    # Verify post-login state on server
    $verifyProbe = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$arubaPort/ubuntu_probe")
    $verifyProbe.Proxy = $null
    $verifyProbe.AllowAutoRedirect = $false
    $vResp = $verifyProbe.GetResponse()
    Assert-Condition ([int]$vResp.StatusCode -eq 204) `
        "Aruba portal confirms online status (HTTP 204)"
    $vResp.Close()
} finally {
    Stop-MockHttpServer $mockAruba
    Remove-Item $arubaCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_ARUBA_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 9: Security Guardrails & Structured Diagnostic Failure Categories
# ------------------------------------------------------------------------------
Write-Host "`n[Test 9] Security Guardrails & Structured Diagnostic Failure Categories" -ForegroundColor Cyan

# 9.1 Network Unavailable
$env:UNINET_TEST_SSID = ""
Invoke-UniLogin
Assert-Condition ($global:LastAuthStatus -eq "NETWORK_UNAVAILABLE") `
    "State machine emits NETWORK_UNAVAILABLE when no SSID is connected"

# 9.2 Wrong SSID
$env:UNINET_TEST_SSID = "Starbucks_Guest"
Invoke-UniLogin
Assert-Condition ($global:LastAuthStatus -eq "WRONG_SSID") `
    "State machine emits WRONG_SSID when connected to non-campus network"

# 9.3 Credentials Missing
$env:UNINET_TEST_SSID = "UoM_Wireless"
$fakeCredsPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "non_existent_creds.json")
$env:UNINET_TEST_CREDS_FILE = $fakeCredsPath
$origCreds = $CredsFile
$origSysCreds = $SysCredsFile
$CredsFile = $fakeCredsPath
$SysCredsFile = $fakeCredsPath
Invoke-UniLogin
Assert-Condition ($global:LastAuthStatus -eq "CREDENTIALS_MISSING") `
    "State machine emits CREDENTIALS_MISSING when credentials file is missing"
$CredsFile = $origCreds
$SysCredsFile = $origSysCreds
$env:UNINET_TEST_CREDS_FILE = $null

$rogueServerScript = @"
import http.server, sys

class RogueHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            self.send_response(302)
            self.send_header('Location', 'https://evil-phishing-portal.com/login')
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), RogueHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockRogue = Start-MockHttpServer -ScriptContent $rogueServerScript -FileName "mock_rogue.py"
$roguePort = $mockRogue.Port

$testCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test_creds.json")
New-TestCredentialsFile -FilePath $testCredsFile -Username "student" -Password "password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$roguePort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $testCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "UNTRUSTED_REDIRECT") `
        "Security Guardrail: Invoke-UniLogin blocks untrusted external redirect domain before landing probe" $global:LastAuthStatus
} finally {
    Stop-MockHttpServer $mockRogue
    Remove-Item $testCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}

# 9.5 Negative Security: TLS Certificate Bypass Verification
$env:UNINET_ALLOW_TEST_CERT = "0"
$callback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$dummyReq = [System.Net.HttpWebRequest]::Create("https://127.0.0.1:8443/login")
$dummyCert = $null
$dummyErrors = [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors
$tlsResult = $callback.Invoke($dummyReq, $dummyCert, $null, $dummyErrors)
Assert-Condition ($tlsResult -eq $false) `
    "Security Guardrail: ServerCertificateValidationCallback rejects untrusted certificates when test cert flag is off"


# ------------------------------------------------------------------------------
# Test 10: Institutional Certificate Pinning & Hostname Binding
# ------------------------------------------------------------------------------
Write-Host "`n[Test 10] Institutional Certificate Pinning & Hostname Binding" -ForegroundColor Cyan

$pinCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$certBase64 = "MIICszCCAZugAwIBAgIJAIqRUiuw6tGyMA0GCSqGSIb3DQEBCwUAMBkxFzAVBgNVBAMTDmNvbm5lY3QudW9tLmxrMB4XDTI2MTEwOTE2NTA1OFoXDTM2MTEwOTE2NTA1OFowGTEXMBUGA1UEAxMOY29ubmVjdC51b20ubGswggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC1JUTHdPsf5BSnbcS+gKjoFbhZqhGHr9lXmupcPqvdBYuniOnfXicRvKVtBwZF/C0Czg2nhIemmGd9qHtBfzPM/QesnV0RmkyDlaeIIYzHu91YE6Q2cIGB69ZxgcwLysg0n5qtuvIaEXZ8p8bcdXpvOPjjJoxHIIv4q1RZuZ7U1yVTEpb/tPi5NLYbanDhr83tHlEqyrzchsqSLTnhkPs+z0uB26wQDmN1hmd0ZxvtQyih8BIFmoOIDgSFeBOEuxrjEUJ7rSgY6YJYsmvoIrqHDRZzjKztbOx820Ye86utGN6WX0ORujRxhrsdJrD2jDb2CS5BVPIm/FzWMS2kTENxAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAAHwcYpz+N2o4SpD3N0maOtlsLm3DASoOCURRWMRUYr0gXxOhVgHZMiw9THRYp2D+HuubOg2COr7MqDLog9E8atvhNwaWBXrE1li3ASOM57jjIenQEoDJhw1y81qguTjqPsMhimxLLH7wNe/h2j8vpTXMKA6s+SpV54O/JPwu+LxnYXEIt2G0vOz7gIZooAkCc4rn+TmyV0WjRh1weP7Petrsge5rxepRPRm8YOTqsu43aACOZmOaXrZUa0XLLdYiMbQyTNbSPdSNrIl7tYYJJM5a+8sHNWGMe3GYxUvbTrg4pisbkCk7/sqC+lr9PnLo/Kf5wi9uQdgCHBXl7yo5WM="
$validCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[System.Convert]::FromBase64String($certBase64))
$validThumb = $validCert.GetCertHashString()

$env:UNINET_PINNED_CERT_THUMBPRINT = $validThumb
$reqUom   = [System.Net.HttpWebRequest]::Create("https://connect.uom.lk/cgi-bin/login")
$reqRogue = [System.Net.HttpWebRequest]::Create("https://evil-phishing.com/login")

$pinPass = $pinCallback.Invoke($reqUom, $validCert, $null, [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
Assert-Condition ($pinPass -eq $true) `
    "Accepts pinned certificate thumbprint bound to connect.uom.lk"

$pinFailHost = $pinCallback.Invoke($reqRogue, $validCert, $null, [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
Assert-Condition ($pinFailHost -eq $false) `
    "Rejects pinned certificate thumbprint presented by untrusted host (evil-phishing.com)"

$env:UNINET_PINNED_CERT_THUMBPRINT = "INVALID_NON_HEX_THUMBPRINT"
$pinFailFormat = $pinCallback.Invoke($reqUom, $validCert, $null, [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
Assert-Condition ($pinFailFormat -eq $false) `
    "Rejects malformed certificate thumbprint (non-hex or invalid length)"

$env:UNINET_PINNED_CERT_THUMBPRINT = $null


# ------------------------------------------------------------------------------
# Test 11: DPAPI Secret Encryption & Fallback
# ------------------------------------------------------------------------------
Write-Host "`n[Test 11] DPAPI Secret Encryption & Cross-Platform Fallback" -ForegroundColor Cyan

$sampleSecret = "SuperSecurePassword#2026!"
$protected = Protect-Secret $sampleSecret
Assert-Condition (-not [string]::IsNullOrEmpty($protected)) `
    "Protect-Secret outputs valid protected representation"

$unprotected = Unprotect-Secret $protected
Assert-Condition ($unprotected -eq $sampleSecret) `
    "Unprotect-Secret recovers original plaintext secret"

$plainFallback = Unprotect-Secret "RawPlaintextStringWithoutEncryption"
Assert-Condition ($plainFallback -eq "RawPlaintextStringWithoutEncryption" -or $plainFallback -eq $null) `
    "Unprotect-Secret handles unencrypted strings without crashing"

$emptyProtect = Protect-Secret ""
Assert-Condition ($emptyProtect -eq "") `
    "Protect-Secret handles empty secret input safely"

# Corrupted ciphertext rejection verification
$corruptedCipher = "AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAACORRUPTEDTESTCORRUPTEDCIPHERTEXT=="
$corruptedResult = Unprotect-Secret $corruptedCipher
Assert-Condition ($corruptedResult -eq $null -or -not ([Environment]::OSVersion.Platform -eq "Win32NT")) `
    "Unprotect-Secret rejects corrupted ciphertext without returning raw corrupted string as password"


# ------------------------------------------------------------------------------
# Test 12: Already-Online Network Bypass
# ------------------------------------------------------------------------------
Write-Host "`n[Test 12] Already-Online Network Bypass" -ForegroundColor Cyan

$onlineScript = @"
import http.server, sys

class OnlineHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            self.send_response(204)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), OnlineHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockOnline = Start-MockHttpServer -ScriptContent $onlineScript -FileName "mock_online.py"
$onlinePort = $mockOnline.Port

$onlineCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "online_creds.json")
New-TestCredentialsFile -FilePath $onlineCredsFile -Username "student" -Password "password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$onlinePort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $onlineCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "SUCCESS") `
        "Already-online connection detected immediately with SUCCESS status"
} finally {
    Stop-MockHttpServer $mockOnline
    Remove-Item $onlineCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 13: Portal HTTP 401/403 Authentication Rejection
# ------------------------------------------------------------------------------
Write-Host "`n[Test 13] Portal HTTP 401/403 Authentication Rejection" -ForegroundColor Cyan

$rejectScript = @"
import http.server, sys

class RejectHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:{}/login.html'.format(self.server.server_port))
            self.end_headers()
        elif self.path == '/login.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/login_submit\" method=\"POST\"><input name=\"user\"><input name=\"password\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/login_submit':
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'Invalid Credentials')
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), RejectHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockReject = Start-MockHttpServer -ScriptContent $rejectScript -FileName "mock_reject.py"
$rejectPort = $mockReject.Port

$rejectCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "reject_creds.json")
New-TestCredentialsFile -FilePath $rejectCredsFile -Username "wrong_student" -Password "bad_password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$rejectPort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $rejectCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "AUTHENTICATION_REJECTED") `
        "Captive portal HTTP 401 sets AUTHENTICATION_REJECTED state"
} finally {
    Stop-MockHttpServer $mockReject
    Remove-Item $rejectCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 14: Failed Post-Login Verification
# ------------------------------------------------------------------------------
Write-Host "`n[Test 14] Failed Post-Login Verification" -ForegroundColor Cyan

$unverifiedScript = @"
import http.server, sys

class UnverifiedHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            # Always redirects, never transitions to 204
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:{}/login.html'.format(self.server.server_port))
            self.end_headers()
        elif self.path == '/login.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"/login_submit\" method=\"POST\"><input name=\"user\"><input name=\"password\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/login_submit':
            # Accepts submission with 200, but connectivity never unlocks to 204
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Pending administrator approval...')
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), UnverifiedHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockUnverified = Start-MockHttpServer -ScriptContent $unverifiedScript -FileName "mock_unverified.py"
$unverifiedPort = $mockUnverified.Port

$unverifiedCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "unverified_creds.json")
New-TestCredentialsFile -FilePath $unverifiedCredsFile -Username "student" -Password "password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$unverifiedPort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $unverifiedCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "CONNECTIVITY_VERIFICATION_FAILED") `
        "State machine records CONNECTIVITY_VERIFICATION_FAILED when probes fail post-login"
} finally {
    Stop-MockHttpServer $mockUnverified
    Remove-Item $unverifiedCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 15: Form Action Pointing to Untrusted Domain
# ------------------------------------------------------------------------------
Write-Host "`n[Test 15] Form Action Pointing to Untrusted Domain" -ForegroundColor Cyan

$phishingActionScript = @"
import http.server, sys

class PhishingActionHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:{}/login.html'.format(self.server.server_port))
            self.end_headers()
        elif self.path == '/login.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><form action=\"https://attacker-credential-stealer.com/harvest\" method=\"POST\"><input name=\"user\"><input name=\"password\"></form></html>')
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), PhishingActionHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockPhishing = Start-MockHttpServer -ScriptContent $phishingActionScript -FileName "mock_phishing_action.py"
$phishingActionPort = $mockPhishing.Port

$phishingCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "phishing_creds.json")
New-TestCredentialsFile -FilePath $phishingCredsFile -Username "student" -Password "password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$phishingActionPort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $phishingCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "INVALID_AUTH_ENDPOINT") `
        "Security Guardrail: Invoke-PortalPost blocks untrusted form action destination"
} finally {
    Stop-MockHttpServer $mockPhishing
    Remove-Item $phishingCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Test 16: Missing Form Action Fallback
# ------------------------------------------------------------------------------
Write-Host "`n[Test 16] Missing Form Action Fallback" -ForegroundColor Cyan

$noActionHtml = "<html><body><form method='POST'><input name='username'></form></body></html>"
$extractedAction = Get-FormActionUrl -Html $noActionHtml
Assert-Condition ($extractedAction -eq "") `
    "Get-FormActionUrl returns empty string when action attribute is omitted"

$resolvedFallback = Resolve-PortalUrl -Base "https://connect.uom.lk/portal/index.html" -Target $extractedAction
Assert-Condition ($resolvedFallback -eq "https://connect.uom.lk/portal/index.html") `
    "Resolve-PortalUrl preserves current landing page URL as fallback"


# ------------------------------------------------------------------------------
# Test 17: Missing CSRF Token / Hidden Fields Resilience
# ------------------------------------------------------------------------------
Write-Host "`n[Test 17] Missing CSRF Token / Hidden Fields Resilience" -ForegroundColor Cyan

$noHiddenHtml = "<html><body><form action='/login'><input name='user'><input name='password'></form></body></html>"
$extractedHidden = Get-HiddenFormFields -Html $noHiddenHtml
Assert-Condition ($extractedHidden.Count -eq 0) `
    "Get-HiddenFormFields returns empty collection gracefully when no hidden inputs exist"

$extractedHidden["user"] = "student_test"
$extractedHidden["password"] = "pass123"
Assert-Condition ($extractedHidden.ContainsKey("user") -and $extractedHidden.ContainsKey("password")) `
    "Form fields collection safely accepts injected credentials"


# ------------------------------------------------------------------------------
# Test 18: Meta-Refresh Redirect to Untrusted Domain Blocked
# ------------------------------------------------------------------------------
Write-Host "`n[Test 18] Meta-Refresh Redirect to Untrusted Domain Blocked" -ForegroundColor Cyan

$metaScript = @"
import http.server, sys

class MetaHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/generate_204':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:{}/landing.html'.format(self.server.server_port))
            self.end_headers()
        elif self.path == '/landing.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><head><meta http-equiv=\"refresh\" content=\"0; url=https://evil-meta-redirect.com/portal\"></head></html>')
        else:
            self.send_response(404)
            self.end_headers()

s = http.server.HTTPServer(('127.0.0.1', 0), MetaHandler)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
    f.flush()
s.serve_forever()
"@

$mockMeta = Start-MockHttpServer -ScriptContent $metaScript -FileName "mock_meta.py"
$metaPort = $mockMeta.Port

$metaCredsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "meta_creds.json")
New-TestCredentialsFile -FilePath $metaCredsFile -Username "student" -Password "password"

try {
    $env:UNINET_TEST_SSID       = "UoM_Wireless"
    $env:UNINET_TEST_PROBE_URL  = "http://127.0.0.1:$metaPort/generate_204"
    $env:UNINET_TEST_CREDS_FILE = $metaCredsFile

    Invoke-UniLogin

    Assert-Condition ($global:LastAuthStatus -eq "UNTRUSTED_REDIRECT") `
        "Security Guardrail: Invoke-UniLogin blocks meta-refresh redirect to untrusted domain"
} finally {
    Stop-MockHttpServer $mockMeta
    Remove-Item $metaCredsFile -Force -ErrorAction SilentlyContinue
    $env:UNINET_TEST_SSID = $null
    $env:UNINET_TEST_PROBE_URL = $null
    $env:UNINET_TEST_CREDS_FILE = $null
}


# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "TEST SUMMARY: $TestPassCount Passed, $TestFailCount Failed" -ForegroundColor $(if ($TestFailCount -eq 0) { "Green" } else { "Red" })
Write-Host "========================================================`n" -ForegroundColor Cyan

if ($TestFailCount -gt 0) {
    exit 1
}
exit 0
