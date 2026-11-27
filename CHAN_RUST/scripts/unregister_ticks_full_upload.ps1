# unregister_ticks_full_upload.ps1
# Delete Chan\TicksFullUpload scheduled task.
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$taskName = 'Chan\TicksFullUpload'
$out = @{ ok = $false; taskName = $taskName; message = '' }

try {
    if ($WhatIf) {
        $out.ok = $true
        $out.message = 'WhatIf: would delete ' + $taskName
        Write-Output ($out | ConvertTo-Json -Compress)
        exit 0
    }
    $null = schtasks /Delete /TN $taskName /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('schtasks delete failed exit=' + $LASTEXITCODE)
    }
    $out.ok = $true
    $out.message = 'deleted'
    Write-Output ($out | ConvertTo-Json -Compress)
    exit 0
}
catch {
    $out.ok = $false
    $out.message = [string]$_.Exception.Message
    Write-Output ($out | ConvertTo-Json -Compress)
    exit 1
}
