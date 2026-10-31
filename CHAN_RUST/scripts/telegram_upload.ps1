param(
  [string]$Dir = "D:\2\chan_month5\exports\a_shares_daily",
  [string]$Token = $env:TG_BOT_TOKEN,
  [string]$ChatId = $env:TG_CHAT_ID,
  [double]$Rate = 6,
  [int]$Limit = 0
)
$ErrorActionPreference = 'Stop'
if (-not $Token -or -not $ChatId) { throw 'Need TG_BOT_TOKEN and TG_CHAT_ID' }

Add-Type -AssemblyName System.Net.Http

$daily = Join-Path $Dir 'daily'
$statePath = Join-Path $Dir 'upload_state.json'
$indexPath = Join-Path $Dir 'index.json'
$hintPath = Join-Path $Dir 'telegram_app_hint.json'

function Read-State {
  if (-not (Test-Path $statePath)) { return @{ files = @{} } }
  $j = Get-Content $statePath -Raw -Encoding utf8 | ConvertFrom-Json
  $h = @{}
  if ($j.files) {
    $j.files.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
  }
  return @{ files = $h; index_file_id = $j.index_file_id; index_message_id = $j.index_message_id }
}

function Write-State($st) {
  $out = @{ files = $st.files }
  if ($st.index_file_id) { $out.index_file_id = $st.index_file_id }
  if ($st.index_message_id) { $out.index_message_id = $st.index_message_id }
  ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $statePath -Encoding utf8
}

function Send-Doc([string]$Path, [string]$Caption) {
  $uri = "https://api.telegram.org/bot$Token/sendDocument"
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(180)
  try {
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add([System.Net.Http.StringContent]::new($ChatId), 'chat_id') | Out-Null
    $content.Add([System.Net.Http.StringContent]::new('true'), 'disable_notification') | Out-Null
    if ($Caption) {
      $content.Add([System.Net.Http.StringContent]::new($Caption), 'caption') | Out-Null
    }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $sc = New-Object System.Net.Http.StreamContent($fs)
      $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
      $name = [IO.Path]::GetFileName($Path)
      $content.Add($sc, 'document', $name) | Out-Null
      $resp = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
      $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if (-not $txt) { throw 'empty response' }
      return ($txt | ConvertFrom-Json)
    } finally {
      $fs.Dispose()
    }
  } finally {
    $client.Dispose()
  }
}

$st = Read-State
$all = @(Get-ChildItem (Join-Path $daily '*.csv') | Sort-Object Name)
if ($Limit -gt 0) { $all = $all | Select-Object -First $Limit }
Write-Host "upload $($all.Count) files; state has $($st.files.Count)"

$interval = 1.0 / [Math]::Max($Rate, 0.5)
$n = 0
foreach ($f in $all) {
  $code = $f.BaseName.Substring($f.BaseName.Length - 6)
  if ($st.files.ContainsKey($code)) { continue }
  Start-Sleep -Seconds $interval
  try {
    $resp = Send-Doc -Path $f.FullName -Caption "#A $code"
  } catch {
    Write-Warning "fail $($f.Name): $_"
    continue
  }
  if (-not $resp.ok) {
    Write-Warning ($resp | ConvertTo-Json -Compress)
    if ($resp.error_code -eq 429 -and $resp.parameters.retry_after) {
      Start-Sleep -Seconds ([int]$resp.parameters.retry_after + 1)
    }
    continue
  }
  $doc = $resp.result.document
  $st.files[$code] = @{
    file_id = $doc.file_id
    message_id = $resp.result.message_id
    size = $f.Length
  }
  $n++
  if ($n % 25 -eq 0) {
    Write-State $st
    Write-Host "progress $n new; total $($st.files.Count)"
  }
}
Write-State $st

$index = @{
  version = 1
  count = $st.files.Count
  generated_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  files = $st.files
}
($index | ConvertTo-Json -Depth 8) | Set-Content -Path $indexPath -Encoding utf8

$idx = Send-Doc -Path $indexPath -Caption "#index $($st.files.Count)"
if ($idx.ok) {
  $st.index_file_id = $idx.result.document.file_id
  $st.index_message_id = $idx.result.message_id
  Write-State $st
  @{ chat_id = $ChatId; index_file_id = $st.index_file_id; count = $st.files.Count } |
    ConvertTo-Json | Set-Content -Path $hintPath -Encoding utf8
  Write-Host "done count=$($st.files.Count) index_file_id=$($st.index_file_id)"
} else {
  Write-Warning 'index upload failed'
}
