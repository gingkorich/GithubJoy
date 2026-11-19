# GitHub Joy - logging (ASCII only)
Set-StrictMode -Off

$script:JoyLogPath = $null

function Protect-JoySecret([string]$Text) {
  if (-not $Text) { return '' }
  $t = $Text
  $t = $t -replace 'gh[pousr]_[A-Za-z0-9]{20,}', '***'
  $t = $t -replace 'sk-[A-Za-z0-9\-_]{10,}', '***'
  $t = $t -replace '(?i)(token|api[_-]?key)\s*[:=]\s*\S+', '$1=***'
  $t = $t -replace '(?i)bearer\s+[A-Za-z0-9\-_.]{10,}', 'Bearer ***'
  return $t
}

function Initialize-JoyLog([string]$Path) {
  if (-not $Path) { return }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $script:JoyLogPath = $Path
  $line = "===== GitHub Joy started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
  [IO.File]::AppendAllText($Path, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Write-JoyLog([string]$Message, [string]$Level = 'INFO') {
  $ts = Get-Date -Format 'HH:mm:ss'
  $safe = Protect-JoySecret ([string]$Message)
  $line = "[$ts] [$Level] $safe"
  Write-Host $line
  if ($script:JoyLogPath) {
    [IO.File]::AppendAllText($script:JoyLogPath, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  }
}

function Write-JoyEvent($Event) {
  $json = $Event | ConvertTo-Json -Compress -Depth 6
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}