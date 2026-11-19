# GitHub Joy - publish: reports -> docs/ -> commit -> push (M4b)
# ASCII only (PowerShell 5.1).
param(
  [switch]$DryRun,
  [switch]$NoPush,
  [string]$Message = '',
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

$root = Get-JoyRoot
$dataDir = Join-Path $root 'data'
$reportsDir = Join-Path $root 'reports'
$idxPath = Join-Path $dataDir 'reports-index.json'
$queuePath = Join-Path $dataDir 'queue.json'
$runId = 'publish-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$started = Get-Date

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\publish-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("publish {0} start (dryRun={1}, noPush={2})" -f $runId, [bool]$DryRun, [bool]$NoPush)

$script:Result = [ordered]@{
  ok = $false; runId = $runId
  startedAt = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  durationMs = 0
  dryRun = [bool]$DryRun; noPush = [bool]$NoPush
  branch = $null; dir = $null; baseUrl = $null
  copied = @(); entries = @(); commit = $null; pushed = $false
  error = $null
}

function New-IsoNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Save-ResultAndExit([int]$Code) {
  $script:Result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
  if ($JsonOut) { Write-JoyJsonFile $JsonOut $script:Result }
  Write-JoyEvent @{ evt = 'result'; code = $Code; result = $script:Result }
  Write-JoyLog ("publish finished code={0} pushed={1} error={2}" -f $Code, $script:Result.pushed, $script:Result.error)
  exit $Code
}

function Fail-JoyPublish([int]$Code, [string]$Message, [string]$Hint = '') {
  $script:Result.ok = $false
  $script:Result.error = $Message
  if ($Hint) { Write-JoyLog $Hint 'WARN' }
  Write-JoyLog ("FAIL: {0}" -f $Message) 'ERROR'
  Save-ResultAndExit $Code
}

function Invoke-Git([string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & git -C $root @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return @{ code = $code; out = (($out | ForEach-Object { [string]$_ }) -join "`n").Trim() }
}

# ---------------------------------------------------------------- config
$gh = Get-JoyGhConfig
$pub = $null
if ($gh.PSObject.Properties.Name -contains 'publish') { $pub = $gh.publish }
if (-not $pub) { Fail-JoyPublish 2 'gh.json.publish missing' 'Add publish {repo, branch, dir, baseUrl}' }

$branch = 'main'
if ($pub.PSObject.Properties.Name -contains 'branch' -and $pub.branch) { $branch = [string]$pub.branch }
$dirName = 'docs'
if ($pub.PSObject.Properties.Name -contains 'dir' -and $pub.dir) { $dirName = [string]$pub.dir }
$baseUrl = ''
if ($pub.PSObject.Properties.Name -contains 'baseUrl' -and $pub.baseUrl) { $baseUrl = ([string]$pub.baseUrl).TrimEnd('/') }
$docsDir = Join-Path $root $dirName

$script:Result.branch = $branch
$script:Result.dir = $dirName
$script:Result.baseUrl = $baseUrl

if (-not (Test-Path -LiteralPath $docsDir)) {
  if ($DryRun) { Write-JoyLog ("dryRun: would create " + $docsDir) }
  else { New-Item -ItemType Directory -Force -Path $docsDir | Out-Null }
}
if (-not (Test-Path -LiteralPath $reportsDir)) { Fail-JoyPublish 1 'reports/ is empty; run render first' }

# ---------------------------------------------------------------- entries
$entries = Read-JoyJsonFile $idxPath
if (-not $entries) { Fail-JoyPublish 1 'reports-index.json missing; run render first' }
if ($entries -isnot [array]) { $entries = @($entries) }
$pending = @($entries | Where-Object { -not [bool]$_.published })

if ($pending.Count -eq 0) {
  Write-JoyLog 'nothing to publish (all entries marked published)'
  $script:Result.ok = $true
  Save-ResultAndExit 0
}

$files = @()
foreach ($e in $pending) {
  $src = Join-Path $reportsDir ([string]$e.file)
  if (-not (Test-Path -LiteralPath $src)) {
    Fail-JoyPublish 1 ('report file missing: ' + [string]$e.file) 'Run render again for this report'
  }
  $files += [string]$e.file
}
$files += 'latest.html'
$files += 'index.html'
$files = @($files | Select-Object -Unique)

$script:Result.entries = @($pending | ForEach-Object { [string]$_.file })
Write-JoyLog ("pending reports: {0}" -f ($files -join ', '))

# ---------------------------------------------------------------- dry run
if ($DryRun) {
  foreach ($f in $files) { Write-JoyLog ("dryRun: would copy reports\{0} -> {1}\{0}" -f $f, $dirName) }
  if (-not (Test-Path -LiteralPath (Join-Path $docsDir '.nojekyll'))) {
    Write-JoyLog 'dryRun: would create .nojekyll'
  }
  Write-JoyLog 'dryRun: would git add only these files, then commit and push'
  $script:Result.ok = $true
  Save-ResultAndExit 0
}

# ---------------------------------------------------------------- copy
foreach ($f in $files) {
  $src = Join-Path $reportsDir $f
  $dst = Join-Path $docsDir $f
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $script:Result.copied += $f
}
$nojekyll = Join-Path $docsDir '.nojekyll'
if (-not (Test-Path -LiteralPath $nojekyll)) {
  [IO.File]::WriteAllText($nojekyll, '', (New-Object Text.UTF8Encoding($false)))
  $script:Result.copied += '.nojekyll'
}
Write-JoyLog ("copied {0} file(s) to {1}" -f $script:Result.copied.Count, $dirName)

# ---------------------------------------------------------------- git
$r = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if ($r.code -ne 0) { Fail-JoyPublish 3 'not a git repository' 'Run from the GitHubJoy repo root' }

$hasRemote = $true
$r = Invoke-Git @('remote', 'get-url', 'origin')
if ($r.code -ne 0 -or -not $r.out) { $hasRemote = $false }

if ($hasRemote -and -not $NoPush) {
  $r = Invoke-Git @('fetch', 'origin')
  if ($r.code -ne 0) { Fail-JoyPublish 3 ('git fetch failed: ' + $r.out) 'Check network/proxy (RUNBOOK 6.11)' }

  $r = Invoke-Git @('rev-list', '--left-right', '--count', ("HEAD...origin/$branch"))
  if ($r.code -eq 0 -and $r.out) {
    $parts = @($r.out -split '\s+' | Where-Object { $_ })
    if ($parts.Count -ge 2) {
      $behind = [int]$parts[1]
      if ($behind -gt 0) {
        Fail-JoyPublish 3 ("local branch is behind origin/$branch by $behind commit(s)") 'Run git pull --rebase manually, then publish again'
      }
    }
  }
}

$addArgs = @('add', '--')
foreach ($f in $script:Result.copied) {
  $rel = ($dirName + '/' + $f) -replace '\\', '/'
  $addArgs += $rel
}
$r = Invoke-Git $addArgs
if ($r.code -ne 0) { Fail-JoyPublish 3 ('git add failed: ' + $r.out) }

$commit = $null
$r = Invoke-Git @('diff', '--cached', '--quiet')
if ($r.code -ne 0) {
  $total = 0
  foreach ($e in $pending) { $total += [int]$e.count }
  $msg = $Message
  if (-not $msg) { $msg = 'joy: ' + (Get-Date -Format 'yyyy-MM-dd') + ' n=' + $total }
  $r = Invoke-Git @('commit', '-m', $msg)
  if ($r.code -ne 0) { Fail-JoyPublish 3 ('git commit failed: ' + $r.out) 'Check git user.name/email' }
  $commit = (Invoke-Git @('rev-parse', '--short', 'HEAD')).out
  Write-JoyLog ("committed {0}: {1}" -f $commit, $msg)
} else {
  Write-JoyLog 'no staged changes; skip commit'
}
$script:Result.commit = $commit

# ---------------------------------------------------------------- push
if (-not $NoPush) {
  if (-not $hasRemote) { Fail-JoyPublish 3 'no git remote origin' 'Add remote or run with -NoPush' }
  $r = Invoke-Git @('push', 'origin', $branch)
  if ($r.code -ne 0) { Fail-JoyPublish 3 ('git push failed: ' + $r.out) 'Check permissions/branch protection' }
  $script:Result.pushed = $true
  Write-JoyLog ("pushed to origin/{0}" -f $branch)
} else {
  Write-JoyLog 'noPush: committed locally, not pushed'
}

# ------------------------------------------------- mark published (push only)
if ($script:Result.pushed) {
  $now = New-IsoNow
  $pendingNames = @{}
  foreach ($e in $pending) { $pendingNames[[string]$e.file] = $true }
  foreach ($e in $entries) {
    if ($pendingNames.ContainsKey([string]$e.file)) {
      $e.published = $true
      $e.pushedAt = $now
      if ($baseUrl) { $e.url = $baseUrl + '/' + [string]$e.file }
    }
  }
  Write-JoyJsonFile $idxPath $entries

  $queue = Read-JoyJsonFile $queuePath
  if ($queue -and $queue.PSObject.Properties.Name -contains 'items') {
    $map = @{}
    foreach ($q in @($queue.items)) { if ($q.id) { $map[([string]$q.id).ToLowerInvariant()] = $q } }
    foreach ($e in $pending) {
      if (-not ($e.PSObject.Properties.Name -contains 'ids')) { continue }
      foreach ($id in @($e.ids)) {
        $k = ([string]$id).ToLowerInvariant()
        if ($map.ContainsKey($k)) {
          $map[$k].published = $true
          $map[$k].publishedUrl = [string]$e.url
        }
      }
    }
    $queue.updatedAt = $now
    Write-JoyJsonFile $queuePath $queue
  }
  Write-JoyLog 'marked entries and queue items as published'
}

$script:Result.ok = $true
Save-ResultAndExit 0