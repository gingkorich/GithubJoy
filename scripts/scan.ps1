# GitHub Joy - scan: Search API -> dedupe -> queue -> Lists -> star
# ASCII only (PowerShell 5.1). Dry run writes nothing and mutates nothing.
param(
  [switch]$DryRun,
  [switch]$NoStar,
  [int]$MaxAdd = 0,
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
$runId = 'scan-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$started = Get-Date

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\scan-' + (Get-Date -Format 'yyyy-MM-dd') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("scan {0} start (dryRun={1}, noStar={2})" -f $runId, [bool]$DryRun, [bool]$NoStar)
Write-JoyEvent @{ evt = 'progress'; phase = 'start'; done = 0; total = 5 }

$script:Result = [ordered]@{
  ok             = $false
  dryRun         = [bool]$DryRun
  runId          = $runId
  startedAt      = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  durationMs     = 0
  tokenSource    = 'none'
  login          = $null
  proxy          = $null
  scanned        = 0
  added          = 0
  queued         = 0
  skipped        = [ordered]@{ already_read = 0; already_unread = 0; already_done = 0; denied = 0; starred = 0; capped = 0; star_quota = 0 }
  starred        = 0
  starSkipped    = 0
  starFailed     = 0
  selectionUsed  = [ordered]@{}
  selectionFilled = 0
  listsCreated   = @()
  listsWouldCreate = @()
  listAddFailed  = @()
  periods        = @()
  unreadCount    = 0
  totalUnreadAfter = 0
  trendingFile   = $null
  queueFile      = $null
  error          = $null
  hint           = $null
}

function Save-ResultAndExit([int]$Code) {
  $script:Result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
  if ($JsonOut) {
    Write-JoyJsonFile $JsonOut $script:Result
  }
  $summary = $script:Result | ConvertTo-Json -Compress -Depth 8
  Write-JoyEvent @{ evt = 'result'; code = $Code; result = $script:Result }
  Write-JoyLog ("scan finished code={0} added={1} starred={2} error={3}" -f $Code, $script:Result.added, $script:Result.starred, $script:Result.error)
  exit $Code
}

function Fail-JoyScan([int]$Code, [string]$Message, [string]$Hint = '') {
  $script:Result.ok = $false
  $script:Result.error = $Message
  $script:Result.hint = $Hint
  Write-JoyLog ("FAIL: {0}" -f $Message) 'ERROR'
  Save-ResultAndExit $Code
}

function New-IsoNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Get-QueuePath { Join-Path $dataDir 'queue.json' }
function Get-StatePath { Join-Path $dataDir 'state.json' }
function Get-TrendingPath([string]$Date) { Join-Path $dataDir ("trending-$Date.json") }

function Get-InitialQueue {
  return [pscustomobject]@{
    version = 1
    updatedAt = (New-IsoNow)
    seq = 0
    items = @()
  }
}

function Get-InitialState {
  return [pscustomobject]@{
    version = 1
    lastScan = $null
    lastRead = $null
    starCounters = [pscustomobject]@{ day = (Get-Date).ToString('yyyy-MM-dd'); count = 0 }
  }
}

function Test-Denied($Item, $Config) {
  $dl = $null
  if ($Config -and $Config.PSObject.Properties.Name -contains 'queue' -and $Config.queue) { $dl = $Config.queue.denylist }
  if (-not $dl) { return $false }
  $full = [string]$Item.fullName
  $owner = ($full -split '/')[0]
  $lang = ''
  if ($Item.PSObject.Properties.Name -contains 'language') { $lang = [string]$Item.language }
  $desc = ''
  if ($Item.PSObject.Properties.Name -contains 'description') { $desc = [string]$Item.description }
  $hay = ($full + ' ' + $desc).ToLowerInvariant()

  foreach ($x in @($dl.owners)) { if ($x -and $owner.ToLowerInvariant() -eq ([string]$x).ToLowerInvariant()) { return $true } }
  foreach ($x in @($dl.repos)) { if ($x -and $full.ToLowerInvariant() -eq ([string]$x).ToLowerInvariant()) { return $true } }
  foreach ($x in @($dl.languages)) { if ($x -and $lang -and $lang.ToLowerInvariant() -eq ([string]$x).ToLowerInvariant()) { return $true } }
  foreach ($x in @($dl.keywords)) { if ($x -and $hay.Contains(([string]$x).ToLowerInvariant())) { return $true } }
  return $false
}

Write-JoyLog ("root={0} runId={1}" -f $root, $runId)
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }

# ---------------------------------------------------------------- auth
$cfg = Get-JoyConfig
$proxy = Get-JoyProxy
$script:Result.proxy = $proxy
if ($proxy) { Write-JoyLog "proxy=$proxy" } else { Write-JoyLog 'proxy=none (direct)' }
Use-JoyProxy $proxy

$tok = Get-JoyTokenInfo -Proxy $proxy
$script:Result.tokenSource = $tok.source
if (-not $tok.value) {
  Fail-JoyScan 2 'no GitHub token: run gh auth login or set gh.json.token' 'RUNBOOK 5.2 / 5.3'
}
$token = $tok.value
$login = Get-JoyViewer -Token $token -Proxy $proxy
if (-not $login) {
  Fail-JoyScan 2 'token rejected by GitHub (viewer query failed)' 'Re-login with gh, or replace the PAT'
}
$script:Result.login = $login
Write-JoyLog "authenticated as $login (tokenSource=$($tok.source))"
Write-JoyEvent @{ evt = 'progress'; phase = 'auth'; done = 1; total = 5 }

# ---------------------------------------------------------------- search
$searchCfg = $cfg.search
$periods = @('today', 'week', 'month')
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'periods' -and $searchCfg.periods) {
  $periods = @($searchCfg.periods)
}
$perPage = 25
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'perPage' -and $searchCfg.perPage) { $perPage = [int]$searchCfg.perPage }
$strict = $true
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'strict') { $strict = [bool]$searchCfg.strict }
$op = '>='
if ($strict) { $op = '>' }
$interval = 300
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'intervalMs' -and $searchCfg.intervalMs) { $interval = [int]$searchCfg.intervalMs }
$minStars = $null
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'minStars') { $minStars = $searchCfg.minStars }

$days = @{ today = 1; week = 7; month = 30 }
$records = @()
$periodSummaries = @()
$utcToday = [DateTime]::UtcNow.Date

for ($i = 0; $i -lt $periods.Count; $i++) {
  $period = [string]$periods[$i]
  $d = 1
  if ($days.ContainsKey($period)) { $d = $days[$period] }
  $min = 0
  if ($minStars -and $minStars.PSObject.Properties.Name -contains $period) { $min = [int]$minStars.$period }
  $since = $utcToday.AddDays(-1 * $d).ToString('yyyy-MM-dd')
  $q = "created:>=$since stars:$op$min archived:false fork:false"
  $url = 'https://api.github.com/search/repositories?q=' + [uri]::EscapeDataString($q) + "&sort=stars&order=desc&per_page=$perPage"

  Write-JoyLog "search $period q=$q"
  $r = Invoke-JoyHttp -Uri $url -Headers (New-JoyApiHeaders $token) -Proxy $proxy -TimeoutSec 30
  if (-not $r.ok) {
    $detail = Protect-JoySecret (($r.body + ' ' + $r.error).Trim())
    if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
    Fail-JoyScan 1 "search $period failed (HTTP $($r.status)): $detail" 'Check proxy/network, or wait for the search rate limit (RUNBOOK 6.4)'
  }

  $obj = $null
  try { $obj = $r.body | ConvertFrom-Json } catch { Fail-JoyScan 1 "search $period returned non-JSON" '' }
  $total = 0
  if ($obj.PSObject.Properties.Name -contains 'total_count') { $total = [int]$obj.total_count }
  $items = @($obj.items)
  if ($total -eq 0 -or $items.Count -eq 0) {
    Write-JoyLog ("search {0} returned 0 items (stars{1}{2} since={3}); treat as empty" -f $period, $op, $min, $since) 'WARN'
    $periodSummaries += [pscustomobject]@{
      period = $period; query = $q; totalCount = $total; got = 0; fetchedAt = (New-IsoNow)
    }
    Write-JoyEvent @{ evt = 'progress'; phase = 'search'; done = ($i + 1); total = $periods.Count }
    if ($i -lt $periods.Count - 1) { Start-Sleep -Milliseconds $interval }
    continue
  }

  $rank = 0
  foreach ($it in $items) {
    $rank++
    $records += [pscustomobject]@{
      fullName    = [string]$it.full_name
      period      = $period
      rank        = $rank
      stars       = [int]$it.stargazers_count
      forks       = [int]$it.forks_count
      language    = [string]$it.language
      description = [string]$it.description
      createdAt   = [string]$it.created_at
      pushedAt    = [string]$it.pushed_at
      archived    = [bool]$it.archived
      topics      = @($it.topics)
      nodeId      = [string]$it.node_id
      query       = $q
    }
  }
  $periodSummaries += [pscustomobject]@{
    period = $period; query = $q; totalCount = $total; got = $items.Count; fetchedAt = (New-IsoNow)
  }
  Write-JoyLog "search $period total=$total got=$($items.Count)"
  Write-JoyEvent @{ evt = 'progress'; phase = 'search'; done = ($i + 1); total = $periods.Count }
  if ($i -lt $periods.Count - 1) { Start-Sleep -Milliseconds $interval }
}
$script:Result.periods = $periodSummaries
$script:Result.scanned = $records.Count
if ($records.Count -eq 0) {
  Fail-JoyScan 1 'no candidates from any period' 'Check thresholds, proxy/network, or lower config.search.minStars'
}

# trending snapshot (real run only)
if (-not $DryRun) {
  $date = $utcToday.ToString('yyyy-MM-dd')
  $snapItems = @()
  foreach ($rec in $records) {
    $snapItems += [ordered]@{
      fullName = $rec.fullName; period = $rec.period; rank = $rec.rank
      stars = $rec.stars; language = $rec.language; description = $rec.description
      createdAt = $rec.createdAt; pushedAt = $rec.pushedAt; archived = $rec.archived
    }
  }
  $trending = [ordered]@{
    version = 1; date = $date; source = 'search'; periods = $periodSummaries; items = $snapItems
  }
  $tp = Get-TrendingPath $date
  Write-JoyJsonFile $tp $trending
  $script:Result.trendingFile = $tp
  Write-JoyLog "trending snapshot written: $tp"
}

# ---------------------------------------------------------------- dedupe
$priority = @{}
for ($i = 0; $i -lt $periods.Count; $i++) { $priority[[string]$periods[$i]] = $i }

$candMap = @{}
foreach ($rec in $records) {
  $key = $rec.fullName.ToLowerInvariant()
  if (-not $candMap.ContainsKey($key)) {
    $pi = 99
    if ($priority.ContainsKey($rec.period)) { $pi = [int]$priority[$rec.period] }
    $candMap[$key] = [pscustomobject]@{
      key = $key; fullName = $rec.fullName; firstRank = $rec.rank; firstPeriod = $rec.period
      order = ($pi * 100000 + $rec.rank); periods = @(); repo = $rec
    }
  }
  $candMap[$key].periods += [pscustomobject]@{ period = $rec.period; rank = $rec.rank }
}
$candidates = @($candMap.Values | Sort-Object order)
Write-JoyLog "unique candidates: $($candidates.Count)"
Write-JoyEvent @{ evt = 'progress'; phase = 'search'; done = $periods.Count; total = $periods.Count }

# ---------------------------------------------------------------- state
$queue = Read-JoyJsonFile (Get-QueuePath)
if (-not $queue) { $queue = Get-InitialQueue }
if (-not ($queue.PSObject.Properties.Name -contains 'items')) { $queue | Add-Member -NotePropertyName items -NotePropertyValue @() -Force }
$state = Read-JoyJsonFile (Get-StatePath)
if (-not $state) { $state = Get-InitialState }
if (-not ($state.PSObject.Properties.Name -contains 'starCounters') -or -not $state.starCounters) {
  $state | Add-Member -NotePropertyName starCounters -NotePropertyValue ([pscustomobject]@{ day = (Get-Date).ToString('yyyy-MM-dd'); count = 0 }) -Force
}

$queueIndex = @{}
foreach ($qi in @($queue.items)) {
  if ($null -ne $qi -and $qi.id) { $queueIndex[([string]$qi.id).ToLowerInvariant()] = $qi }
}
Write-JoyLog "queue items: $($queue.items.Count), seq=$($queue.seq)"

# ---------------------------------------------------------------- lists
Write-JoyEvent @{ evt = 'progress'; phase = 'lists'; done = 0; total = 1 }
$listsRes = Get-JoyLists -Token $token -Proxy $proxy
if (-not $listsRes.ok) {
  Fail-JoyScan 2 ('cannot read Star Lists: ' + [string]$listsRes.error) 'Check the user scope (RUNBOOK 6.5)'
}

$names = Get-JoyListNames
$byName = @{}
foreach ($l in @($listsRes.lists)) {
  $nk = ([string]$l.name).ToLowerInvariant()
  if ($byName.ContainsKey($nk)) {
    Write-JoyLog ("duplicate List name '{0}' ignored (first one wins)" -f $l.name) 'WARN'
  } else {
    $byName[$nk] = $l
  }
}
$unread = $null
$read = $null
$uk = ([string]$names.unread).ToLowerInvariant()
$rk = ([string]$names.read).ToLowerInvariant()
if ($byName.ContainsKey($uk)) { $unread = $byName[$uk] }
if ($byName.ContainsKey($rk)) { $read = $byName[$rk] }

$created = @()
$wouldCreate = @()
$unreadIsNew = $false
$readIsNew = $false

if (-not $unread) {
  if ($DryRun) {
    Write-JoyLog ("dryRun: would create List '{0}'" -f $names.unread)
    $wouldCreate += [string]$names.unread
    $unreadIsNew = $true
  } else {
    $c = New-JoyList -Token $token -Name ([string]$names.unread) -Description 'GitHub Joy: items to read' -Proxy $proxy
    if (-not $c.ok) { Fail-JoyScan 2 ('create List failed: ' + [string]$c.error) 'Check the user scope' }
    $unread = [pscustomobject]@{ id = $c.id; name = [string]$names.unread; itemCount = 0; isPrivate = $false }
    $created += [string]$names.unread
    $unreadIsNew = $true
    Write-JoyLog ("created List '{0}' ({1})" -f $names.unread, $c.id)
  }
}

if (-not $read) {
  if ($DryRun) {
    Write-JoyLog ("dryRun: would create List '{0}'" -f $names.read)
    $wouldCreate += [string]$names.read
    $readIsNew = $true
  } else {
    $c = New-JoyList -Token $token -Name ([string]$names.read) -Description 'GitHub Joy: already read' -Proxy $proxy
    if (-not $c.ok) { Fail-JoyScan 2 ('create List failed: ' + [string]$c.error) 'Check the user scope' }
    $read = [pscustomobject]@{ id = $c.id; name = [string]$names.read; itemCount = 0; isPrivate = $false }
    $created += [string]$names.read
    $readIsNew = $true
    Write-JoyLog ("created List '{0}' ({1})" -f $names.read, $c.id)
  }
}

$script:Result.listsCreated = $created
$script:Result.listsWouldCreate = $wouldCreate

$allLists = @{}
foreach ($l in @($listsRes.lists)) { $allLists[[string]$l.id] = $l }
if ($unread -and -not $unreadIsNew) { $allLists[[string]$unread.id] = $unread }
if ($read -and -not $readIsNew) { $allLists[[string]$read.id] = $read }
if ($unreadIsNew -and $unread) { $allLists[[string]$unread.id] = $unread }
if ($readIsNew -and $read) { $allLists[[string]$read.id] = $read }

$member = @{}
$unreadCount = 0
foreach ($l in @($allLists.Values)) {
  if (-not $l.id) { continue }
  if ($unread -and $unread.id -eq $l.id) { $unreadCount = [int]$l.itemCount }
  if ($unreadIsNew -and $unread -and $unread.id -eq $l.id) { continue }
  $items = Get-JoyListItems -Token $token -ListId ([string]$l.id) -Proxy $proxy
  if (-not $items.ok) {
    Fail-JoyScan 2 ("cannot read items of List '{0}': {1}" -f $l.name, $items.error) 'Check GraphQL scope/limits'
  }
  foreach ($nm in @($items.names)) {
    $k = ([string]$nm).ToLowerInvariant()
    if (-not $member.ContainsKey($k)) { $member[$k] = New-Object System.Collections.Generic.List[string] }
    if (-not $member[$k].Contains([string]$l.id)) { $member[$k].Add([string]$l.id) }
  }
  Write-JoyLog ("list '{0}': {1} items (totalCount={2})" -f $l.name, @($items.names).Count, $l.itemCount)
}
$script:Result.unreadCount = $unreadCount
Write-JoyLog "lists indexed: $($allLists.Count), unreadCount=$unreadCount"
Write-JoyEvent @{ evt = 'progress'; phase = 'lists'; done = 1; total = 1 }

# ---------------------------------------------------------------- filter
$toAdd = @()
$toEnsure = @()
$skipped = $script:Result.skipped

foreach ($c in $candidates) {
  $ids = @()
  if ($member.ContainsKey($c.key)) { $ids = @($member[$c.key].ToArray()) }
  $qi = $null
  if ($queueIndex.ContainsKey($c.key)) { $qi = $queueIndex[$c.key] }

  $inUnread = $false
  $inRead = $false
  if ($unread -and $unread.id -and ($ids -contains [string]$unread.id)) { $inUnread = $true }
  if ($read -and $read.id -and ($ids -contains [string]$read.id)) { $inRead = $true }

  if ($inRead) { $skipped.already_read++; continue }
  if ($inUnread) {
    $skipped.already_unread++
    if ($qi -and $qi.PSObject.Properties.Name -contains 'list' -and $qi.list) { $qi.list.inUnread = $true }
    continue
  }
  if ($qi) {
    $st = [string]$qi.status
    if ($st -in @('done', 'moved')) { $skipped.already_done++; continue }
    if ($st -in @('pending', 'summarizing', 'failed')) {
      $toEnsure += [pscustomobject]@{ cand = $c; qi = $qi; ids = $ids }
      continue
    }
    if ($st -eq 'gone') { continue }
  }
  if (Test-Denied $c.repo $cfg) { $skipped.denied++; continue }
  $toAdd += [pscustomobject]@{ cand = $c; ids = $ids }
}

Write-JoyLog ("filtered: add={0} ensure={1} skipped(read={2},unread={3},done={4},denied={5})" -f `
  $toAdd.Count, $toEnsure.Count, $skipped.already_read, $skipped.already_unread, $skipped.already_done, $skipped.denied)

# ---------------------------------------------------------------- star config (needed for quota)
$starCfg = $null
if ($cfg.PSObject.Properties.Name -contains 'star') { $starCfg = $cfg.star }
$starEnabled = -not [bool]$NoStar
$maxScan = 25
$maxDay = 100
$starInterval = 1000
if ($starCfg) {
  if ($starCfg.PSObject.Properties.Name -contains 'enabled') { $starEnabled = $starEnabled -and [bool]$starCfg.enabled }
  if ($starCfg.PSObject.Properties.Name -contains 'maxPerScan') { $maxScan = [int]$starCfg.maxPerScan }
  if ($starCfg.PSObject.Properties.Name -contains 'maxPerDay') { $maxDay = [int]$starCfg.maxPerDay }
  if ($starCfg.PSObject.Properties.Name -contains 'intervalMs') { $starInterval = [int]$starCfg.intervalMs }
}

$today = (Get-Date).ToString('yyyy-MM-dd')
if ([string]$state.starCounters.day -ne $today) {
  $state.starCounters.day = $today
  $state.starCounters.count = 0
}
$dayCount = [int]$state.starCounters.count

# ---------------------------------------------------------------- star filter
$starFilter = $true
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'starFilter') { $starFilter = [bool]$searchCfg.starFilter }

if ($starFilter -and $toAdd.Count -gt 0) {
  $names = @()
  foreach ($e in $toAdd) { $names += [string]$e.cand.fullName }
  $sf = Get-JoyStarredMap -Token $token -FullNames $names -Proxy $proxy
  $keepAdd = @()
  foreach ($e in $toAdd) {
    if ($sf.map.ContainsKey([string]$e.cand.fullName)) { $skipped.starred++ } else { $keepAdd += $e }
  }
  $toAdd = $keepAdd
  Write-JoyLog ("star filter: alreadyStarred={0} batchErrors={1} remainAdd={2}" -f $sf.map.Count, $sf.errors, $toAdd.Count)
}

# ---------------------------------------------------------------- quota selection
$maxSelect = 25
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'maxPerScan') { $maxSelect = [int]$searchCfg.maxPerScan }
$quota = $null
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'quota') { $quota = $searchCfg.quota }
$fillRemaining = $true
if ($searchCfg -and $searchCfg.PSObject.Properties.Name -contains 'fillRemaining') { $fillRemaining = [bool]$searchCfg.fillRemaining }

$eligible = @($toAdd | Sort-Object { [int]$_.cand.repo.stars } -Descending)
$selected = @()
$selKeys = @{}
$used = [ordered]@{}
foreach ($p in $periods) {
  $cnt = 0
  $q = 0
  if ($quota -and $quota.PSObject.Properties.Name -contains ([string]$p)) { $q = [int]$quota.([string]$p) }
  if ($q -gt 0) {
    foreach ($e in $eligible) {
      if ($cnt -ge $q -or $selected.Count -ge $maxSelect) { break }
      if ($selKeys.ContainsKey($e.cand.key)) { continue }
      if ([string]$e.cand.firstPeriod -ne [string]$p) { continue }
      $selected += $e
      $selKeys[$e.cand.key] = $true
      $cnt++
    }
  }
  $used[[string]$p] = $cnt
}
$filled = 0
if ($fillRemaining) {
  foreach ($e in $eligible) {
    if ($selected.Count -ge $maxSelect) { break }
    if (-not $selKeys.ContainsKey($e.cand.key)) {
      $selected += $e
      $selKeys[$e.cand.key] = $true
      $filled++
    }
  }
}
$skipped.capped = $eligible.Count - $selected.Count
$toAdd = $selected
$script:Result.selectionUsed = $used
$script:Result.selectionFilled = $filled
$usedText = (($used.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')
Write-JoyLog ("selection: eligible={0} picked={1} byPeriod={2}" -f $eligible.Count, $selected.Count, $usedText)

if ($MaxAdd -gt 0 -and $toAdd.Count -gt $MaxAdd) {
  $skipped.capped += ($toAdd.Count - $MaxAdd)
  $toAdd = @($toAdd | Select-Object -First $MaxAdd)
  Write-JoyLog ("capped adds to {0} (MaxAdd)" -f $MaxAdd) 'WARN'
}

# never add more than the remaining daily star quota, so "added => starred" holds
$dayRemaining = $maxDay - $dayCount
if ($dayRemaining -lt 0) { $dayRemaining = 0 }
$ensureNeed = @($toEnsure | Where-Object { -not $_.qi.starred }).Count
$capacity = [Math]::Min($maxScan, $dayRemaining) - $ensureNeed
if ($capacity -lt 0) { $capacity = 0 }
if ($toAdd.Count -gt $capacity) {
  $dropped = $toAdd.Count - $capacity
  $toAdd = @($toAdd | Select-Object -First $capacity)
  $skipped.star_quota += $dropped
  $skipped.capped += $dropped
  Write-JoyLog ("star capacity={0} (ensure needs {1}); dropped {2} from this run" -f $capacity, $ensureNeed, $dropped) 'WARN'
}

# ---------------------------------------------------------------- enqueue
$seq = [int]$queue.seq
$newEntries = @()
foreach ($n in $toAdd) {
  $seq++
  $r = $n.cand.repo
  $qi = [pscustomobject][ordered]@{
    id          = [string]$n.cand.key
    fullName    = [string]$r.fullName
    seq         = $seq
    status      = 'pending'
    addedAt     = (New-IsoNow)
    scannedFrom = @($n.cand.periods)
    repo        = [pscustomobject]@{
      nodeId = [string]$r.nodeId; description = [string]$r.description
      language = [string]$r.language; stars = [int]$r.stars; forks = [int]$r.forks
      topics = @($r.topics); archived = [bool]$r.archived; pushedAt = [string]$r.pushedAt
    }
    list        = [pscustomobject]@{ inUnread = $false; inRead = $false; otherListIds = @() }
    starred     = $false
    starSkipped = $null
    attempts    = 0
    lastError   = $null
    summaryPath = $null
    published   = $false
    publishedUrl = $null
    movedAt     = $null
  }
  $queue.items = @($queue.items) + $qi
  $queueIndex[$n.cand.key] = $qi
  $newEntries += [pscustomobject]@{ qi = $qi; ids = $n.ids }
}
$queue.seq = $seq
Write-JoyLog "selected for unread: $($newEntries.Count)"
Write-JoyEvent @{ evt = 'progress'; phase = 'select'; done = 1; total = 1 }

# ------------------------------------------------- star + lists write
# GitHub Star Lists only keep starred repositories: star first, then add.
$unreadId = $null
if ($unread) { $unreadId = [string]$unread.id }
$addFailed = @()
$addedOk = 0
$addedPlan = 0
$ensuredOk = 0
$ensuredPlan = 0
$starCount = 0
$starPlan = 0
$starSkipped = 0
$starFailed = 0

$mutations = @()
foreach ($e in $toEnsure) { $mutations += [pscustomobject]@{ qi = $e.qi; ids = $e.ids; isNew = $false } }
foreach ($e in $newEntries) { $mutations += [pscustomobject]@{ qi = $e.qi; ids = $e.ids; isNew = $true } }

if ($mutations.Count -gt 0 -and -not $unreadId -and -not $DryRun) {
  Fail-JoyScan 2 'unread List id is missing; cannot add items' 'Create the List manually or re-run without --dry-run'
}
if (-not $starEnabled -and $mutations.Count -gt 0) {
  Write-JoyLog 'star disabled (NoStar): Star Lists require starred repos, list writes are skipped' 'WARN'
}

foreach ($m in $mutations) {
  $target = @()
  foreach ($id in @($m.ids)) {
    if ($id -and $id -ne $unreadId) { $target += [string]$id }
  }
  if ($unreadId) { $target += $unreadId }

  if ($DryRun) {
    if (-not $starEnabled) {
      $m.qi.starSkipped = 'disabled'
      $starSkipped++
      continue
    }
    if (-not $m.qi.starred) {
      if ($starPlan -ge $maxScan) { $m.qi.starSkipped = 'cap_per_scan'; $starSkipped++; continue }
      if ($dayCount -ge $maxDay) { $m.qi.starSkipped = 'cap_per_day'; $starSkipped++; continue }
      $starPlan++
    }
    if ($m.isNew) { $addedPlan++ } else { $ensuredPlan++ }
    $planTotal = $addedPlan + $ensuredPlan
    if ($planTotal -le 10) {
      Write-JoyLog ("dryRun: would star + set Lists for {0} -> [{1}]" -f $m.qi.fullName, ($target -join ', '))
    }
    continue
  }

  if (-not $starEnabled) {
    $m.qi.starSkipped = 'disabled'
    $starSkipped++
    continue
  }

  if (-not $m.qi.starred) {
    if ($starCount -ge $maxScan) { $m.qi.starSkipped = 'cap_per_scan'; $starSkipped++; continue }
    if ($dayCount -ge $maxDay) { $m.qi.starSkipped = 'cap_per_day'; $starSkipped++; continue }
    $sr = Add-JoyStar -Token $token -FullName ([string]$m.qi.fullName) -Proxy $proxy
    if (-not $sr.ok) {
      $starFailed++
      $m.qi.starSkipped = 'failed'
      $m.qi.lastError = ('star_failed: ' + [string]$sr.error)
      Write-JoyLog ("star failed for {0}: {1}" -f $m.qi.fullName, $sr.error) 'WARN'
      continue
    }
    $m.qi.starred = $true
    $starCount++
    $dayCount++
    Start-Sleep -Milliseconds $starInterval
  }

  $nodeId = [string]$m.qi.repo.nodeId
  if (-not $nodeId) {
    $nodeId = Get-JoyRepoNodeId -Token $token -FullName ([string]$m.qi.fullName) -Proxy $proxy
    if ($nodeId) { $m.qi.repo.nodeId = $nodeId }
  }
  if (-not $nodeId) {
    $addFailed += [pscustomobject]@{ fullName = [string]$m.qi.fullName; error = 'missing_node_id' }
    $m.qi.lastError = 'missing_node_id'
    continue
  }

  $res = Set-JoyItemLists -Token $token -NodeId $nodeId -ListIds $target -Proxy $proxy
  if (-not $res.ok) {
    $addFailed += [pscustomobject]@{ fullName = [string]$m.qi.fullName; error = [string]$res.error }
    $m.qi.list.inUnread = $false
    $m.qi.lastError = ('list_add_failed: ' + [string]$res.error)
    continue
  }
  $m.qi.list.inUnread = $true
  $other = @()
  foreach ($id in $target) { if ($id -ne $unreadId) { $other += $id } }
  $m.qi.list.otherListIds = $other
  if ($m.isNew) { $addedOk++ } else { $ensuredOk++ }
  Start-Sleep -Milliseconds 300
}

if ($DryRun) {
  $addedOk = $addedPlan
  $ensuredOk = $ensuredPlan
}
$script:Result.listAddFailed = $addFailed
$script:Result.queued = 0
$script:Result.added = $addedOk
$script:Result.ensured = 0
Write-JoyLog ("star: done={0} planned={1} skipped={2} failed={3}" -f $starCount, $starPlan, $starSkipped, $starFailed)
Write-JoyLog ("lists write: addedOk={0} failed={1}" -f $addedOk, $addFailed.Count)

# ---------------------------------------------------------------- persist
$totalUnreadAfter = $unreadCount + $addedOk + $ensuredOk
$elapsed = [int]((Get-Date) - $started).TotalMilliseconds

$state.lastScan = [pscustomobject][ordered]@{
  runId = $runId
  at = (New-IsoNow)
  durationMs = $elapsed
  scanned = $records.Count
  added = $addedOk
  queued = 0
  ensured = 0
  skipped = $skipped
  totalUnreadAfter = $totalUnreadAfter
}
$state.starCounters = [pscustomobject][ordered]@{ day = $today; count = $dayCount }

$statePath = Get-StatePath

if (-not $DryRun) {
  Write-JoyJsonFile $statePath $state
  Write-JoyLog 'state written (queue untouched)'
} else {
  Write-JoyLog 'dryRun: state not written'
}

$script:Result.totalUnreadAfter = $totalUnreadAfter
$script:Result.starred = $(if ($DryRun) { $starPlan } else { $starCount })
$script:Result.starSkipped = $starSkipped
$script:Result.starFailed = $starFailed
$script:Result.ok = ($addFailed.Count -eq 0 -and $starFailed -eq 0)

Write-JoyEvent @{ evt = 'progress'; phase = 'done'; done = 5; total = 5 }
Write-JoyLog ("summary: scanned={0} added={1} unread {2}->{3} starred={4} skipped={5} listFailed={6}" -f `
  $records.Count, $addedOk, $unreadCount, $totalUnreadAfter, $script:Result.starred, $starSkipped, $addFailed.Count)

$exitCode = 0
if (-not $script:Result.ok) { $exitCode = 5 }
Save-ResultAndExit $exitCode