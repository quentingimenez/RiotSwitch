param(
    [int]$Attempts = 20,
    [int]$IntervalMs = 500
)

$ErrorActionPreference = 'Stop'

function Invoke-RiotShowOnce {
    param([string]$LockfilePath)
    if (-not (Test-Path -LiteralPath $LockfilePath)) { return 'no_lockfile' }
    $text = [System.IO.File]::ReadAllText($LockfilePath)
    $parts = $text.Trim().Split(':')
    if ($parts.Length -lt 5) { return 'bad_lockfile' }
    $port = 0
    if (-not [int]::TryParse($parts[2], [ref]$port) -or $port -le 0 -or $port -gt 65535) { return 'bad_port' }
    $protocol = $parts[4].Trim().ToLowerInvariant()
    if ($protocol -ne 'https' -and $protocol -ne 'http') { return 'bad_protocol' }
    $password = ($parts[3..($parts.Length - 2)] -join ':')
    if ([string]::IsNullOrEmpty($password)) { return 'no_password' }

    $url = $protocol + '://127.0.0.1:' + $port + '/riot-client-lifecycle/v1/show'
    $credentials = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('riot:' + $password))
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'POST'
        $req.ContentLength = 0
        $req.Proxy = $null
        $req.Timeout = 2000
        $req.ReadWriteTimeout = 2000
        $req.Headers.Add('Authorization', 'Basic ' + $credentials)
        try {
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return ('http_' + $code)
        }
        catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
                $_.Exception.Response.Close()
                return ('http_' + $code)
            }
            return ('webex_' + $_.Exception.Status)
        }
    }
    catch {
        return ('ex_' + $_.Exception.GetType().Name)
    }
}

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]'Tls12, Tls11, Tls'
} catch { }

$lock = Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile'
$last = $null
$attempt = 0
for ($i = 0; $i -lt $Attempts; $i++) {
    $attempt = $i + 1
    $last = Invoke-RiotShowOnce -LockfilePath $lock
    if ($last -eq 'http_200' -or $last -eq 'http_204' -or $last -eq 'http_201') { break }
    Start-Sleep -Milliseconds $IntervalMs
}

$ok = ($last -eq 'http_200' -or $last -eq 'http_204' -or $last -eq 'http_201')
[ordered]@{
    ok       = $ok
    attempts = $attempt
    last     = $last
    lockfile = $lock
} | ConvertTo-Json -Compress
