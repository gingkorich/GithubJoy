# GitHub Joy - lists status probe (ASCII only)
# Outputs a single JSON line: {"ok":true,"login":"x","unread":{"name","count"},"read":{"name","count"}}
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }

. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\http.ps1')
. (Join-Path $PSScriptRoot 'lib\github.ps1')

$result = [ordered]@{
  ok = $false; login = $null
  unread = $null; read = $null
  at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  error = $null
}

try {
  $proxy = Get-JoyProxy
  Use-JoyProxy $proxy
  $tok = Get-JoyTokenInfo -Proxy $proxy
  if (-not $tok.value) {
    $result.error = 'no_token'
  } else {
    $login = Get-JoyViewer -Token $tok.value -Proxy $proxy
    $result.login = $login
    $lists = Get-JoyLists -Token $tok.value -Proxy $proxy
    if (-not $lists.ok) {
      $result.error = 'lists_failed: ' + [string]$lists.error
    } else {
      $names = Get-JoyListNames
      $u = $lists.lists | Where-Object { ([string]$_.name).ToLowerInvariant() -eq ([string]$names.unread).ToLowerInvariant() } | Select-Object -First 1
      $r = $lists.lists | Where-Object { ([string]$_.name).ToLowerInvariant() -eq ([string]$names.read).ToLowerInvariant() } | Select-Object -First 1
      if ($u) { $result.unread = [ordered]@{ name = [string]$u.name; count = [int]$u.itemCount } }
      if ($r) { $result.read = [ordered]@{ name = [string]$r.name; count = [int]$r.itemCount } }
      $result.ok = ($null -ne $u -and $null -ne $r)
      if (-not $result.ok -and -not $result.error) { $result.error = 'list_not_found' }
    }
  }
} catch {
  $result.ok = $false
  $result.error = [string]$_.Exception.Message
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5 -Compress))
exit 0