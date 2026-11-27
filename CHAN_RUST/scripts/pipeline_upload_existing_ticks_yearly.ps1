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
$MAX_ZIP_MB = 45

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
  ($out | ConvertTo-Json -Depth 10) | Set-Content -Path $tmp -Encoding utf8
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

function Upload-Chunk([string]$Code, [string]$YearTag, $Files) {
  $zip = Join-Path $ZipDir "${Code}_${YearTag}_ticks.zip"
  if (Test-Path $zip) { Remove-Item $zip -Force }
  $tmpDir = Join-Path $ZipDir "_stage_${Code}_${YearTag}"
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  foreach ($f in $Files) { Copy-Item $f.FullName (Join-Path $tmpDir $f.Name) -Force }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($tmpDir, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
  Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
  if ($mb -gt $MAX_ZIP_MB) {
    Remove-Item $zip -Force
    throw "chunk ${Code}_${YearTag} too large: ${mb}MB"
  }
  Start-Sleep -Seconds (1.0 / [Math]::Max($Rate, 0.5))
  $resp = Send-Doc -Path $zip -Caption "#ticks $Code $YearTag ($($Files.Count)d)"
  if (-not $resp.ok) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    throw ("upload reject: " + ($resp | ConvertTo-Json -Compress))
  }
  $r = @{ file_id = $resp.result.document.file_id; message_id = $resp.result.message_id; days = $Files.Count; zip_mb = $mb }
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  return $r
}

$st = Read-TickState
$dirs = @(Get-ChildItem $CacheRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
if ($Limit -gt 0) { $dirs = $dirs | Select-Object -First $Limit }
Write-Host "tick dirs: $($dirs.Count); stocks in state: $($st.files.Count)"

$n = 0
foreach ($d in $dirs) {
  $code = $d.Name
  $files = @(Get-ChildItem $d.FullName -File -Filter '*.txt' -ErrorAction SilentlyContinue)
  if ($files.Count -eq 0) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue; continue }

  $entry = $st.files[$code]
  if ($entry -isnot [hashtable] -and $entry -ne $null) {
    $entry = @{ years = @{} }
  }
  if (-not $entry) { $entry = @{ years = @{} } }
  if (-not $entry.years) { $entry.years = @{} }

  $byYear = $files | Group-Object { $_.BaseName.Substring(0, 4) }
  $allDone = $true
  foreach ($g in $byYear) {
    $yr = $g.Name
    if ($entry.years.ContainsKey($yr)) { continue }
    try {
      $r = Upload-Chunk -Code $code -YearTag $yr -Files $g.Group
      $entry.years[$yr] = $r
      Write-TickState $st
      Write-Host "  ok $code $yr ($($g.Count)d, $($r.zip_mb)MB)"
    } catch {
      $allDone = $false
      Write-Warning "  fail $code $yr : $_"
      if ("$_" -match 'too large') {
        # 该年仍超限：按半年再拆
        $half1 = @($g.Group | Where-Object { [int]$_.BaseName.Substring(4, 2) -le 6 })
        $half2 = @($g.Group | Where-Object { [int]$_.BaseName.Substring(4, 2) -gt 6 })
        foreach ($pair in @(@("${yr}H1", $half1), @("${yr}H2", $half2))) {
          $tag = $pair[0]; $sub = $pair[1]
          if ($sub.Count -eq 0 -or $entry.years.ContainsKey($tag)) { continue }
          try {
            $r2 = Upload-Chunk -Code $code -YearTag $tag -Files $sub
            $entry.years[$tag] = $r2
            Write-TickState $st
            Write-Host "  ok $code $tag ($($sub.Count)d, $($r2.zip_mb)MB)"
            $allDone = $true
          } catch {
            $allDone = $false
            Write-Warning "  fail $code $tag : $_"
          }
        }
      }
    }
  }
  $st.files[$code] = $entry
  Write-TickState $st
  if ($allDone) {
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    $n++
    Write-Host "  stock $code done; dir removed (total stocks $($st.files.Count))"
  }
}

$index = @{ version = 2; kind = 'ticks_zip_yearly'; count = $st.files.Count; generated_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); files = $st.files }
($index | ConvertTo-Json -Depth 10) | Set-Content -Path $indexPath -Encoding utf8
$idx = Send-Doc -Path $indexPath -Caption "#ticks_index $($st.files.Count)"
if ($idx.ok) {
  $st.index_file_id = $idx.result.document.file_id
  Write-TickState $st
  Write-Host "ticks done count=$($st.files.Count) index_file_id=$($st.index_file_id)"
}
