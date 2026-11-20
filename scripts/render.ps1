# GitHub Joy - render: summaries -> self-contained HTML (M4a, no publish)
# ASCII only (PowerShell 5.1).
param(
  [int]$N = 0,
  [string]$OnlyId = '',
  [string]$IdsFile = '',
  [string]$RunId = '',
  [string]$OutDir = '',
  [switch]$NoIndex,
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
$sumDir = Join-Path $dataDir 'summaries'
$L = Read-JoyJsonFile (Join-Path $root 'templates\labels.json')
if (-not $OutDir) { $OutDir = Join-Path $root 'reports' }
$runTag = 'render-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$started = Get-Date

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\render-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("render {0} start (N={1}, runId={2}, out={3})" -f $runTag, $N, $RunId, $OutDir)

$script:Result = [ordered]@{
  ok = $false; runId = $runTag
  startedAt = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  durationMs = 0; count = 0; qaTotal = 0
  file = $null; latest = $null; indexFile = $null
  skipped = @(); error = $null
}

function New-IsoNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Save-ResultAndExit([int]$Code) {
  $script:Result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
  if ($JsonOut) { Write-JoyJsonFile $JsonOut $script:Result }
  Write-JoyEvent @{ evt = 'result'; code = $Code; result = $script:Result }
  Write-JoyLog ("render finished code={0} count={1} file={2}" -f $Code, $script:Result.count, $script:Result.file)
  exit $Code
}

function Fail-JoyRender([int]$Code, [string]$Message) {
  $script:Result.ok = $false; $script:Result.error = $Message
  Write-JoyLog ("FAIL: {0}" -f $Message) 'ERROR'
  Save-ResultAndExit $Code
}

function Write-JoyTextFile([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-JoyHtml([string]$s) {
  if ($null -eq $s) { return '' }
  $t = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' `
    -replace '"', '&quot;' -replace "'", '&#39;'
  $t = $t -replace "`r`n", '<br>' -replace "`n", '<br>'
  return $t
}

function ConvertTo-JoyList($arr) {
  $items = @($arr | Where-Object { $_ -ne $null -and ([string]$_).Trim() -ne '' })
  if ($items.Count -eq 0) { return '<span class="muted">&mdash;</span>' }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('<ul>')
  foreach ($x in $items) { [void]$sb.Append('<li>' + (ConvertTo-JoyHtml ([string]$x)) + '</li>') }
  [void]$sb.Append('</ul>')
  return $sb.ToString()
}

function Get-RepoUrl([string]$FullName) {
  $u = 'https://github.com/' + $FullName
  if ($u -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return 'https://github.com' }
  return $u
}

# ---------------------------------------------------------------- select
$queue = Read-JoyJsonFile (Join-Path $dataDir 'queue.json')
$items = @()
if ($queue -and $queue.PSObject.Properties.Name -contains 'items') { $items = @($queue.items) }

function Get-SummaryPath([string]$FullName) {
  $p = $FullName -split '/', 2
  return (Join-Path $sumDir (($p[0] + '__' + $p[1]).ToLowerInvariant() + '.json'))
}

$candidates = @()
if ($OnlyId -or $IdsFile) {
  $ids = @()
  if ($OnlyId) { $ids += $OnlyId.Trim() }
  if ($IdsFile) {
    if (-not (Test-Path -LiteralPath $IdsFile)) { Fail-JoyRender 2 ("ids file not found: " + $IdsFile) }
    $ids += @([IO.File]::ReadAllLines($IdsFile, [Text.Encoding]::UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  foreach ($key in $ids) {
    $hit = $items | Where-Object {
      ([string]$_.id).ToLowerInvariant() -eq $key.ToLowerInvariant() -or
      ([string]$_.fullName).ToLowerInvariant() -eq $key.ToLowerInvariant()
    } | Select-Object -First 1
    if ($hit) { $candidates += $hit; continue }
    if ($key -match '/') {
      $path = Get-SummaryPath $key
      if (Test-Path -LiteralPath $path) {
        $candidates += [pscustomobject]@{ id = $key.ToLowerInvariant(); fullName = $key; summaryPath = $path; repo = $null }
      }
    }
  }
} elseif ($RunId) {
  $candidates = @()
  foreach ($sf in @(Get-ChildItem -LiteralPath $sumDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $tmp = Read-JoyJsonFile $sf.FullName
    if ($tmp -and [string]$tmp.readRunId -eq $RunId) {
      $candidates += [pscustomobject]@{ id = [string]$tmp.id; fullName = [string]$tmp.fullName; summaryPath = $sf.FullName; repo = $null }
    }
  }
} else {
  $take = $N
  if ($take -le 0) { $take = 5 }
  $files = @(Get-ChildItem -LiteralPath $sumDir -Filter '*.json' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First $take)
  $candidates = @()
  foreach ($sf in $files) {
    $tmp = Read-JoyJsonFile $sf.FullName
    if ($tmp -and $tmp.fullName) {
      $candidates += [pscustomobject]@{ id = [string]$tmp.id; fullName = [string]$tmp.fullName; summaryPath = $sf.FullName; repo = $null }
    }
  }
}

$selected = @()
foreach ($it in $candidates) {
  $path = [string]$it.summaryPath
  if (-not $path) { $path = Get-SummaryPath ([string]$it.fullName) }
  if (-not (Test-Path -LiteralPath $path)) {
    $script:Result.skipped += [ordered]@{ id = $it.id; reason = 'summary_missing'; path = $path }
    continue
  }
  $sum = Read-JoyJsonFile $path
  if (-not $sum -or -not ($sum.PSObject.Properties.Name -contains 'overview') -or -not $sum.overview) {
    $script:Result.skipped += [ordered]@{ id = $it.id; reason = 'summary_invalid'; path = $path }
    continue
  }
  $selected += [pscustomobject]@{ item = $it; summary = $sum; path = $path }
}

if ($selected.Count -eq 0) {
  Fail-JoyRender 1 'no renderable summaries (run read first, or check -OnlyId/-RunId)'
}
Write-JoyLog ("selected {0} summary item(s)" -f $selected.Count)

# ---------------------------------------------------------------- build html
$cards = New-Object Text.StringBuilder
$qaTotal = 0
$modes = @{}

foreach ($sel in $selected) {
  $s = $sel.summary
  $full = [string]$s.fullName
  if (-not $full) { $full = [string]$sel.item.fullName }
  $url = Get-RepoUrl $full
  $mode = [string]$s.mode
  if (-not $mode) { $mode = 'deep' }
  if ($modes.ContainsKey($mode)) { $modes[$mode]++ } else { $modes[$mode] = 1 }
  $qa = @($s.qa)
  $qaTotal += $qa.Count

  [void]$cards.Append('<article class="card">')
  [void]$cards.Append('<h2><a href="' + $url + '" target="_blank" rel="noopener">' + (ConvertTo-JoyHtml $full) + '</a>')
  $stars = 0
  if ($s.PSObject.Properties.Name -contains 'stars') { $stars = [int]$s.stars }
  $starsText = '{0:N0}' -f $stars
  [void]$cards.Append('<span class="tag">&#9733; ' + $starsText + '</span>')
  [void]$cards.Append('</h2>')
  [void]$cards.Append('<p class="overview">' + (ConvertTo-JoyHtml ([string]$s.overview)) + '</p>')

  if ($qa.Count -gt 0) {
    [void]$cards.Append('<section class="qa"><h3>' + $L.qaTitle + '</h3>')
    $qi = 0
    foreach ($q in $qa) {
      $qi++
      $open = ''
      if ($qi -eq 1) { $open = ' open' }
      [void]$cards.Append('<details' + $open + '><summary>Q' + $qi + ' &middot; ' + (ConvertTo-JoyHtml ([string]$q.q)) + '</summary>')
      [void]$cards.Append('<p>' + (ConvertTo-JoyHtml ([string]$q.a)) + '</p>')
      $refs = @($q.refs | Where-Object { $_ })
      if ($refs.Count -gt 0) {
        $refHtml = (($refs | ForEach-Object { '<code>' + (ConvertTo-JoyHtml ([string]$_)) + '</code>' }) -join ' ')
        [void]$cards.Append('<p class="refs">' + $L.refsPrefix + $refHtml + '</p>')
      }
      [void]$cards.Append('</details>')
    }
    [void]$cards.Append('</section>')
  }

  $warn = @($s.warnings | Where-Object { $_ })
  if ($warn.Count -gt 0) {
    [void]$cards.Append('<p class="warn">' + $L.warnPrefix + (ConvertTo-JoyHtml ($warn -join '; ')) + '</p>')
  }
  [void]$cards.Append('</article>')
}

$now = Get-Date
$dateStr = $now.ToString('yyyy-MM-dd')
$modeText = (($modes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
$statsText = $L.statsTpl.Replace('{count}', [string]$selected.Count).Replace('{qa}', [string]$qaTotal).Replace('{modes}', $modeText).Replace('{time}', $now.ToString('yyyy-MM-dd HH:mm'))

$tpl = [IO.File]::ReadAllText((Join-Path $root 'templates\report.html.tpl'), [Text.Encoding]::UTF8)
$html = $tpl.Replace('{{TITLE}}', (ConvertTo-JoyHtml ($L.reportTitleTpl.Replace('{date}', $dateStr))))
$html = $html.Replace('{{SUBTITLE}}', (ConvertTo-JoyHtml ($L.reportSubtitleTpl.Replace('{count}', [string]$selected.Count).Replace('{qa}', [string]$qaTotal))))
$html = $html.Replace('{{STATS}}', (ConvertTo-JoyHtml $statsText))
$html = $html.Replace('{{CARDS}}', $cards.ToString())
$html = $html.Replace('{{FAILED}}', '')
$footer = $L.footerTpl.Replace('{runId}', $runTag)
$html = $html.Replace('{{FOOTER}}', (ConvertTo-JoyHtml $footer))

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$stamp = $now.ToString('yyyyMMddHHmmss')
$file = Join-Path $OutDir ($stamp + '.html')
$seq = 1
while (Test-Path -LiteralPath $file) {
  $file = Join-Path $OutDir ($stamp + '-' + $seq + '.html')
  $seq++
}
Write-JoyTextFile $file $html
$latest = Join-Path $OutDir 'latest.html'
Copy-Item -LiteralPath $file -Destination $latest -Force
$script:Result.file = $file
$script:Result.latest = $latest
$script:Result.count = $selected.Count
$script:Result.qaTotal = $qaTotal
Write-JoyLog ("report written: {0}" -f $file)

# ---------------------------------------------------------------- index
if (-not $NoIndex) {
  $idxPath = Join-Path $dataDir 'reports-index.json'
  $entries = Read-JoyJsonFile $idxPath
  if (-not $entries) { $entries = @() }
  if ($entries -isnot [array]) { $entries = @($entries) }

  $name = Split-Path -Leaf $file
  $entry = [ordered]@{
    file = $name; date = $dateStr; count = $selected.Count; qa = $qaTotal
    ids = @($selected | ForEach-Object { [string]$_.summary.id })
    createdAt = (New-IsoNow); published = $false; url = ''
  }
  $entries = @($entry) + @($entries | Where-Object { [string]$_.file -ne $name })
  Write-JoyJsonFile $idxPath $entries

  $sorted = @($entries | Sort-Object { [string]$_.createdAt } -Descending)

  $idxTpl = [IO.File]::ReadAllText((Join-Path $root 'templates\index.html.tpl'), [Text.Encoding]::UTF8)

  # two outputs: reports/index.html (links relative to itself) and the repo-root
  # index.html (links prefixed with 'reports/', serves as the Pages homepage).
  foreach ($prefix in @('', 'reports/')) {
    $rows = New-Object Text.StringBuilder
    if ($prefix) {
      [void]$rows.Append('<tr><td><a href="reports/latest.html">' + (ConvertTo-JoyHtml ([string]$L.latestFile)) + '</a> <span class="muted">(' + (ConvertTo-JoyHtml ([string]$L.latestLabel)) + ')</span></td><td>&mdash;</td><td>&mdash;</td></tr>')
    }
    foreach ($e in $sorted) {
      $when = [string]$e.createdAt
      try { $when = ([datetime]$e.createdAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
      [void]$rows.Append('<tr><td><a href="' + (ConvertTo-JoyHtml ($prefix + [string]$e.file)) + '">' + (ConvertTo-JoyHtml ([string]$e.file)) + '</a></td>')
      [void]$rows.Append('<td>' + [int]$e.count + '</td>')
      [void]$rows.Append('<td>' + (ConvertTo-JoyHtml $when) + '</td></tr>')
    }
    $idxHtml = $idxTpl.Replace('{{TITLE}}', (ConvertTo-JoyHtml $L.indexTitle))
    $idxHtml = $idxHtml.Replace('{{SUBTITLE}}', (ConvertTo-JoyHtml $L.indexSubtitle))
    $idxHtml = $idxHtml.Replace('{{ROWS}}', $rows.ToString())
    $idxHtml = $idxHtml.Replace('{{FOOTER}}', (ConvertTo-JoyHtml ($L.indexFooterTpl.Replace('{count}', [string]$sorted.Count))))
    if ($prefix) {
      $idxFile = Join-Path $root 'index.html'
    } else {
      $idxFile = Join-Path $OutDir 'index.html'
      $script:Result.indexFile = $idxFile
    }
    Write-JoyTextFile $idxFile $idxHtml
    Write-JoyLog ("index written: {0}" -f $idxFile)
  }
  $script:Result.rootIndexFile = Join-Path $root 'index.html'
}

$script:Result.ok = $true
Write-JoyEvent @{ evt = 'progress'; phase = 'done'; done = $selected.Count; total = $selected.Count }
Save-ResultAndExit 0