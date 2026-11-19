# GitHub Joy - read: select queue items, fetch materials, summarize with LLM
# ASCII only (PowerShell 5.1). No publish/migrate in M3b.
param(
  [int]$N = 0,
  [string]$OnlyId = '',
  [string]$IdsFile = '',
  [switch]$Force,
  [switch]$Lite,
  [switch]$DryRun,
  [switch]$NoWrite,
  [switch]$NoLlm,
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
. (Join-Path $PSScriptRoot 'lib\llm.ps1')

$root = Get-JoyRoot
$dataDir = Join-Path $root 'data'
$sumDir = Join-Path $dataDir 'summaries'
$runId = 'read-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$started = Get-Date
if (-not (Test-Path -LiteralPath $sumDir)) { New-Item -ItemType Directory -Force -Path $sumDir | Out-Null }

if (-not $LogFile) { $LogFile = Join-Path $root ('logs\read-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
Initialize-JoyLog $LogFile
Write-JoyLog ("read {0} start (dryRun={1}, noWrite={2}, noLlm={3}, lite={4})" -f $runId, [bool]$DryRun, [bool]$NoWrite, [bool]$NoLlm, [bool]$Lite)
Write-JoyEvent @{ evt = 'progress'; phase = 'start'; done = 0; total = 0 }

$script:Result = [ordered]@{
  ok = $false; runId = $runId
  startedAt = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  durationMs = 0
  dryRun = [bool]$DryRun; noWrite = [bool]$NoWrite; noLlm = [bool]$NoLlm
  mode = $(if ($Lite) { 'lite' } else { 'deep' })
  selected = 0; succeeded = 0; failed = 0; skipped = 0
  created = 0; selectionSource = 'queue'; unreadTotal = 0
  items = @()
  llm = [ordered]@{ model = $null; calls = 0 }
  error = $null; hint = $null
}

function New-IsoNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-QueuePath { Join-Path $dataDir 'queue.json' }
function Get-StatePath { Join-Path $dataDir 'state.json' }

function Save-ResultAndExit([int]$Code) {
  $script:Result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
  if ($JsonOut) { Write-JoyJsonFile $JsonOut $script:Result }
  Write-JoyEvent @{ evt = 'result'; code = $Code; result = $script:Result }
  Write-JoyLog ("read finished code={0} ok={1} succeeded={2} failed={3}" -f $Code, $script:Result.ok, $script:Result.succeeded, $script:Result.failed)
  exit $Code
}

function Fail-JoyRead([int]$Code, [string]$Message, [string]$Hint = '') {
  $script:Result.ok = $false
  $script:Result.error = $Message
  $script:Result.hint = $Hint
  Write-JoyLog ("FAIL: {0}" -f $Message) 'ERROR'
  Save-ResultAndExit $Code
}

function Save-Queue($Queue) {
  if ($NoWrite -or $DryRun) { return }
  $Queue.updatedAt = (New-IsoNow)
  Write-JoyJsonFile (Get-QueuePath) $Queue
}

$cfg = Get-JoyConfig
$proxy = Get-JoyProxy
Use-JoyProxy $proxy
$tok = Get-JoyTokenInfo -Proxy $proxy
if (-not $tok.value) { Fail-JoyRead 2 'no GitHub token' 'Run gh auth login or set gh.json.token' }
$token = $tok.value
Write-JoyLog ("token source={0} proxy={1}" -f $tok.source, $(if ($proxy) { $proxy } else { 'none' }))

$readCfg = $null
if ($cfg.PSObject.Properties.Name -contains 'read') { $readCfg = $cfg.read }
$defaultN = 5; $maxN = 20; $deepMode = $true
$readmeMax = 20000; $treeMax = 200; $keyMin = 3; $keyMax = 5; $keyFileMax = 8000
if ($readCfg) {
  if ($readCfg.PSObject.Properties.Name -contains 'defaultN') { $defaultN = [int]$readCfg.defaultN }
  if ($readCfg.PSObject.Properties.Name -contains 'maxN') { $maxN = [int]$readCfg.maxN }
  if ($readCfg.PSObject.Properties.Name -contains 'deepMode') { $deepMode = [bool]$readCfg.deepMode }
  if ($readCfg.PSObject.Properties.Name -contains 'readmeMaxChars') { $readmeMax = [int]$readCfg.readmeMaxChars }
  if ($readCfg.PSObject.Properties.Name -contains 'treeMaxEntries') { $treeMax = [int]$readCfg.treeMaxEntries }
  if ($readCfg.PSObject.Properties.Name -contains 'keyFilesMin') { $keyMin = [int]$readCfg.keyFilesMin }
  if ($readCfg.PSObject.Properties.Name -contains 'keyFilesMax') { $keyMax = [int]$readCfg.keyFilesMax }
  if ($readCfg.PSObject.Properties.Name -contains 'keyFileMaxChars') { $keyFileMax = [int]$readCfg.keyFileMaxChars }
}
if ($Lite) { $deepMode = $false }
$script:Result.mode = $(if ($deepMode) { 'deep' } else { 'lite' })

$llm = $null
if (-not $NoLlm) {
  $llm = Get-JoyLlmConfig
  if (-not $llm) { Fail-JoyRead 2 'llm.json missing or incomplete' 'Fill base_url/model/api_key in the console model card' }
  $script:Result.llm.model = $llm.Model
}

# ---------------------------------------------------------------- select (unread List is the source of truth)
$queue = Read-JoyJsonFile (Get-QueuePath)
if (-not $queue -or -not ($queue.PSObject.Properties.Name -contains 'items')) {
  $queue = [pscustomobject][ordered]@{ version = 1; updatedAt = (New-IsoNow); seq = 0; items = @() }
}
$queue.items = @($queue.items)

# reset items left in summarizing by a cancelled/interrupted run
$stale = @($queue.items | Where-Object { [string]$_.status -eq 'summarizing' })
if ($stale.Count -gt 0) {
  foreach ($it in $stale) { $it.status = 'pending'; $it.lastError = 'interrupted' }
  Save-Queue $queue
  Write-JoyLog ("reset {0} interrupted item(s) to pending" -f $stale.Count) 'WARN'
}

$listsRes = Get-JoyLists -Token $token -Proxy $proxy
if (-not $listsRes.ok) { Fail-JoyRead 2 ('cannot read Lists: ' + [string]$listsRes.error) 'Check the user scope (RUNBOOK 6.5)' }
$names = Get-JoyListNames
$unread = $listsRes.lists | Where-Object { ([string]$_.name).ToLowerInvariant() -eq ([string]$names.unread).ToLowerInvariant() } | Select-Object -First 1
if (-not $unread) { Fail-JoyRead 2 'unread List not found' 'Run scan first' }

$listRes = Get-JoyListItemsDetailed -Token $token -ListId ([string]$unread.id) -Proxy $proxy -Max 300
if (-not $listRes.ok) { Fail-JoyRead 2 ('cannot read unread items: ' + [string]$listRes.error) }
$listItems = @($listRes.items)
$script:Result.unreadTotal = $listItems.Count
$script:Result.selectionSource = 'unread-list'
Write-JoyLog ("unread List has {0} item(s)" -f $listItems.Count)

$queueIndex = @{}
foreach ($q in $queue.items) { if ($q.id) { $queueIndex[([string]$q.id).ToLowerInvariant()] = $q } }

$ids = @()
if ($OnlyId) { $ids += $OnlyId.Trim().ToLowerInvariant() }
if ($IdsFile) {
  if (-not (Test-Path -LiteralPath $IdsFile)) { Fail-JoyRead 2 ("ids file not found: " + $IdsFile) }
  $ids += @([IO.File]::ReadAllLines($IdsFile, [Text.Encoding]::UTF8) |
      ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

$wantN = $N
if ($wantN -le 0) { $wantN = $defaultN }
if ($wantN -gt $maxN) { $wantN = $maxN }

$selected = @()
$seq = [int]$queue.seq
$created = 0

foreach ($li in $listItems) {
  $key = ([string]$li.fullName).ToLowerInvariant()
  if ($ids.Count -gt 0) {
    if (-not ($ids -contains $key)) { continue }
  } elseif ($selected.Count -ge $wantN) {
    break
  }

  $existing = $null
  if ($queueIndex.ContainsKey($key)) { $existing = $queueIndex[$key] }

  if ($existing) {
    if ([string]$existing.status -in @('moved', 'gone')) { continue }
    if (-not $Force -and [string]$existing.status -eq 'done' -and $existing.summaryPath -and (Test-Path -LiteralPath ([string]$existing.summaryPath))) {
      $script:Result.skipped++
      Write-JoyLog ("skip existing summary: {0}" -f $li.fullName)
      continue
    }
  }

  if (-not $existing) {
    $seq++
    $existing = [pscustomobject][ordered]@{
      id = $key
      fullName = [string]$li.fullName
      seq = $seq
      status = 'pending'
      addedAt = (New-IsoNow)
      scannedFrom = @()
      repo = [pscustomobject]@{
        nodeId = [string]$li.id; description = [string]$li.description
        language = [string]$li.language; stars = [int]$li.stars; forks = 0
        topics = @(); archived = [bool]$li.archived; pushedAt = [string]$li.pushedAt
      }
      list = [pscustomobject]@{ inUnread = $true; inRead = $false; otherListIds = @() }
      starred = $true
      starSkipped = $null
      attempts = 0
      lastError = $null
      summaryPath = $null
      published = $false
      publishedUrl = $null
      movedAt = $null
    }
    $queue.items = @($queue.items) + $existing
    $queueIndex[$key] = $existing
    $created++
  } else {
    if ($existing.repo) {
      if (-not $existing.repo.nodeId) { $existing.repo.nodeId = [string]$li.id }
      $existing.repo.stars = [int]$li.stars
      if (-not $existing.repo.description) { $existing.repo.description = [string]$li.description }
      if (-not $existing.repo.language) { $existing.repo.language = [string]$li.language }
    }
    if ($existing.list) { $existing.list.inUnread = $true }
  }
  $selected += $existing
}

$queue.seq = $seq
if ($created -gt 0) {
  Write-JoyLog ("mirrored {0} unread item(s) into queue" -f $created)
  Save-Queue $queue
}
$script:Result.created = $created

if ($ids.Count -gt 0 -and $selected.Count -eq 0) {
  Fail-JoyRead 2 'none of the requested ids are in the unread List' 'Check the id or the List name in gh.json'
}
$wanted = @($selected)

if ($wanted.Count -eq 0) {
  Write-JoyLog 'no items selected' 'WARN'
  $script:Result.ok = $true
  Save-ResultAndExit 0
}
$script:Result.selected = $wanted.Count
Write-JoyLog ("selected {0}: {1}" -f $wanted.Count, (($wanted | ForEach-Object { $_.fullName }) -join ', '))
Write-JoyEvent @{ evt = 'progress'; phase = 'select'; done = 1; total = 1 }

if ($DryRun) {
  foreach ($it in $wanted) { Write-JoyLog ("dryRun: would read {0} (status={1})" -f $it.fullName, $it.status) }
  $script:Result.ok = $true
  Save-ResultAndExit 0
}

# ---------------------------------------------------------------- helpers
function Get-JoyRawHeaders([string]$Token) {
  $h = New-JoyApiHeaders $Token
  $h['Accept'] = 'application/vnd.github.raw'
  return $h
}

function Get-JoyRepoMeta([string]$FullName, [string]$Token, [string]$Proxy) {
  $r = Invoke-JoyHttp -Uri ("https://api.github.com/repos/" + $FullName) -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; status = $r.status; error = $r.error; body = $r.body } }
  try { return @{ ok = $true; data = ($r.body | ConvertFrom-Json) } }
  catch { return @{ ok = $false; status = $r.status; error = 'meta_json_parse_failed'; body = $r.body } }
}

function Get-JoyReadme([string]$FullName, [string]$Token, [string]$Proxy, [int]$MaxChars) {
  $r = Invoke-JoyHttp -Uri ("https://api.github.com/repos/$FullName/readme") -Headers (Get-JoyRawHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; status = $r.status; error = $r.error } }
  $text = [string]$r.body
  $truncated = $false
  if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars); $truncated = $true }
  return @{ ok = $true; text = $text; truncated = $truncated; chars = $text.Length }
}

function Get-JoyTree([string]$FullName, [string]$Branch, [string]$Token, [string]$Proxy, [int]$MaxEntries) {
  $uri = "https://api.github.com/repos/$FullName/git/trees/$Branch" + '?recursive=1'
  $r = Invoke-JoyHttp -Uri $uri -Headers (New-JoyApiHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; status = $r.status; error = $r.error; paths = @() } }
  $paths = New-Object System.Collections.Generic.List[string]
  try {
    $obj = $r.body | ConvertFrom-Json
    foreach ($n in @($obj.tree)) {
      if ($null -eq $n -or [string]$n.type -ne 'blob') { continue }
      $p = [string]$n.path
      if (-not $p) { continue }
      if ($p -match '(^|/)(node_modules|dist|build|vendor|\.git|assets|images|img|fonts)/') { continue }
      if ($p -match '\.(png|jpg|jpeg|gif|svg|ico|webp|woff2?|ttf|otf|zip|gz|7z|pdf|exe|dll|so|dylib)$') { continue }
      $paths.Add($p)
      if ($paths.Count -ge $MaxEntries) { break }
    }
  } catch {
    return @{ ok = $false; status = $r.status; error = 'tree_json_parse_failed'; paths = @() }
  }
  return @{ ok = $true; paths = $paths.ToArray(); truncated = ($paths.Count -ge $MaxEntries) }
}

function Get-JoyFileText([string]$FullName, [string]$Path, [string]$Token, [string]$Proxy, [int]$MaxChars) {
  $enc = (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
  $uri = "https://api.github.com/repos/$FullName/contents/$enc"
  $r = Invoke-JoyHttp -Uri $uri -Headers (Get-JoyRawHeaders $Token) -Proxy $Proxy
  if (-not $r.ok) { return @{ ok = $false; status = $r.status; error = $r.error } }
  $text = [string]$r.body
  $truncated = $false
  if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars); $truncated = $true }
  return @{ ok = $true; text = $text; truncated = $truncated; chars = $text.Length }
}

function Select-JoyKeyFiles($Paths, [string]$Readme, [int]$Max) {
  if ($Max -le 0 -or -not $Paths) { return @() }
  $scored = @()
  foreach ($p in @($Paths)) {
    $leaf = ([string]$p -split '/')[-1].ToLowerInvariant()
    if ($leaf -match '^readme(\..*)?$') { continue }
    if ($leaf -match '\.(lock|sum)$') { continue }
    $score = 0
    if ($leaf -match '^(main|index|app|cli|server|run|start|worker|bot)\.[A-Za-z0-9]+$') { $score += 3 }
    if ($leaf -in @('package.json', 'pyproject.toml', 'cargo.toml', 'go.mod', 'makefile', 'dockerfile', 'docker-compose.yml', 'requirements.txt', 'pom.xml', 'build.gradle', 'cmakelists.txt', 'setup.py', 'composer.json')) { $score += 2 }
    if ($Readme -and $Readme.Contains([string]$p)) { $score += 2 }
    if ($p -match '^(src|lib|app|internal|pkg)/' -and (($p -split '/').Count -le 4)) { $score += 1 }
    if ($p -match '(^|/)(tests?|spec|docs?|examples?|samples?|benchmarks?)/') { $score -= 5 }
    $scored += [pscustomobject]@{ path = [string]$p; score = $score }
  }
  return @($scored | Sort-Object score -Descending | Select-Object -First $Max | ForEach-Object { $_.path })
}

function New-JoyUserPrompt($Meta, [string]$FullName, [string]$ReadmeText, [string]$TreeText, [string]$FilesBlock, [string]$Mode) {
  $tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'prompts\summarize.user.tpl'), [Text.Encoding]::UTF8)
  $desc = ''; $lang = ''; $lic = ''; $stars = 0; $pushed = ''; $branch = ''
  if ($Meta) {
    $desc = [string]$Meta.description
    $lang = [string]$Meta.language
    $stars = [int]$Meta.stargazers_count
    if ($Meta.license -and $Meta.license.spdx_id) { $lic = [string]$Meta.license.spdx_id }
    $pushed = [string]$Meta.pushed_at
    $branch = [string]$Meta.default_branch
  }
  $t = $tpl
  $t = $t.Replace('{{FULL_NAME}}', $FullName)
  $t = $t.Replace('{{DESCRIPTION}}', $desc)
  $t = $t.Replace('{{LANGUAGE}}', $lang)
  $t = $t.Replace('{{STARS}}', [string]$stars)
  $t = $t.Replace('{{LICENSE}}', $lic)
  $t = $t.Replace('{{PUSHED_AT}}', $pushed)
  $t = $t.Replace('{{BRANCH}}', $branch)
  $t = $t.Replace('{{MODE}}', $Mode)
  $t = $t.Replace('{{README}}', $ReadmeText)
  $t = $t.Replace('{{TREE}}', $TreeText)
  $t = $t.Replace('{{FILES_BLOCK}}', $FilesBlock)
  return $t
}

function Test-JoySummary($Obj, [string[]]$AllowedPaths) {
  $errors = @()
  $warnings = @()

  $overview = ''
  if ($Obj.PSObject.Properties.Name -contains 'overview') { $overview = ([string]$Obj.overview).Trim() }
  if (-not $overview) {
    $errors += 'overview missing'
  } else {
    $len = $overview.Length
    if ($len -lt 80 -or $len -gt 150) { $warnings += ("overview length " + $len) }
  }

  $allowed = @{}
  foreach ($p in @($AllowedPaths)) { if ($p) { $allowed[([string]$p).ToLowerInvariant()] = $true } }

  $qaOut = @()
  $qa = @()
  if ($Obj.PSObject.Properties.Name -contains 'qa') { $qa = @($Obj.qa) }
  if ($qa.Count -lt 3) { $errors += ("qa count " + $qa.Count + ' < 3') }
  if ($qa.Count -gt 6) { $warnings += ("qa count " + $qa.Count + ' > 6 (trimmed)') }
  foreach ($item in $qa) {
    if ($qaOut.Count -ge 6) { break }
    if ($null -eq $item) { continue }
    $q = ''; $a = ''
    if ($item.PSObject.Properties.Name -contains 'q') { $q = ([string]$item.q).Trim() }
    if ($item.PSObject.Properties.Name -contains 'a') { $a = ([string]$item.a).Trim() }
    if (-not $q -or -not $a) { $warnings += 'qa item missing q/a'; continue }
    $refs = @()
    if ($item.PSObject.Properties.Name -contains 'refs') {
      foreach ($rf in @($item.refs)) {
        $k = ([string]$rf).Trim()
        if (-not $k) { continue }
        if ($allowed.ContainsKey($k.ToLowerInvariant())) { $refs += $k }
        else { $warnings += ('ref not in sources: ' + $k) }
      }
    }
    $qaOut += [pscustomobject]@{ q = $q; a = $a; refs = $refs }
  }
  if ($qaOut.Count -lt 3) { $errors += ('valid qa count ' + $qaOut.Count + ' < 3') }

  $stack = [ordered]@{ language = ''; frameworks = @(); build = '' }
  if ($Obj.PSObject.Properties.Name -contains 'stack' -and $Obj.stack) {
    if ($Obj.stack.PSObject.Properties.Name -contains 'language') { $stack.language = [string]$Obj.stack.language }
    if ($Obj.stack.PSObject.Properties.Name -contains 'frameworks') { $stack.frameworks = @($Obj.stack.frameworks) }
    if ($Obj.stack.PSObject.Properties.Name -contains 'build') { $stack.build = [string]$Obj.stack.build }
  }
  $useCases = @()
  if ($Obj.PSObject.Properties.Name -contains 'useCases') { $useCases = @($Obj.useCases) }
  $risks = @()
  if ($Obj.PSObject.Properties.Name -contains 'risks') { $risks = @($Obj.risks) }

  $bad = @()
  $clichePath = Join-Path $PSScriptRoot 'prompts\cliches.txt'
  if (Test-Path -LiteralPath $clichePath) {
    $bad = @([IO.File]::ReadAllLines($clichePath, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
  }
  foreach ($b in $bad) {
    if ($overview -match [regex]::Escape($b)) { $warnings += ('cliche: ' + $b) }
  }

  $normalized = [ordered]@{
    overview = $overview
    qa = $qaOut
    stack = $stack
    useCases = $useCases
    risks = $risks
  }
  return @{ ok = ($errors.Count -eq 0); errors = $errors; warnings = $warnings; obj = $normalized }
}

# ---------------------------------------------------------------- main loop
$systemPrompt = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'prompts\summarize.system.txt'), [Text.Encoding]::UTF8)
$idx = 0
$itemsOut = @()

foreach ($item in $wanted) {
  $idx++
  $full = [string]$item.fullName
  $parts = $full -split '/', 2
  $owner = $parts[0]; $repo = $parts[1]
  $summaryPath = Join-Path $sumDir (($owner + '__' + $repo).ToLowerInvariant() + '.json')

  if (-not $Force -and -not $NoWrite -and [string]$item.status -eq 'done' -and (Test-Path -LiteralPath $summaryPath)) {
    $script:Result.skipped++
    $itemsOut += [ordered]@{ id = $item.id; status = 'skipped_existing'; summaryPath = $summaryPath; error = $null }
    Write-JoyLog ("skip existing summary: {0}" -f $full)
    continue
  }

  $entry = [ordered]@{
    id = $item.id; status = ''; summaryPath = $null
    overviewChars = 0; qaCount = 0
    materials = [ordered]@{ readmeChars = 0; treeEntries = 0; files = @() }
    error = $null; warnings = @()
  }

  try {
    if (-not $NoWrite -and -not $NoLlm) {
      $item.status = 'summarizing'
      $item.attempts = [int]$item.attempts + 1
      Save-Queue $queue
    }

    $meta = Get-JoyRepoMeta -FullName $full -Token $token -Proxy $proxy
    if (-not $meta.ok) {
      if ($meta.status -eq 404) {
        $item.status = 'gone'; $item.lastError = 'repo 404'
        Save-Queue $queue
        $entry.status = 'gone'; $entry.error = 'repo 404'
        $itemsOut += $entry
        $script:Result.failed++
        Write-JoyLog ("repo gone: {0}" -f $full) 'WARN'
        continue
      }
      throw ('meta HTTP ' + $meta.status + ': ' + [string]$meta.error)
    }
    $m = $meta.data
    $branch = [string]$m.default_branch
    if (-not $branch) { $branch = 'main' }

    $warnings = @()
    $sources = @()
    $readmeText = ''
    $readme = Get-JoyReadme -FullName $full -Token $token -Proxy $proxy -MaxChars $readmeMax
    if ($readme.ok) {
      $readmeText = [string]$readme.text
      $sources += [ordered]@{ path = 'README.md'; chars = [int]$readme.chars; truncated = [bool]$readme.truncated }
    } else {
      $warnings += ('no_readme (HTTP ' + $readme.status + ')')
    }

    $tree = Get-JoyTree -FullName $full -Branch $branch -Token $token -Proxy $proxy -MaxEntries $treeMax
    $paths = @()
    $treeText = ''
    if ($tree.ok) {
      $paths = @($tree.paths)
      $treeText = ($paths -join "`n")
    } else {
      $warnings += ('tree_failed (HTTP ' + $tree.status + ')')
    }

    $keyPaths = @()
    $filesBlock = ''
    if ($deepMode -and $paths.Count -gt 0) {
      $kMax = [Math]::Min($keyMax, [Math]::Max($keyMin, 3))
      $keyPaths = @(Select-JoyKeyFiles -Paths $paths -Readme $readmeText -Max $kMax)
      foreach ($kp in $keyPaths) {
        $f = Get-JoyFileText -FullName $full -Path $kp -Token $token -Proxy $proxy -MaxChars $keyFileMax
        if ($f.ok) {
          $filesBlock += ("`nFILE: " + $kp + "`n<<<FILE`n" + $f.text + "`nFILE>>>`n")
          $sources += [ordered]@{ path = $kp; chars = [int]$f.chars; truncated = [bool]$f.truncated }
        } else {
          $warnings += ('file_failed: ' + $kp + ' (HTTP ' + $f.status + ')')
        }
      }
    }

    $entry.materials.readmeChars = $readmeText.Length
    $entry.materials.treeEntries = $paths.Count
    $entry.materials.files = $keyPaths
    Write-JoyLog ("materials {0}: readme={1} tree={2} files={3}" -f $full, $readmeText.Length, $paths.Count, $keyPaths.Count)

    if ($NoLlm) {
      $entry.status = 'materials'
      $entry.warnings = $warnings
      $itemsOut += $entry
      $script:Result.skipped++
      Write-JoyEvent @{ evt = 'progress'; phase = 'item'; done = $idx; total = $wanted.Count }
      continue
    }

    $userPrompt = New-JoyUserPrompt -Meta $m -FullName $full -ReadmeText $readmeText -TreeText $treeText -FilesBlock $filesBlock -Mode $script:Result.mode
    $messages = @(
      @{ role = 'system'; content = $systemPrompt },
      @{ role = 'user'; content = $userPrompt }
    )

    $llmRes = Invoke-JoyLlmChat -Config $llm -Messages $messages -MaxTokens 12000 -Proxy $proxy
    $script:Result.llm.calls++
    if (-not $llmRes.ok) { throw ('llm: ' + [string]$llmRes.error) }

    $parsed = ConvertFrom-JoyLlmJson $llmRes.content
    if (-not $parsed.ok) {
      try {
        [IO.File]::WriteAllText((Join-Path $dataDir 'last-llm-raw.txt'), [string]$llmRes.content, (New-Object Text.UTF8Encoding($false)))
        Write-JoyLog 'raw llm output saved to data\last-llm-raw.txt' 'WARN'
      } catch { }
      throw ('llm_json: ' + [string]$parsed.error)
    }

    $allowed = @('README.md') + @($paths) + @($keyPaths)
    $val = Test-JoySummary -Obj $parsed.obj -AllowedPaths $allowed
    $warnings += @($val.warnings)

    if (-not $val.ok) {
      Write-JoyLog ("summary invalid, repairing: " + ($val.errors -join '; ')) 'WARN'
      $repairTpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'prompts\repair.tpl'), [Text.Encoding]::UTF8)
      $repairText = $repairTpl.Replace('{{ERRORS}}', ($val.errors -join '; '))
      $repair = @(
        @{ role = 'system'; content = $systemPrompt },
        @{ role = 'user'; content = $userPrompt },
        @{ role = 'assistant'; content = $parsed.raw },
        @{ role = 'user'; content = $repairText }
      )
      $r2 = Invoke-JoyLlmChat -Config $llm -Messages $repair -MaxTokens 12000 -Proxy $proxy
      $script:Result.llm.calls++
      if ($r2.ok) {
        $p2 = ConvertFrom-JoyLlmJson $r2.content
        if ($p2.ok) {
          $v2 = Test-JoySummary -Obj $p2.obj -AllowedPaths $allowed
          $warnings += @($v2.warnings)
          if ($v2.ok -or (@($v2.obj.qa).Count -ge 3 -and $v2.obj.overview)) { $val = $v2 }
        }
      }
    }

    $final = $val.obj
    if (-not $final.overview -or @($final.qa).Count -lt 3) {
      throw ('summary_incomplete (qa=' + @($final.qa).Count + ')')
    }
    if (-not $val.ok) { $warnings += ('unresolved: ' + ($val.errors -join '; ')) }

    $summary = [ordered]@{
      version = 1
      id = [string]$item.id
      fullName = $full
      mode = $script:Result.mode
      overview = $final.overview
      qa = $final.qa
      stack = $final.stack
      useCases = $final.useCases
      risks = $final.risks
      sources = $sources
      tree = [ordered]@{ entries = $paths.Count; truncated = [bool]$tree.truncated }
      model = $llm.Model
      generatedAt = (New-IsoNow)
      readRunId = $runId
      warnings = @($warnings)
    }

    if (-not $NoWrite) {
      Write-JoyJsonFile $summaryPath $summary
      $item.status = 'done'
      $item.summaryPath = $summaryPath
      $item.readRunId = $runId
      $item.lastError = $null
      Save-Queue $queue
    }

    $entry.status = 'done'
    $entry.summaryPath = $(if ($NoWrite) { $null } else { $summaryPath })
    $entry.overviewChars = ([string]$final.overview).Length
    $entry.qaCount = @($final.qa).Count
    $entry.warnings = @($warnings)
    $itemsOut += $entry
    $script:Result.succeeded++

    Write-JoyLog ("done {0}: overview={1} chars, qa={2}, warnings={3}" -f $full, $entry.overviewChars, $entry.qaCount, $warnings.Count)
    if ($NoWrite) { Write-JoyLog ('noWrite preview overview: ' + ([string]$final.overview)) }
    Write-JoyEvent @{ evt = 'progress'; phase = 'item'; done = $idx; total = $wanted.Count }
  } catch {
    $msg = Protect-JoySecret ([string]$_.Exception.Message)
    $item.status = 'failed'
    $item.lastError = $msg
    Save-Queue $queue
    $entry.status = 'failed'
    $entry.error = $msg
    $itemsOut += $entry
    $script:Result.failed++
    Write-JoyLog ("failed {0}: {1}" -f $full, $msg) 'ERROR'
    Write-JoyEvent @{ evt = 'progress'; phase = 'item'; done = $idx; total = $wanted.Count }
  }
}

$script:Result.items = $itemsOut

if (-not $NoWrite) {
  $stateObj = Read-JoyJsonFile (Get-StatePath)
  if (-not $stateObj) { $stateObj = [pscustomobject]@{ version = 1 } }
  $lastRead = [ordered]@{
    runId = $runId; n = $wanted.Count; succeeded = $script:Result.succeeded
    failed = $script:Result.failed; at = (New-IsoNow)
  }
  $stateObj | Add-Member -NotePropertyName lastRead -NotePropertyValue $lastRead -Force
  Write-JoyJsonFile (Get-StatePath) $stateObj
}

$script:Result.ok = ($script:Result.failed -eq 0)
Write-JoyEvent @{ evt = 'progress'; phase = 'done'; done = $wanted.Count; total = $wanted.Count }
Write-JoyLog ("summary: selected={0} succeeded={1} failed={2} skipped={3} llmCalls={4}" -f `
  $wanted.Count, $script:Result.succeeded, $script:Result.failed, $script:Result.skipped, $script:Result.llm.calls)

$exitCode = 0
if (-not $script:Result.ok) { $exitCode = 5 }
Save-ResultAndExit $exitCode