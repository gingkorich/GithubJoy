# GitHub Joy - migrate: published items unread -> read (M4b)
# ASCII only (PowerShell 5.1).
param(
  [string]$RunId = '',
  [string]$OnlyId = '',
  [switch]$DryRun,
  [string]$Rollback = '',
  [string]$JsonOut = '',
  [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
try {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
  $OutputEncoding = [Text.Encoding]::UTF8
} catch { }

. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\http.ps1')
. (Join-Path $PSScriptRoot 'lib\github.ps1')

$root = Get-JoyRoot
$dataDir = Join-Path $root 'data'
$stateDir = Join-Path $dataDir 'state'
$queuePath = Join-Path $dataDir 'queue.json'
$runTag = 'migrate-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$started = Get-Date
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\migrate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("migrate {0} start (dryRun={1}, runId={2}, rollback={3})" -f $runTag, [bool]$DryRun, $RunId, $Rollback)

$script:Result = [ordered]@{
  ok = $false; runId = $runTag
  startedAt = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  durationMs = 0; dryRun = [bool]$DryRun
  selected = 0; moved = 0; failed = 0; rolledBack = 0
  snapshot = $null; items = @(); error = $null
}

function New-IsoNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-StatePath { Join-Path $dataDir 'state.json' }

function Save-ResultAndExit([int]$Code) {
  $script:Result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
  if ($JsonOut) { Write-JoyJsonFile $JsonOut $script:Result }
  Write-JoyEvent @{ evt = 'result'; code = $Code; result = $script:Result }
  Write-JoyLog ("migrate finished code={0} moved={1} failed={2} rolledBack={3}" -f $Code, $script:Result.moved, $script:Result.failed, $script:Result.rolledBack)
  exit $Code
}

function Fail-JoyMigrate([int]$Code, [string]$Message, [string]$Hint = '') {
  $script:Result.ok = $false; $script:Result.error = $Message
  if ($Hint) { Write-JoyLog $Hint 'WARN' }
  Write-JoyLog ("FAIL: {0}" -f $Message) 'ERROR'
  Save-ResultAndExit $Code
}

# ---------------------------------------------------------------- auth + lists
$cfg = Get-JoyConfig
$proxy = Get-JoyProxy
Use-JoyProxy $proxy
$tok = Get-JoyTokenInfo -Proxy $proxy
if (-not $tok.value) { Fail-JoyMigrate 2 'no GitHub token' 'Run gh auth login or set gh.json.token' }
$token = $tok.value

$listsRes = Get-JoyLists -Token $token -Proxy $proxy
if (-not $listsRes.ok) { Fail-JoyMigrate 2 ('cannot read Lists: ' + [string]$listsRes.error) 'Check user scope' }

$names = Get-JoyListNames
$unread = $listsRes.lists | Where-Object { ([string]$_.name).ToLowerInvariant() -eq ([string]$names.unread).ToLowerInvariant() } | Select-Object -First 1
$read = $listsRes.lists | Where-Object { ([string]$_.name).ToLowerInvariant() -eq ([string]$names.read).ToLowerInvariant() } | Select-Object -First 1
if (-not $unread -or -not $read) { Fail-JoyMigrate 2 'unread/read List not found' 'Run scan to create them' }

$unreadId = [string]$unread.id
$readId = [string]$read.id

# ---------------------------------------------------------------- rollback
if ($Rollback) {
  $snapPath = Join-Path $stateDir ('lists-' + $Rollback + '.json')
  if (-not (Test-Path -LiteralPath $snapPath)) { Fail-JoyMigrate 2 ('snapshot not found: ' + $snapPath) }
  $snap = Read-JoyJsonFile $snapPath

  foreach ($s in @($snap.items)) {
    $target = @()
    foreach ($id in @($s.otherListIds)) { if ($id) { $target += [string]$id } }
    $target += $unreadId
    if ($DryRun) {
      Write-JoyLog ("dryRun: would restore {0} to [{1}]" -f $s.fullName, ($target -join ', '))
      $script:Result.rolledBack++
      continue
    }
    $nodeId = [string]$s.nodeId
    if (-not $nodeId) { $nodeId = Get-JoyRepoNodeId -Token $token -FullName ([string]$s.fullName) -Proxy $proxy }
    if (-not $nodeId) { $script:Result.failed++; continue }
    $r = Set-JoyItemLists -Token $token -NodeId $nodeId -ListIds $target -Proxy $proxy
    if ($r.ok) { $script:Result.rolledBack++ } else { $script:Result.failed++ }
    Start-Sleep -Milliseconds 300
  }
  $script:Result.ok = ($script:Result.failed -eq 0)
  if (-not $script:Result.ok) { Save-ResultAndExit 5 }
  Save-ResultAndExit 0
}

# ---------------------------------------------------------------- select from published reports
$idxPath = Join-Path $dataDir 'reports-index.json'
$idx = Read-JoyJsonFile $idxPath
if (-not $idx) { Fail-JoyMigrate 1 'reports-index.json missing' 'Run render and publish first' }
if ($idx -isnot [array]) { $idx = @($idx) }

$publishedIds = @{}
foreach ($e in $idx) {
  if (-not [bool]$e.published) { continue }
  if (-not ($e.PSObject.Properties.Name -contains 'ids')) { continue }
  foreach ($id in @($e.ids)) {
    if ($id) { $publishedIds[([string]$id).ToLowerInvariant()] = $true }
  }
}
if ($publishedIds.Count -eq 0) {
  Write-JoyLog 'nothing to migrate (no published report entries)'
  $script:Result.ok = $true
  Save-ResultAndExit 0
}
if ($RunId) { Fail-JoyMigrate 2 'RunId filter is no longer supported' 'Use -OnlyId or migrate all published entries' }

$detail = Get-JoyListItemsDetailed -Token $token -ListId $unreadId -Proxy $proxy -Max 300
if (-not $detail.ok) { Fail-JoyMigrate 2 ('cannot read unread items: ' + [string]$detail.error) }
$unreadMap = @{}
foreach ($li in @($detail.items)) { $unreadMap[([string]$li.fullName).ToLowerInvariant()] = $li }

$membership = @{}
foreach ($l in @($listsRes.lists)) {
  $items = Get-JoyListItems -Token $token -ListId ([string]$l.id) -Proxy $proxy
  if (-not $items.ok) { continue }
  foreach ($nm in @($items.names)) {
    $k = ([string]$nm).ToLowerInvariant()
    if (-not $membership.ContainsKey($k)) { $membership[$k] = New-Object System.Collections.Generic.List[string] }
    if (-not $membership[$k].Contains([string]$l.id)) { $membership[$k].Add([string]$l.id) }
  }
}

$todo = @()
foreach ($k in @($publishedIds.Keys)) {
  if (-not $unreadMap.ContainsKey($k)) { continue }
  $li = $unreadMap[$k]
  $other = @()
  if ($membership.ContainsKey($k)) {
    foreach ($id in $membership[$k]) {
      if ($id -ne $unreadId -and $id -ne $readId) { $other += [string]$id }
    }
  }
  $todo += [pscustomobject]@{
    id = $k
    fullName = [string]$li.fullName
    status = 'done'
    published = $true
    movedAt = $null
    lastError = $null
    repo = [pscustomobject]@{ nodeId = [string]$li.id }
    list = [pscustomobject]@{ inUnread = $true; inRead = $false; otherListIds = $other }
  }
}
if ($OnlyId) {
  $todo = @($todo | Where-Object {
      ([string]$_.id).ToLowerInvariant() -eq $OnlyId.ToLowerInvariant() -or
      ([string]$_.fullName).ToLowerInvariant() -eq $OnlyId.ToLowerInvariant()
    })
}
$script:Result.selected = $todo.Count

if ($todo.Count -eq 0) {
  Write-JoyLog 'nothing to migrate (need status=done, published=true, still in unread)'
  $script:Result.ok = $true
  Save-ResultAndExit 0
}
Write-JoyLog ("selected {0} item(s) for migration" -f $todo.Count)

# ---------------------------------------------------------------- snapshot
$snapPath = Join-Path $stateDir ('lists-' + $runTag + '.json')
$snapItems = @()
foreach ($it in $todo) {
  $other = @()
  if ($it.list -and ($it.list.PSObject.Properties.Name -contains 'otherListIds')) { $other = @($it.list.otherListIds) }
  $nodeId = $null
  if ($it.repo -and ($it.repo.PSObject.Properties.Name -contains 'nodeId')) { $nodeId = [string]$it.repo.nodeId }
  $snapItems += [ordered]@{
    id = [string]$it.id; fullName = [string]$it.fullName; nodeId = $nodeId
    otherListIds = $other; status = [string]$it.status
  }
}
$snap = [ordered]@{
  runId = $runTag; capturedAt = (New-IsoNow)
  unreadList = [ordered]@{ id = $unreadId; name = [string]$unread.name }
  readList = [ordered]@{ id = $readId; name = [string]$read.name }
  items = $snapItems
}
if (-not $DryRun) {
  Write-JoyJsonFile $snapPath $snap
  $script:Result.snapshot = $snapPath
  Write-JoyLog ("snapshot written: {0}" -f $snapPath)
} else {
  Write-JoyLog ("dryRun: would write snapshot {0}" -f $snapPath)
}

# ---------------------------------------------------------------- migrate
$itemsOut = @()
$idx = 0
foreach ($it in $todo) {
  $idx++
  $entry = [ordered]@{ id = $it.id; fullName = $it.fullName; status = ''; error = $null }
  try {
    $target = @()
    if ($it.list -and ($it.list.PSObject.Properties.Name -contains 'otherListIds')) {
      foreach ($id in @($it.list.otherListIds)) {
        if ($id -and $id -ne $readId -and $id -ne $unreadId) { $target += [string]$id }
      }
    }
    $target += $readId

    if ($DryRun) {
      Write-JoyLog ("dryRun: would set Lists for {0} -> [{1}]" -f $it.fullName, ($target -join ', '))
      $entry.status = 'would_move'
      $itemsOut += $entry
      $script:Result.moved++
      Write-JoyEvent @{ evt = 'progress'; phase = 'item'; done = $idx; total = $todo.Count }
      continue
    }

    $nodeId = ''
    if ($it.repo -and ($it.repo.PSObject.Properties.Name -contains 'nodeId')) { $nodeId = [string]$it.repo.nodeId }
    if (-not $nodeId) {
      $nodeId = Get-JoyRepoNodeId -Token $token -FullName ([string]$it.fullName) -Proxy $proxy
      if ($nodeId) { $it.repo.nodeId = $nodeId }
    }
    if (-not $nodeId) { throw 'missing_node_id' }

    $r = Set-JoyItemLists -Token $token -NodeId $nodeId -ListIds $target -Proxy $proxy
    if (-not $r.ok) { throw ('list_update_failed: ' + [string]$r.error) }

    $it.status = 'moved'
    $it.movedAt = (New-IsoNow)
    if ($it.list) {
      $it.list.inUnread = $false
      $it.list.inRead = $true
      $it.list.otherListIds = @($target | Where-Object { $_ -ne $readId })
    }
    $script:Result.moved++
    $entry.status = 'moved'
    Write-JoyLog ("moved {0} -> {1}" -f $it.fullName, ([string]$read.name))
    Start-Sleep -Milliseconds 300
  } catch {
    $msg = Protect-JoySecret ([string]$_.Exception.Message)
    $it.lastError = $msg
    $script:Result.failed++
    $entry.status = 'failed'
    $entry.error = $msg
    Write-JoyLog ("failed {0}: {1}" -f $it.fullName, $msg) 'ERROR'
  }
  $itemsOut += $entry
  Write-JoyEvent @{ evt = 'progress'; phase = 'item'; done = $idx; total = $todo.Count }
}

$script:Result.items = $itemsOut
if (-not $DryRun) {
  $st = Read-JoyJsonFile (Get-StatePath)
  if (-not $st) { $st = [pscustomobject]@{ version = 1 } }
  $base = [int]$unread.itemCount
  if ($base -le 0 -and $st.PSObject.Properties.Name -contains 'unreadTotal' -and $st.unreadTotal) {
    $base = [int]$st.unreadTotal.count
  }
  $left = [Math]::Max(0, $base - $script:Result.moved)
  $ut = [ordered]@{ count = $left; refreshedAt = (New-IsoNow) }
  $st | Add-Member -NotePropertyName unreadTotal -NotePropertyValue $ut -Force
  Write-JoyJsonFile (Get-StatePath) $st
  Write-JoyLog ("state.unreadTotal updated to {0}" -f $left)
}

$script:Result.ok = ($script:Result.failed -eq 0)
if (-not $script:Result.ok) { Save-ResultAndExit 5 }
Save-ResultAndExit 0