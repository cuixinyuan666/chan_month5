# Upload existing tick cache on D (or G) as one zip per stock, then delete local cache.
param(
  [string]$CacheRoot = "D:\2\chan_month5\a_Data\.tdx_protocol_cache",
  [string]$StateDir = "G:\chan_month5_data\state\ticks",
  [string]$ZipDir = "G:\chan_month5_data\zips",
  [string]$Token = $env:TG_BOT_TOKEN,
  [string]$ChatId = $env:TG_CHAT_ID,
  [double]$Rate = 3,
  [int]$Limit = 0
)
$ErrorActionPreference = 'Continue'
if (-not $Token -or -not $ChatId) { throw 'Need TG_BOT_TOKEN and TG_CHAT_ID' }

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force -Path $StateDir,$ZipDir | Out-Null

$statePath = Join-Path $StateDir 'ticks_upload_state.json'
$indexPath = Join-Path $StateDir 'ticks_index.json'

function Read-TickState {
  if (-not (Test-Path $statePath)) { return @{ files = @{} } }
  try {
    $j = Get-Content $statePath -Raw -Encoding utf8 | ConvertFrom-Json
    $h = @{}
    if ($j.files) { $j.files.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    return @{ files = $h; index_file_id = $j.index_file_id }
  } catch { return @{ files = @{} } }
}

function Write-TickState($st) {
  $out = @{ files = $st.files }
  if ($st.index_file_id) { $out.index_file_id = $st.index_file_id }
  $tmp = "$statePath.tmp"
  ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding utf8
  Move-Item -Path $tmp -Destination $statePath -Force
}

function Send-Doc([string]$Path, [string]$Caption) {
  $uri = "https://api.telegram.org/bot$Token/sendDocument"
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(600)
  try {
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add([System.Net.Http.StringContent]::new($ChatId), 'chat_id') | Out-Null
    $content.Add([System.Net.Http.StringContent]::new('true'), 'disable_notification') | Out-Null
    if ($Caption) { $content.Add([System.Net.Http.StringContent]::new($Caption), 'caption') | Out-Null }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $sc = New-Object System.Net.Http.StreamContent($fs)
      $content.Add($sc, 'document', [IO.Path]::GetFileName($Path)) | Out-Null
      $resp = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
      $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      return ($txt | ConvertFrom-Json)
    } finally { $fs.Dispose() }
  } finally { $client.Dispose() }
}

$st = Read-TickState
$dirs = @(Get-ChildItem $CacheRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
if ($Limit -gt 0) { $dirs = $dirs | Select-Object -First $Limit }
Write-Host "tick cache stocks: $($dirs.Count); uploaded already: $($st.files.Count)"

$interval = 1.0 / [Math]::Max($Rate, 0.5)
$n = 0
foreach ($d in $dirs) {
  $code = $d.Name
  if ($st.files.ContainsKey($code)) {
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    continue
  }
  $zip = Join-Path $ZipDir "${code}_ticks.zip"
  if (Test-Path $zip) { Remove-Item $zip -Force }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($d.FullName, $zip)
  Start-Sleep -Seconds $interval
  try {
    $resp = Send-Doc -Path $zip -Caption "#ticks $code"
  } catch {
    Write-Warning "upload fail $code : $_"
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    continue
  }
  if (-not $resp.ok) {
    Write-Warning ($resp | ConvertTo-Json -Compress)
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    continue
  }
  $doc = $resp.result.document
  $dayCount = (Get-ChildItem $d.FullName -File).Count
  $st.files[$code] = @{ file_id = $doc.file_id; message_id = $resp.result.message_id; zip_size = (Get-Item $zip).Length; days = $dayCount }
  Remove-Item $d.FullName -Recurse -Force
  Remove-Item $zip -Force
  $n++
  if ($n % 10 -eq 0) {
    Write-TickState $st
    Write-Host "  uploaded $n stocks; total index $($st.files.Count)"
  }
}
Write-TickState $st

$index = @{ version = 1; kind = 'ticks_zip'; count = $st.files.Count; generated_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); files = $st.files }
($index | ConvertTo-Json -Depth 8) | Set-Content -Path $indexPath -Encoding utf8
$idx = Send-Doc -Path $indexPath -Caption "#ticks_index $($st.files.Count)"
if ($idx.ok) {
  $st.index_file_id = $idx.result.document.file_id
  Write-TickState $st
  Write-Host "ticks done count=$($st.files.Count) index_file_id=$($st.index_file_id)"
}
