param(
  [string]$Dir = "D:\2\chan_month5\exports\a_shares_daily",
  [string]$StateDir = "G:\chan_month5_data\state\daily",
  [string]$Token = $env:TG_BOT_TOKEN,
  [string]$ChatId = $env:TG_CHAT_ID,
  [double]$Rate = 6,
  [int]$Limit = 0,
  [switch]$ForceReupload,
  [switch]$DeleteCsvAfterUpload
)
$ErrorActionPreference = 'Stop'
if (-not $Token -or -not $ChatId) { throw 'Need TG_BOT_TOKEN and TG_CHAT_ID' }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$daily = Join-Path $Dir 'daily'
$statePath = Join-Path $StateDir 'upload_state.json'
$indexPath = Join-Path $StateDir 'index.json'
$hintPath = Join-Path $Dir 'telegram_app_hint.json'
$summaryPath = Join-Path $Dir 'summary.csv'

$summaryMap = @{}
if (Test-Path $summaryPath) {
  $lines = Get-Content $summaryPath -Encoding utf8
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $p = $lines[$i].Split(',')
    if ($p.Length -ge 8) { $summaryMap[$p[0].Trim()] = $p }
  }
}

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
  $tmp = "$statePath.tmp"
  try {
    ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding utf8 -ErrorAction Stop
    Move-Item -Path $tmp -Destination $statePath -Force
  } catch {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    throw
  }
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
if ($ForceReupload) { $st = @{ files = @{} } }
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
  $meta = @{ file_id = $doc.file_id; message_id = $resp.result.message_id; size = $f.Length }
  if ($summaryMap.ContainsKey($code)) {
    $p = $summaryMap[$code]
    $meta.name = $p[1]; $meta.market = [int]$p[2]; $meta.bars = [int]$p[4]
    $meta.first = $p[5]; $meta.last = $p[6]
  }
  $st.files[$code] = $meta
  if ($DeleteCsvAfterUpload) {
    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
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
