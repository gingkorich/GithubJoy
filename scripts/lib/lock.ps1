# GitHub Joy - cross-process workflow lease (ASCII only, PowerShell 5.1)
Set-StrictMode -Off

$script:JoyWorkflowLockPath = $null
$script:JoyWorkflowLockToken = $null
$script:JoyWorkflowLockOwned = $false

function Read-JoyWorkflowLock {
  param([string]$Path)
  try {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $raw = $raw -replace '^\uFEFF', ''
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-JoyWorkflowProcessAlive([int]$ProcessId, [string]$StartedAt) {
  if (-not $ProcessId) { return $false }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
  } catch {
    return $false
  }
  if ($StartedAt) {
    try {
      $expected = ([datetime]$StartedAt).ToUniversalTime()
      $actual = $p.StartTime.ToUniversalTime()
      if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 10) { return $false }
    } catch {
      # If process start time cannot be checked, do not steal a possibly-live lock.
      return $true
    }
  }
  return $true
}

function Test-JoyWorkflowOwnerAlive($Record) {
  if (-not $Record) { return $false }
  if (Test-JoyWorkflowProcessAlive ([int]$Record.ownerPid) ([string]$Record.ownerStartedAt)) { return $true }
  return (Test-JoyWorkflowProcessAlive ([int]$Record.activeChildPid) ([string]$Record.activeChildStartedAt))
}

function Enter-JoyWorkflowLock {
  param([string]$Kind = 'workflow')

  $root = Get-JoyRoot
  $dir = Join-Path $root 'data\locks'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $path = Join-Path $dir 'workflow.lock.json'
  $script:JoyWorkflowLockPath = $path

  # Service pipeline children join the existing lease; they never own or release it.
  $inherited = [string]$env:JOY_WORKFLOW_LOCK_TOKEN
  if ($inherited) {
    $record = Read-JoyWorkflowLock $path
    if ($record -and [string]$record.token -eq $inherited) {
      $script:JoyWorkflowLockToken = $inherited
      $script:JoyWorkflowLockOwned = $false
      return @{ ok = $true; token = $inherited; owned = $false; error = $null }
    }
    return @{ ok = $false; token = $null; owned = $false; error = 'workflow_lock_token_invalid' }
  }

  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $token = [guid]::NewGuid().ToString('N')
    $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($proc) { $startedAt = $proc.StartTime.ToUniversalTime().ToString('o') }
    $record = [ordered]@{
      version = 1
      token = $token
      ownerPid = $PID
      ownerStartedAt = $startedAt
      kind = $Kind
      acquiredAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $createdByUs = $false
    try {
      $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      $createdByUs = $true
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress -Depth 4))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
      } finally {
        $fs.Dispose()
      }
      $script:JoyWorkflowLockToken = $token
      $script:JoyWorkflowLockOwned = $true
      return @{ ok = $true; token = $token; owned = $true; error = $null }
    } catch [IO.IOException] {
      if ($createdByUs) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; token = $null; owned = $false; error = ('workflow_lock_write_failed: ' + $_.Exception.Message) }
      }
      if (-not (Test-Path -LiteralPath $path)) {
        return @{ ok = $false; token = $null; owned = $false; error = ('workflow_lock_create_failed: ' + $_.Exception.Message) }
      }

      $existing = Read-JoyWorkflowLock $path
      if ($existing -and (Test-JoyWorkflowOwnerAlive $existing)) {
        return @{ ok = $false; token = $null; owned = $false; error = ('workflow_busy: ' + [string]$existing.kind + ' pid=' + [string]$existing.ownerPid) }
      }
      if (-not $existing) {
        return @{ ok = $false; token = $null; owned = $false; error = 'workflow_lock_invalid: inspect processes before removing the lock file' }
      }

      # Reclaim stale metadata atomically. Only one contender can rename it.
      try {
        $stale = $path + '.stale-' + [guid]::NewGuid().ToString('N')
        [IO.File]::Move($path, $stale)
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
      } catch { }
    } catch {
      if ($createdByUs) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
      return @{ ok = $false; token = $null; owned = $false; error = ('workflow_lock_create_failed: ' + $_.Exception.Message) }
    }
  }
  return @{ ok = $false; token = $null; owned = $false; error = 'workflow_busy' }
}

function Exit-JoyWorkflowLock {
  if (-not $script:JoyWorkflowLockOwned -or -not $script:JoyWorkflowLockPath -or -not $script:JoyWorkflowLockToken) {
    $script:JoyWorkflowLockToken = $null
    $script:JoyWorkflowLockOwned = $false
    return
  }
  $record = Read-JoyWorkflowLock $script:JoyWorkflowLockPath
  if ($record -and [string]$record.token -eq [string]$script:JoyWorkflowLockToken) {
    Remove-Item -LiteralPath $script:JoyWorkflowLockPath -Force -ErrorAction SilentlyContinue
  }
  $script:JoyWorkflowLockToken = $null
  $script:JoyWorkflowLockOwned = $false
}
