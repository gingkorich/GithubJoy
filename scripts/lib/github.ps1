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
query($cursor: String) {
  viewer {
    lists(first: 50, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { id name isPrivate items(first: 1) { totalCount } }
    }
  }
}
'@
  $out = @()
  $cursor = $null
  for ($page = 0; $page -lt 100; $page++) {
    $r = Invoke-JoyGraphQL -Token $Token -Query $q -Variables @{ cursor = $cursor } -Proxy $Proxy
    if (-not $r.ok) { return @{ ok = $false; lists = @(); error = $r.error } }
    $conn = $r.data.viewer.lists
    foreach ($n in @($conn.nodes)) {
      if ($null -eq $n) { continue }
      $out += [pscustomobject]@{
        id = [string]$n.id
        name = [string]$n.name
        isPrivate = [bool]$n.isPrivate
        itemCount = [int]$n.items.totalCount
      }
    }
    if (-not $conn.pageInfo.hasNextPage) { return @{ ok = $true; lists = $out; error = $null } }
    $next = [string]$conn.pageInfo.endCursor
    if (-not $next -or $next -eq $cursor) {
      return @{ ok = $false; lists = @(); error = 'lists_pagination_cursor_invalid' }
    }
    $cursor = $next
  }
  return @{ ok = $false; lists = @(); error = 'lists_pagination_limit_exceeded' }
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
  if ($conn.pageInfo.hasNextPage) {
    return @{ ok = $false; names = @(); error = 'list_items_pagination_limit_exceeded' }
  }
  return @{ ok = $true; names = $names.ToArray(); error = $null }
}

function Get-JoyListItemsDetailed {
  param([string]$Token, [string]$ListId, [string]$Proxy, [int]$Max = 300)

  $q = @'
query($id: ID!, $n: Int!, $cursor: String) {
  node(id: $id) {
    ... on UserList {
      items(first: $n, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on Repository {
            id nameWithOwner stargazerCount description pushedAt isArchived
            primaryLanguage { name }
          }
        }
      }
    }
  }
}
'@

  $out = @()
  $cursor = $null
  for ($i = 0; $i -lt 5; $i++) {
    $r = Invoke-JoyGraphQL -Token $Token -Query $q -Variables @{ id = $ListId; n = 100; cursor = $cursor } -Proxy $Proxy
    if (-not $r.ok) { return @{ ok = $false; items = @(); error = $r.error } }
    $conn = $r.data.node.items
    foreach ($n in @($conn.nodes)) {
      if ($null -eq $n) { continue }
      $lang = ''
      if ($n.primaryLanguage) { $lang = [string]$n.primaryLanguage.name }
      $out += [pscustomobject]@{
        id = [string]$n.id
        fullName = [string]$n.nameWithOwner
        stars = [int]$n.stargazerCount
        description = [string]$n.description
        language = $lang
        pushedAt = [string]$n.pushedAt
        archived = [bool]$n.isArchived
      }
    }
    if (-not $conn.pageInfo.hasNextPage -or $out.Count -ge $Max) { break }
    $cursor = [string]$conn.pageInfo.endCursor
  }
  return @{ ok = $true; items = @($out | Select-Object -First $Max); error = $null }
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
  $uri = 'https://api.github.com/user/starred/' + $FullName
  $r = Invoke-JoyEmptyPut -Uri $uri -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if ($r.ok) { return @{ ok = $true; status = $r.status; error = $null } }
  # 304 = already starred (idempotent no-op); 302 = redirect, treat as ok too
  if ($r.status -in @(302, 304)) { return @{ ok = $true; status = $r.status; error = $null } }
  return $r
}

function Remove-JoyStar {
  param([string]$Token, [string]$FullName, [string]$Proxy)
  $uri = 'https://api.github.com/user/starred/' + $FullName
  $r = Invoke-JoyHttp -Method 'DELETE' -Uri $uri -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if ($r.ok -or $r.status -eq 404) { return @{ ok = $true; status = $r.status; error = $null } }
  return @{ ok = $false; status = $r.status; error = (($r.body + ' ' + $r.error).Trim()) }
}

function Get-JoyStarredMap {
  param([string]$Token, [string[]]$FullNames, [string]$Proxy)

  $map = @{}
  $unknown = New-Object System.Collections.Generic.List[string]
  $list = @($FullNames | Where-Object { $_ } | Sort-Object -Unique)
  for ($i = 0; $i -lt $list.Count; $i += 25) {
    $end = [Math]::Min($i + 24, $list.Count - 1)
    $chunk = @($list[$i..$end])
    $parts = @()
    $queryNames = @()
    foreach ($full in $chunk) {
      $sp = ([string]$full) -split '/', 2
      if ($sp.Count -lt 2) { $unknown.Add([string]$full); continue }
      $owner = $sp[0] -replace '"', ''
      $name = $sp[1] -replace '"', ''
      $alias = 'r' + $queryNames.Count
      $parts += ($alias + ': repository(owner: "' + $owner + '", name: "' + $name + '") { nameWithOwner viewerHasStarred }')
      $queryNames += [string]$full
    }
    if ($parts.Count -eq 0) { continue }
    $q = 'query { ' + ($parts -join ' ') + ' }'
    $r = $null
    for ($att = 1; $att -le 2; $att++) {
      $r = Invoke-JoyGraphQL -Token $Token -Query $q -Proxy $Proxy
      if ($r.ok) { break }
      if ($att -lt 2) {
        Write-JoyLog ("star filter batch failed, retrying: " + [string]$r.error) 'WARN'
        Start-Sleep -Seconds 2
      }
    }
    if (-not $r -or -not $r.ok) {
      # Preserve exact names so the caller can inspect their List memberships.
      foreach ($full in $queryNames) { $unknown.Add([string]$full) }
      Write-JoyLog ("star filter batch failed after retry: " + [string]$r.error) 'WARN'
      continue
    }
    for ($j = 0; $j -lt $queryNames.Count; $j++) {
      $node = $r.data.('r' + $j)
      if ($null -eq $node) { $unknown.Add([string]$queryNames[$j]); continue }
      if ([bool]$node.viewerHasStarred) { $map[[string]$node.nameWithOwner] = $true }
    }
  }
  return @{ ok = ($unknown.Count -eq 0); map = $map; unknown = @($unknown.ToArray()); errors = $unknown.Count }
}

function Get-JoyRepoNodeId {
  param([string]$Token, [string]$FullName, [string]$Proxy)
  $r = Invoke-JoyHttp -Uri ("https://api.github.com/repos/" + $FullName) -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return $null }
  try { return [string](($r.body | ConvertFrom-Json).node_id) } catch { return $null }
}
