# Agent-only: copy robot verify report to clipboard and close chan_kline.
# User compiles/opens App manually; App writes a_Data/robot_verify/last_report.txt
param(
    [switch]$Close
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $Root
$ReportJson = Join-Path $RepoRoot "a_Data\robot_verify\last_report.json"
$ReportPath = if (Test-Path $ReportJson) { $ReportJson } else { Join-Path $RepoRoot "a_Data\robot_verify\last_report.txt" }
$StatusPath = Join-Path $RepoRoot "a_Data\robot_verify\status.json"

if (-not (Test-Path $ReportPath)) {
    throw "Report not found: $ReportPath (wait for App verify to finish)"
}

$text = Get-Content $ReportPath -Raw -Encoding UTF8
Set-Clipboard -Value $text
Write-Host ">> Copied report JSON to clipboard ($($text.Length) chars) from $ReportPath"

if (Test-Path $StatusPath) {
    Write-Host ">> status.json:"
    Get-Content $StatusPath -Raw
}

if ($Close) {
    $App = Get-Process -Name chan_kline -ErrorAction SilentlyContinue
    if ($App) {
        Write-Host ">> Closing chan_kline..."
        $App | Stop-Process -Force
    } else {
        Write-Host ">> chan_kline not running"
    }
}
