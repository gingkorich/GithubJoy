# GitHub Joy - LLM client (ASCII only)
Set-StrictMode -Off

function Get-JoyLlmConfig {
  $path = Join-Path (Get-JoyRoot) 'llm.json'
  $o = Read-JoyJsonFile $path
  if (-not $o) { return $null }
  $base = ([string]$o.base_url).Trim().TrimEnd('/')
  $key = [string]$o.api_key
  $model = [string]$o.model
  if (-not $base -or -not $key -or -not $model) { return $null }

  $timeout = 60
  if ($o.PSObject.Properties.Name -contains 'timeout_sec' -and $o.timeout_sec) { $timeout = [int]$o.timeout_sec }
  if ($timeout -lt 10) { $timeout = 10 }
  if ($timeout -gt 300) { $timeout = 300 }

  $maxRetries = 3
  if ($o.PSObject.Properties.Name -contains 'max_retries' -and $o.max_retries) { $maxRetries = [int]$o.max_retries }

  $temp = $null
  if ($o.PSObject.Properties.Name -contains 'temperature' -and $o.temperature -ne $null) { $temp = [double]$o.temperature }

  return [pscustomobject]@{
    BaseUrl = $base; ApiKey = $key; Model = $model
    TimeoutSec = $timeout; MaxRetries = $maxRetries; Temperature = $temp
  }
}

function Get-JoyLlmUrl([string]$BaseUrl) {
  if ($BaseUrl -match '/chat/completions$') { return $BaseUrl }
  return ($BaseUrl + '/chat/completions')
}

function Invoke-JoyLlmChat {
  param(
    $Config,
    [object[]]$Messages,
    [int]$MaxTokens = 2000,
    [string]$Proxy = $null
  )

  $url = Get-JoyLlmUrl $Config.BaseUrl
  $useTemp = ($null -ne $Config.Temperature)
  $attempt = 0
  $last = $null
  $maxTok = $MaxTokens

  while ($attempt -lt $Config.MaxRetries) {
    $attempt++
    $payload = [ordered]@{ model = $Config.Model; messages = $Messages; max_tokens = $maxTok }
    if ($useTemp) { $payload['temperature'] = [double]$Config.Temperature }
    $body = $payload | ConvertTo-Json -Depth 12 -Compress

    # Direct first; only on a network-level failure (status 0: timeout/DNS/refused)
    # fall back to the proxy once. HTTP-level errors (4xx/5xx) mean the service
    # is reachable, so no proxy retry. The direct attempt uses the FULL timeout:
    # aborting a slow-but-working direct call would resend the prompt and double
    # the LLM bill.
    $httpArgs = @{
      Method = 'POST'
      Uri    = $url
      Headers = @{ Authorization = "Bearer $($Config.ApiKey)" }
      Body   = $body
      TimeoutSec = $Config.TimeoutSec
    }
    $r = Invoke-JoyHttp @httpArgs -Proxy $null
    if (-not $r.ok -and [int]$r.status -eq 0 -and $Proxy) {
      Write-JoyLog 'llm direct connection failed (network level); retrying via proxy' 'WARN'
      $r = Invoke-JoyHttp @httpArgs -Proxy $Proxy
    }

    $text = [string]$r.body
    if ($r.ok) {
      $obj = $null
      try { $obj = $text | ConvertFrom-Json } catch { return @{ ok = $false; error = 'llm_json_parse_failed'; raw = $text } }
      $content = ''
      $finish = ''
      try {
        $content = [string]$obj.choices[0].message.content
        $finish = [string]$obj.choices[0].finish_reason
      } catch { }
      if ($finish -eq 'length' -and $attempt -lt $Config.MaxRetries -and $maxTok -lt 12000) {
        $maxTok = [Math]::Min(12000, $maxTok * 2)
        Write-JoyLog ("llm truncated by max_tokens; retry with max_tokens=$maxTok") 'WARN'
        continue
      }
      if (-not $content) {
        Write-JoyLog ('llm empty content; finish=' + $finish + ' raw=' + $text.Substring(0, [Math]::Min(600, $text.Length))) 'WARN'
        return @{ ok = $false; error = 'llm_empty_content'; raw = $text }
      }
      $usage = $null
      if ($obj.PSObject.Properties.Name -contains 'usage') { $usage = $obj.usage }
      return @{ ok = $true; content = $content; usage = $usage; attempts = $attempt; raw = $text }
    }

    $last = @{ ok = $false; status = $r.status; error = (($text + ' ' + $r.error).Trim()); raw = $text }

    # some router models reject temperature with 400
    if ($r.status -eq 400 -and $useTemp -and ($text + $r.error) -match '(?i)temperature') {
      Write-JoyLog 'model rejects temperature; retrying without it' 'WARN'
      $useTemp = $false
      $attempt--
      continue
    }

    if ($r.status -in @(429, 500, 502, 503, 504)) {
      if ($attempt -ge $Config.MaxRetries) { break }
      $wait = [Math]::Pow(2, $attempt)
      Write-JoyLog ("LLM HTTP {0}; retry in {1}s ({2}/{3})" -f $r.status, $wait, $attempt, $Config.MaxRetries) 'WARN'
      Start-Sleep -Seconds $wait
      continue
    }
    break
  }

  if (-not $last) { $last = @{ ok = $false; error = 'llm_failed' } }
  $last['attempts'] = $attempt
  return $last
}

function Repair-JoyJsonText([string]$Text) {
  if (-not $Text) { return $Text }
  $sb = New-Object Text.StringBuilder
  $inStr = $false
  $esc = $false
  foreach ($ch in $Text.ToCharArray()) {
    if ($inStr) {
      if ($esc) { [void]$sb.Append($ch); $esc = $false; continue }
      if ($ch -eq '\') { [void]$sb.Append($ch); $esc = $true; continue }
      if ($ch -eq '"') { [void]$sb.Append($ch); $inStr = $false; continue }
      if ($ch -eq "`r") { [void]$sb.Append('\r'); continue }
      if ($ch -eq "`n") { [void]$sb.Append('\n'); continue }
      if ($ch -eq "`t") { [void]$sb.Append('\t'); continue }
      [void]$sb.Append($ch)
    } else {
      if ($ch -eq '"') { $inStr = $true }
      [void]$sb.Append($ch)
    }
  }
  $out = $sb.ToString()
  $out = $out -replace ',\s*([}\]])', '$1'
  return $out
}

function ConvertFrom-JoyLlmJson([string]$Text) {
  if (-not $Text) { return @{ ok = $false; error = 'empty' } }
  $t = $Text.Trim()
  $t = $t -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
  $start = $t.IndexOf('{')
  $end = $t.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) { return @{ ok = $false; error = 'no_json_object'; raw = $Text } }
  $snippet = $t.Substring($start, $end - $start + 1)

  try {
    $obj = $snippet | ConvertFrom-Json
    return @{ ok = $true; obj = $obj; raw = $snippet }
  } catch { }

  $repaired = Repair-JoyJsonText $snippet
  try {
    $obj2 = $repaired | ConvertFrom-Json
    Write-JoyLog 'json repaired (control chars/trailing commas)' 'WARN'
    return @{ ok = $true; obj = $obj2; raw = $snippet; repaired = $true }
  } catch {
    return @{ ok = $false; error = ('json_invalid: ' + $_.Exception.Message); raw = $snippet }
  }
}