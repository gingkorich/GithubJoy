# M1 probe: verify gh token can read Star Lists (R2).
# ASCII-only on purpose (PowerShell 5.1). Output: single-line JSON to stdout.
param(
  [string]$Proxy = ''
)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$root = Split-Path -Parent $PSScriptRoot

function Fail($msg, $detail) {
  $o = [ordered]@{ ok = $false; error = [string]$msg; detail = [string]$detail }
  $o | ConvertTo-Json -Depth 6 -Compress
  exit 1
}

function Get-TokenInfo {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($null -ne $gh) {
    $t = & gh auth token --hostname github.com 2>$null
    if ($LASTEXITCODE -eq 0 -and $t) {
      return @{ value = ([string]$t).Trim(); source = 'gh' }
    }
  }
  $cfg = Join-Path $root 'gh.json'
  if (Test-Path -LiteralPath $cfg) {
    try {
      $raw = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
      $obj = $raw | ConvertFrom-Json
      if ($obj.token) { return @{ value = [string]$obj.token; source = 'gh.json' } }
    } catch { }
  }
  return @{ value = $null; source = 'none' }
}

$tok = Get-TokenInfo
if (-not $tok.value) { Fail 'no_token' 'Run gh auth login or set gh.json.token' }

$query = 'query { viewer { login lists(first: 50) { totalCount nodes { id name isPrivate items(first: 1) { totalCount } } } } }'
$body = @{ query = $query } | ConvertTo-Json -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($body)

try {
  $reqParams = @{
    UseBasicParsing = $true
    Method = 'Post'
    Uri = 'https://api.github.com/graphql'
    Headers = @{ Authorization = "bearer $($tok.value)"; 'User-Agent' = 'GithubJoy/0.1-m1' }
    ContentType = 'application/json; charset=utf-8'
    Body = $bytes
    TimeoutSec = 25
  }
  if ($Proxy) { $reqParams['Proxy'] = $Proxy }
  $resp = Invoke-WebRequest @reqParams
  $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  $data = $text | ConvertFrom-Json
} catch {
  $code = 'n/a'
  $detail = $_.Exception.Message
  try {
    if ($_.Exception.Response) {
      $code = [int]$_.Exception.Response.StatusCode
      $rs = $_.Exception.Response.GetResponseStream()
      $rd = New-Object IO.StreamReader($rs, [Text.Encoding]::UTF8)
      $detail = $rd.ReadToEnd()
    }
  } catch { }
  Fail "http_error_$code" $detail
}

if ($data.errors) {
  $msgs = @($data.errors | ForEach-Object { "$($_.type): $($_.message)" }) -join ' | '
  Fail 'graphql_error' $msgs
}

$lists = @()
$total = 0
$login = $null
try {
  $login = $data.data.viewer.login
  $total = [int]$data.data.viewer.lists.totalCount
  foreach ($n in @($data.data.viewer.lists.nodes)) {
    if ($null -eq $n) { continue }
    $lists += [ordered]@{
      id = $n.id; name = $n.name; isPrivate = $n.isPrivate
      itemCount = [int]$n.items.totalCount
    }
  }
} catch {
  Fail 'shape_error' $_.Exception.Message
}

$names = @($lists | ForEach-Object { $_.name })
[ordered]@{
  ok = $true
  login = $login
  tokenSource = $tok.source
  listCount = $total
  lists = $lists
  hasUnread = ($names -contains 'unread')
  hasRead = ($names -contains 'read')
  note = 'Read probe only. A successful call proves the token can read viewer.lists; write scope is exercised in M2.'
} | ConvertTo-Json -Depth 8 -Compress