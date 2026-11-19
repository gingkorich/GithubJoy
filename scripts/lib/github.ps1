# GitHub Joy - GitHub API helpers (ASCII only)
Set-StrictMode -Off

function Get-JoyTokenInfo {
  param([string]$Proxy)

  Use-JoyProxy $Proxy
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($null -ne $gh) {
    $t = & gh auth token --hostname github.com 2>$null
    if ($LASTEXITCODE -eq 0 -and $t) {
      return @{ value = ([string]$t).Trim(); source = 'gh' }
    }
  }
  $ghcfg = Get-JoyGhConfig
  if ($ghcfg.PSObject.Properties.Name -contains 'token' -and $ghcfg.token) {
    return @{ value = [string]$ghcfg.token; source = 'gh.json' }
  }
  return @{ value = $null; source = 'none' }
}

function New-JoyApiHeaders([string]$Token) {
  return @{
    'Authorization' = "bearer $Token"
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
}

function Invoke-JoyGraphQL {
  param(
    [string]$Token,
    [string]$Query,
    [hashtable]$Variables = @{},
    [string]$Proxy = $null
  )
  $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Compress -Depth 8
  $r = Invoke-JoyHttp -Method 'POST' -Uri 'https://api.github.com/graphql' `
    -Headers (New-JoyApiHeaders $Token) -Body $body -Proxy $Proxy -TimeoutSec 30
  if (-not $r.ok) { return @{ ok = $false; status = $r.status; error = $r.error; body = $r.body; data = $null } }
  $obj = $null
  try { $obj = $r.body | ConvertFrom-Json } catch { return @{ ok = $false; status = $r.status; error = 'graphql_json_parse_failed'; body = $r.body; data = $null } }
  if ($obj.PSObject.Properties.Name -contains 'errors' -and $obj.errors) {
    $msgs = @()
    foreach ($e in @($obj.errors)) { $msgs += ("" + $e.type + ': ' + $e.message) }
    return @{ ok = $false; status = $r.status; error = ($msgs -join ' | '); body = $r.body; data = $obj.data }
  }
  return @{ ok = $true; status = $r.status; error = $null; body = $r.body; data = $obj.data }
}

function Get-JoyViewer {
  param([string]$Token, [string]$Proxy)
  $q = 'query { viewer { login } }'
  $r = Invoke-JoyGraphQL -Token $Token -Query $q -Proxy $Proxy
  if (-not $r.ok) { return $null }
  return [string]$r.data.viewer.login
}

function Get-JoyLists {
  param([string]$Token, [string]$Proxy)
  $q = @'
query {
  viewer {
    lists(first: 50) {
      nodes { id name isPrivate items(first: 1) { totalCount } }
    }
  }
}
'@
  $r = Invoke-JoyGraphQL -Token $Token -Query $q -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; lists = @(); error = $r.error } }
  $out = @()
  foreach ($n in @($r.data.viewer.lists.nodes)) {
    if ($null -eq $n) { continue }
    $out += [pscustomobject]@{
      id = [string]$n.id
      name = [string]$n.name
      isPrivate = [bool]$n.isPrivate
      itemCount = [int]$n.items.totalCount
    }
  }
  return @{ ok = $true; lists = $out; error = $null }
}

function Get-JoyListItems {
  param([string]$Token, [string]$ListId, [string]$Proxy, [int]$PageSize = 100)
  $q = @'
query($id: ID!, $cursor: String, $n: Int!) {
  node(id: $id) {
    ... on UserList {
      items(first: $n, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { ... on Repository { nameWithOwner } }
      }
    }
  }
}
'@
  $names = New-Object System.Collections.Generic.List[string]
  $cursor = $null
  for ($i = 0; $i -lt 30; $i++) {
    $vars = @{ id = $ListId; cursor = $cursor; n = $PageSize }
    $r = Invoke-JoyGraphQL -Token $Token -Query $q -Variables $vars -Proxy $Proxy
    if (-not $r.ok) { return @{ ok = $false; names = @(); error = $r.error } }
    $conn = $r.data.node.items
    foreach ($n in @($conn.nodes)) {
      if ($null -ne $n -and $n.nameWithOwner) { $names.Add([string]$n.nameWithOwner) }
    }
    if (-not $conn.pageInfo.hasNextPage) { break }
    $cursor = [string]$conn.pageInfo.endCursor
  }
  return @{ ok = $true; names = $names.ToArray(); error = $null }
}

function New-JoyList {
  param([string]$Token, [string]$Name, [string]$Description, [string]$Proxy)
  $q = @'
mutation($name: String!, $desc: String) {
  createUserList(input: { name: $name, description: $desc, isPrivate: false }) {
    list { id name }
  }
}
'@
  $r = Invoke-JoyGraphQL -Token $Token -Query $q -Variables @{ name = $Name; desc = $Description } -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; id = $null; error = $r.error } }
  return @{ ok = $true; id = [string]$r.data.createUserList.list.id; error = $null }
}

function Set-JoyItemLists {
  param([string]$Token, [string]$NodeId, [string[]]$ListIds, [string]$Proxy)
  $q = @'
mutation($item: ID!, $lists: [ID!]!) {
  updateUserListsForItem(input: { itemId: $item, listIds: $lists }) {
    lists { id name }
  }
}
'@
  $r = Invoke-JoyGraphQL -Token $Token -Query $q -Variables @{ item = $NodeId; lists = $ListIds } -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
  return @{ ok = $true; error = $null }
}

function Add-JoyStar {
  param([string]$Token, [string]$FullName, [string]$Proxy)
  $uri = 'https://api.github.com/user/starred/' + ($FullName -replace '/', '/')
  $r = Invoke-JoyEmptyPut -Uri $uri -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if ($r.ok) { return @{ ok = $true; status = $r.status; error = $null } }
  if ($r.status -in @(302, 304)) { return @{ ok = $true; status = $r.status; error = $null } }
  return $r
}

function Get-JoyStarredMap {
  param([string]$Token, [string[]]$FullNames, [string]$Proxy)

  $map = @{}
  $errors = 0
  $list = @($FullNames | Where-Object { $_ } | Sort-Object -Unique)
  for ($i = 0; $i -lt $list.Count; $i += 25) {
    $end = [Math]::Min($i + 24, $list.Count - 1)
    $chunk = @($list[$i..$end])
    $parts = @()
    $n = 0
    foreach ($full in $chunk) {
      $sp = ([string]$full) -split '/', 2
      if ($sp.Count -lt 2) { $n++; continue }
      $owner = $sp[0] -replace '"', ''
      $name = $sp[1] -replace '"', ''
      $parts += ('r' + $n + ': repository(owner: "' + $owner + '", name: "' + $name + '") { nameWithOwner viewerHasStarred }')
      $n++
    }
    if ($parts.Count -eq 0) { continue }
    $q = 'query { ' + ($parts -join ' ') + ' }'
    $r = Invoke-JoyGraphQL -Token $Token -Query $q -Proxy $Proxy
    if (-not $r.ok) {
      $errors += $chunk.Count
      Write-JoyLog ("star filter batch failed: " + [string]$r.error) 'WARN'
      continue
    }
    for ($j = 0; $j -lt $n; $j++) {
      $node = $r.data.('r' + $j)
      if ($null -eq $node) { continue }
      if ([bool]$node.viewerHasStarred) { $map[[string]$node.nameWithOwner] = $true }
    }
  }
  return @{ ok = ($errors -eq 0); map = $map; errors = $errors }
}

function Get-JoyRepoNodeId {
  param([string]$Token, [string]$FullName, [string]$Proxy)
  $r = Invoke-JoyHttp -Uri ("https://api.github.com/repos/" + $FullName) -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return $null }
  try { return [string](($r.body | ConvertFrom-Json).node_id) } catch { return $null }
}