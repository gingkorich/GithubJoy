# GitHub Joy - HTTP helpers with retry (ASCII only)
Set-StrictMode -Off

$script:JoyUA = 'GithubJoy/0.2-m2 (+https://github.com/)'

function New-JoyProxyObject([string]$Proxy) {
  if (-not $Proxy) { return $null }
  return (New-Object Net.WebProxy($Proxy))
}

function Read-JoyResponseBody($Response) {
  try {
    $stream = $Response.GetResponseStream()
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return $text
  } catch { return '' }
}

function Invoke-JoyHttp {
  param(
    [string]$Method = 'GET',
    [string]$Uri,
    [hashtable]$Headers = @{},
    [string]$Body = $null,
    [string]$Proxy = $null,
    [int]$TimeoutSec = 25,
    [int]$MaxAttempts = 3
  )

  $attempt = 0
  $last = $null
  while ($attempt -lt $MaxAttempts) {
    $attempt++
    try {
      $p = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSec
        UserAgent = $script:JoyUA
      }
      if ($Body) {
        $p['Body'] = [Text.Encoding]::UTF8.GetBytes([string]$Body)
        $p['ContentType'] = 'application/json; charset=utf-8'
      }
      if ($Proxy) { $p['Proxy'] = $Proxy }
      $resp = Invoke-WebRequest @p
      $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return @{ ok = $true; status = [int]$resp.StatusCode; body = $text; headers = $resp.Headers; error = $null }
    } catch {
      $status = 0
      $text = ''
      $msg = $_.Exception.Message
      try {
        if ($_.Exception.Response) {
          $status = [int]$_.Exception.Response.StatusCode
          $text = Read-JoyResponseBody $_.Exception.Response
        }
      } catch { }
      $last = @{ ok = $false; status = $status; body = $text; headers = @{}; error = $msg }

      $retryable = ($status -in @(0, 429, 500, 502, 503, 504))
      if ($status -eq 403 -and $text -match '(?i)(secondary rate limit|abuse)') { $retryable = $true }
      if (-not $retryable -or $attempt -ge $MaxAttempts) { break }

      $wait = [Math]::Pow(2, $attempt)
      if ($status -eq 429 -and $_.Exception.Response) {
        try {
          $ra = $_.Exception.Response.Headers['Retry-After']
          if ($ra) { $wait = [int]$ra }
        } catch { }
      }
      Write-JoyLog "HTTP $status on $Method $Uri, retry in $wait s (attempt $attempt/$MaxAttempts)" 'WARN'
      Start-Sleep -Seconds ([Math]::Min($wait, 60))
    }
  }
  return $last
}

function Invoke-JoyEmptyPut {
  param(
    [string]$Uri,
    [hashtable]$Headers = @{},
    [string]$Proxy = $null,
    [int]$TimeoutSec = 25
  )
  try {
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'PUT'
    $req.UserAgent = $script:JoyUA
    $req.ContentLength = 0
    $req.Timeout = $TimeoutSec * 1000
    foreach ($k in $Headers.Keys) {
      $v = [string]$Headers[$k]
      switch ($k.ToLowerInvariant()) {
        'accept' { $req.Accept = $v }
        'user-agent' { $req.UserAgent = $v }
        'content-type' { $req.ContentType = $v }
        'referer' { $req.Referer = $v }
        'host' { $req.Host = $v }
        default { $req.Headers[$k] = $v }
      }
    }
    $px = New-JoyProxyObject $Proxy
    if ($px) { $req.Proxy = $px }
    $resp = $req.GetResponse()
    $status = [int]$resp.StatusCode
    $resp.Close()
    return @{ ok = $true; status = $status; error = $null }
  } catch [Net.WebException] {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    return @{ ok = $false; status = $status; error = $_.Exception.Message }
  } catch {
    return @{ ok = $false; status = 0; error = $_.Exception.Message }
  }
}