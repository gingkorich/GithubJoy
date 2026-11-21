# GitHub Joy - cleanup: prune runtime artifacts by age (ASCII only, PS 5.1)
# Safe by design: never touches summaries/, reports-index.json, state.json,
# state/, queue.json, service.json, service-token, reports/.
param(
  [switch]$DryRun,
  [int]$JobDays = 0,
  [int]$LogDays = 0,
  [int]$TrendingDays = 0,
  [int]$KeepJobs = 0,
  [int]$MaterialDays = 0,
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
. (Join-Path $PSScriptRoot 'lib\lock.ps1')

$root = Get-JoyRoot
$dataDir = Join-Path $root 'data'
$jobsDir = Join-Path $dataDir 'jobs'
$logsDir = Join-Path $root 'logs'
$workDir = Join-Path $root '.work'
$matDir = Join-Path $dataDir 'materials'

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\cleanup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("cleanup start (dryRun={0})" -f [bool]$DryRun)

# config defaults (config.json retention section overrides)
$cfg = Get-JoyConfig
$cJobDays = 30; $cLogDays = 90; $cTrendDays = 90; $cKeepJobs = 20; $cMatDays = 30
if ($cfg -and $cfg.PSObject.Properties.Name -contains 'retention') {
  $rt = $cfg.retention
  if ($rt.PSObject.Properties.Name -contains 'jobDays') { $cJobDays = [int]$rt.jobDays }
  if ($rt.PSObject.Properties.Name -contains 'logDays') { $cLogDays = [int]$rt.logDays }
  if ($rt.PSObject.Properties.Name -contains 'trendingDays') { $cTrendDays = [int]$rt.trendingDays }
  if ($rt.PSObject.Properties.Name -contains 'keepJobs') { $cKeepJobs = [int]$rt.keepJobs }
  if ($rt.PSObject.Properties.Name -contains 'materialDays') { $cMatDays = [int]$rt.materialDays }
}
if ($JobDays -gt 0) { $cJobDays = $JobDays }
if ($LogDays -gt 0) { $cLogDays = $LogDays }
if ($TrendingDays -gt 0) { $cTrendDays = $TrendingDays }
if ($KeepJobs -gt 0) { $cKeepJobs = $KeepJobs }
if ($MaterialDays -gt 0) { $cMatDays = $MaterialDays }

$script:Result = [ordered]@{
  ok = $true; dryRun = [bool]$DryRun
  deleted = [ordered]@{ jobs = 0; ids = 0; logs = 0; trending = 0; work = 0; debug = 0; materials = 0 }
  bytes = 0; error = $null
}

$lock = Enter-JoyWorkflowLock -Kind 'cleanup'
if (-not $lock.ok) {
  $script:Result.ok = $false
  $script:Result.error = [string]$lock.error
  Write-JoyLog ("cleanup skipped: {0}" -f $lock.error) 'WARN'
  if ($JsonOut) { $script:Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut -Encoding UTF8 }
  exit 6
}

function Remove-JoyFile([string]$Path) {
  try {
    $size = 0
    $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
    $size = [int]$fi.Length
    if ($DryRun) {
      Write-JoyLog ("dryRun: would delete {0} ({1} bytes)" -f $Path, $size)
    } else {
      Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
      Write-JoyLog ("deleted {0} ({1} bytes)" -f $Path, $size)
    }
    $script:Result.bytes += $size
    return $true
  } catch {
    Write-JoyLog ("skip {0}: {1}" -f $Path, $_.Exception.Message) 'WARN'
    return $false
  }
}

$now = Get-Date

# 1) job files: older than jobDays, or beyond the newest keepJobs (json/result/txt count together)
if (Test-Path -LiteralPath $jobsDir) {
  $jobFiles = @(Get-ChildItem -LiteralPath $jobsDir -File | Sort-Object LastWriteTime -Descending)
  $idx = 0
  foreach ($f in $jobFiles) {
    $idx++
    $keepByCount = ($idx -le $cKeepJobs)
    $keepByAge = (($now - $f.LastWriteTime).TotalDays -lt $cJobDays)
    if ($keepByCount -and $keepByAge) { continue }
    if (Remove-JoyFile $f.FullName) {
      if ($f.Name -like 'ids-*') { $script:Result.deleted.ids++ } else { $script:Result.deleted.jobs++ }
    }
  }
}

# 2) logs: older than logDays (also covers *.out / *.err debug leftovers)
if (Test-Path -LiteralPath $logsDir) {
  foreach ($f in @(Get-ChildItem -LiteralPath $logsDir -File | Where-Object { ($now - $_.LastWriteTime).TotalDays -ge $cLogDays })) {
    if ($f.Name -like 'cleanup-*') { continue }  # never delete own log mid-run by age
    if (Remove-JoyFile $f.FullName) { $script:Result.deleted.logs++ }
  }
}

# 3) trending snapshots: older than trendingDays
foreach ($f in @(Get-ChildItem -LiteralPath $dataDir -File -Filter 'trending-*.json' -ErrorAction SilentlyContinue |
    Where-Object { ($now - $_.LastWriteTime).TotalDays -ge $cTrendDays })) {
  if (Remove-JoyFile $f.FullName) { $script:Result.deleted.trending++ }
}

# 4) .work/ scratch: older than jobDays
if (Test-Path -LiteralPath $workDir) {
  foreach ($f in @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue |
      Where-Object { ($now - $_.LastWriteTime).TotalDays -ge $cJobDays })) {
    if (Remove-JoyFile $f.FullName) { $script:Result.deleted.work++ }
  }
}

# 5) one-off debug artifacts: always removable (dry-run outputs, pre-queue backups, raw llm dumps)
foreach ($pattern in @('dry*.json', 'scan-real*.json', 'queue.before-clear-*.json', 'last-llm-raw.txt')) {
  foreach ($f in @(Get-ChildItem -LiteralPath $dataDir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
    if (Remove-JoyFile $f.FullName) { $script:Result.deleted.debug++ }
  }
}

# 6) materials cache: older than materialDays (read-side TTL is 24h anyway,
#    older copies are dead weight)
if (Test-Path -LiteralPath $matDir) {
  foreach ($f in @(Get-ChildItem -LiteralPath $matDir -File -ErrorAction SilentlyContinue |
      Where-Object { ($now - $_.LastWriteTime).TotalDays -ge $cMatDays })) {
    if (Remove-JoyFile $f.FullName) { $script:Result.deleted.materials++ }
  }
}

$total = $script:Result.deleted.jobs + $script:Result.deleted.ids + $script:Result.deleted.logs +
  $script:Result.deleted.trending + $script:Result.deleted.work + $script:Result.deleted.debug +
  $script:Result.deleted.materials
Write-JoyLog ("summary: removed {0} file(s), {1} bytes (jobs={2}, ids={3}, logs={4}, trending={5}, work={6}, debug={7}, materials={8})" -f `
  $total, $script:Result.bytes, $script:Result.deleted.jobs, $script:Result.deleted.ids, $script:Result.deleted.logs, `
  $script:Result.deleted.trending, $script:Result.deleted.work, $script:Result.deleted.debug, $script:Result.deleted.materials)

if ($JsonOut) {
  $script:Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
}
Exit-JoyWorkflowLock
exit 0
