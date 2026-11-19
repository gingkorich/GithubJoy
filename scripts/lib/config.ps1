# GitHub Joy - config helpers (ASCII only, PowerShell 5.1)
Set-StrictMode -Off

function Get-JoyRoot {
  return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Read-JoyJsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $raw = $raw -replace '^\uFEFF', ''
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Write-JoyJsonFile([string]$Path, $Object) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $json = $Object | ConvertTo-Json -Depth 12
  $tmp = "$Path.tmp"
  $enc = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($tmp, $json, $enc)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-JoyConfig {
  $root = Get-JoyRoot
  $base = Read-JoyJsonFile (Join-Path $root 'config.sample.json')
  if ($null -eq $base) { $base = [pscustomobject]@{} }
  $over = Read-JoyJsonFile (Join-Path $root 'config.json')
  if ($null -eq $over) { return $base }
  foreach ($p in $over.PSObject.Properties) {
    $base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
  }
  return $base
}

function Get-JoyGhConfig {
  $cfg = Read-JoyJsonFile (Join-Path (Get-JoyRoot) 'gh.json')
  if ($null -eq $cfg) { return [pscustomobject]@{} }
  return $cfg
}

function Get-JoyListNames {
  $gh = Get-JoyGhConfig
  $u = 'unread'; $r = 'read'
  if ($gh.PSObject.Properties.Name -contains 'unread_list' -and $gh.unread_list) { $u = [string]$gh.unread_list }
  if ($gh.PSObject.Properties.Name -contains 'read_list' -and $gh.read_list) { $r = [string]$gh.read_list }
  return @{ unread = $u; read = $r }
}

function Normalize-JoyProxy([string]$Value) {
  if (-not $Value) { return $null }
  $s = $Value.Trim()
  if (-not $s) { return $null }
  if ($s -match '^(https?|socks4|socks5|socks5h)://') { return $s }
  if ($s -match '=') {
    $pairs = @{}
    foreach ($kv in ($s -split ';')) {
      if (-not $kv) { continue }
      $i = $kv.IndexOf('=')
      if ($i -gt 0) { $pairs[$kv.Substring(0, $i).Trim().ToLower()] = $kv.Substring($i + 1).Trim() }
    }
    if ($pairs.ContainsKey('https')) { return Normalize-JoyProxy $pairs['https'] }
    if ($pairs.ContainsKey('http')) { return Normalize-JoyProxy $pairs['http'] }
    return $null
  }
  return "http://$s"
}

function Get-SystemProxy {
  try {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $item = Get-ItemProperty -Path $key -ErrorAction Stop
    if ([int]$item.ProxyEnable -eq 1 -and $item.ProxyServer) {
      return Normalize-JoyProxy ([string]$item.ProxyServer)
    }
  } catch { }
  return $null
}

function Get-JoyProxy {
  $cfg = Get-JoyConfig
  $net = $null
  if ($cfg -and $cfg.PSObject.Properties.Name -contains 'network') { $net = $cfg.network }
  $configured = $null
  if ($net -and $net.PSObject.Properties.Name -contains 'proxy') { $configured = Normalize-JoyProxy ([string]$net.proxy) }
  if ($configured) { return $configured }
  $auto = $true
  if ($net -and $net.PSObject.Properties.Name -contains 'autoDetect') { $auto = [bool]$net.autoDetect }
  if ($auto) { return (Get-SystemProxy) }
  return $null
}

function Use-JoyProxy([string]$Proxy) {
  if (-not $Proxy) { return }
  $env:HTTPS_PROXY = $Proxy
  $env:HTTP_PROXY = $Proxy
  $env:ALL_PROXY = $Proxy
  $env:NO_PROXY = 'localhost,127.0.0.1'
  $env:no_proxy = $env:NO_PROXY
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}