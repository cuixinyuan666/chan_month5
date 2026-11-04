# Smart launcher: pick repo (WorkBuddy / worktree / default clone), rebuild only when stale, then start chan_kline.
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) { Write-Host ">> $msg" -ForegroundColor Cyan }

function Find-RepoCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        $scriptRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        [void]$candidates.Add($scriptRepo)
    } catch { }

    foreach ($p in @(
            $env:CHAN_REPO_ROOT,
            (Join-Path $env:USERPROFILE "Downloads\chan\chan_month5"),
            "D:\2\chan_month5"
        )) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
            $rp = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path
            if (-not $candidates.Contains($rp)) { [void]$candidates.Add($rp) }
        } catch { }
    }

    $wtRoots = @(
        (Join-Path $env:LOCALAPPDATA "share\opencode\worktree"),
        (Join-Path $env:USERPROFILE ".local\share\opencode\worktree")
    )
    foreach ($root in $wtRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $r = $_.FullName
                if (Test-Path (Join-Path $r "CHAN_RUST\scripts\build_rust.ps1")) {
                    if (-not $candidates.Contains($r)) { [void]$candidates.Add($r) }
                }
            }
        }
    }

    return @($candidates | Where-Object { Test-ValidRepo $_ })
}

function Test-ValidRepo([string]$repoRoot) {
    if (-not $repoRoot) { return $false }
    $buildScript = Join-Path $repoRoot "CHAN_RUST\scripts\build_rust.ps1"
    $flutterDir = Join-Path $repoRoot "CHAN_RUST\flutter\chan_kline"
    return (Test-Path -LiteralPath $buildScript) -and (Test-Path -LiteralPath $flutterDir)
}

function Get-RepoScore([string]$repoRoot) {
    $score = 0
    if (Test-Path (Join-Path $repoRoot ".workbuddy")) { $score += 1000 }
    if ($repoRoot -match 'worktree|\.wt\\|\.kilo\\worktrees\\') { $score += 200 }
    try {
        $scriptRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        if ($repoRoot -eq $scriptRepo) { $score += 5000 }
    } catch { }
    try {
        Push-Location $repoRoot
        $t = git log -1 --format=%ct 2>$null
        Pop-Location
        if ($t) { $score += [int]$t }
    } catch { Pop-Location -ErrorAction SilentlyContinue }
    return $score
}

function Select-RepoRoot {
    $all = Find-RepoCandidates
    if ($all.Count -eq 0) {
        throw "chan_month5 repo not found"
    }
    return ($all | Sort-Object { Get-RepoScore $_ } -Descending | Select-Object -First 1)
}

function Get-LatestWriteTime([string[]]$paths) {
    $max = [datetime]::MinValue
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $t = (Get-Item -LiteralPath $p).LastWriteTimeUtc
            if ($t -gt $max) { $max = $t }
            continue
        }
        Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.LastWriteTimeUtc -gt $max) { $max = $_.LastWriteTimeUtc }
        }
    }
    if ($max -eq [datetime]::MinValue) { return $null }
    return $max
}

function Test-NeedRebuild {
    param(
        [string]$FlutterDir,
        [string]$ExePath,
        [string]$NativeDll,
        [string]$ReleaseDll,
        [string]$RustRoot
    )
    if (-not (Test-Path -LiteralPath $ExePath)) {
        return @{ Need = $true; Reason = "missing debug exe" }
    }
    $exeTime = (Get-Item -LiteralPath $ExePath).LastWriteTimeUtc

    $rustNewest = Get-LatestWriteTime @(
        (Join-Path $RustRoot "chan_data\src"),
        (Join-Path $RustRoot "chan_ffi\src"),
        (Join-Path $RustRoot "Cargo.toml"),
        (Join-Path $RustRoot "chan_data\Cargo.toml"),
        (Join-Path $RustRoot "chan_ffi\Cargo.toml")
    )
    if ($rustNewest -and $rustNewest -gt $exeTime) {
        return @{ Need = $true; Reason = "rust newer than exe" }
    }
    if ((Test-Path -LiteralPath $ReleaseDll) -and (Get-Item -LiteralPath $ReleaseDll).LastWriteTimeUtc -gt $exeTime) {
        return @{ Need = $true; Reason = "release dll newer than exe" }
    }
    if ((Test-Path -LiteralPath $NativeDll) -and (Get-Item -LiteralPath $NativeDll).LastWriteTimeUtc -gt $exeTime) {
        return @{ Need = $true; Reason = "native dll newer than exe" }
    }

    $dartNewest = Get-LatestWriteTime @(
        (Join-Path $FlutterDir "lib"),
        (Join-Path $FlutterDir "pubspec.yaml"),
        (Join-Path $FlutterDir "pubspec.lock"),
        (Join-Path $FlutterDir "windows")
    )
    if ($dartNewest -and $dartNewest -gt $exeTime) {
        return @{ Need = $true; Reason = "flutter newer than exe" }
    }

    return @{ Need = $false; Reason = "exe up to date" }
}

function Ensure-SubstDrive([string]$repoRoot) {
    $needSubst = $repoRoot.Length -gt 180 -or $repoRoot -match 'worktree|\.wt\\|\.kilo\\worktrees\\'
    if (-not $needSubst) { return @{ BuildRoot = $repoRoot; EnvRoot = $repoRoot } }

    $marker = Join-Path $PSScriptRoot ".subst_drive"
    $drive = "Z:"
    if (Test-Path -LiteralPath $marker) {
        $saved = (Get-Content -LiteralPath $marker -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($saved -match '^[A-Z]:$') { $drive = $saved }
    }

    $substOut = cmd /c "subst $drive" 2>$null
    if ($substOut -and ($substOut -match [regex]::Escape($repoRoot))) {
        Write-Step "subst already mapped"
        return @{ BuildRoot = "${drive}\\"; EnvRoot = $repoRoot }
    }

    cmd /c "subst $drive /d" 2>$null | Out-Null
    $null = cmd /c "subst $drive `"$repoRoot`""
    if ($LASTEXITCODE -ne 0) { throw "subst failed" }
    Set-Content -LiteralPath $marker -Value $drive -Encoding ASCII
    Write-Step "subst mapped $drive -> $repoRoot"
    return @{ BuildRoot = "${drive}\\"; EnvRoot = $repoRoot }
}

function Invoke-SmartBuild([string]$buildRoot) {
    $buildScript = Join-Path $buildRoot "CHAN_RUST\scripts\build_rust.ps1"
    $logRoot = if ($buildRoot -match '^[A-Z]:\\$') { $buildRoot.TrimEnd('\') } else { $buildRoot }
    $log = Join-Path $logRoot "build_rust_run.log"
    Write-Step "building, log: $log"

    $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $buildScript
    ) -WorkingDirectory $logRoot -PassThru -Wait -NoNewWindow

    if ($p.ExitCode -ne 0) {
        if (Test-Path $log) { Get-Content $log -Tail 30 }
        throw "build_rust failed exit $($p.ExitCode)"
    }
    return $true
}

function Start-ChanApp([string]$repoRoot, [string]$flutterDir, [string]$exePath) {
    if (Get-Process -Name chan_kline -ErrorAction SilentlyContinue) {
        Write-Step "app already running"
        return
    }
    $env:CHAN_REPO_ROOT = $repoRoot
    $env:CHAN_KLINE_ROOT = $flutterDir
    Write-Step "launch $exePath"
    Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath -Parent)
}

$repoRoot = Select-RepoRoot
$wb = Test-Path (Join-Path $repoRoot ".workbuddy")
Write-Step "repo: $repoRoot $(if ($wb) { '[WorkBuddy]' } else { '' })"

$paths = Ensure-SubstDrive $repoRoot
$buildRoot = $paths.BuildRoot
$envRoot = $paths.EnvRoot

$flutterDir = Join-Path $buildRoot "CHAN_RUST\flutter\chan_kline"
$rustRoot = Join-Path $buildRoot "CHAN_RUST\rust"
$exePath = Join-Path $flutterDir "build\windows\x64\runner\Debug\chan_kline.exe"
$nativeDll = Join-Path $flutterDir "windows\native\chan_ffi.dll"
$releaseDll = Join-Path $rustRoot "target\release\chan_ffi.dll"

$check = Test-NeedRebuild -FlutterDir $flutterDir -ExePath $exePath -NativeDll $nativeDll -ReleaseDll $releaseDll -RustRoot $rustRoot

if ($check.Need) {
    Write-Step "rebuild: $($check.Reason)"
    Invoke-SmartBuild $buildRoot | Out-Null
    if (Get-Process -Name chan_kline -ErrorAction SilentlyContinue) {
        Write-Step "app started by build_rust"
        exit 0
    }
} else {
    Write-Step "skip build: $($check.Reason)"
}

if (-not (Test-Path -LiteralPath $exePath)) {
    Invoke-SmartBuild $buildRoot | Out-Null
    if (Get-Process -Name chan_kline -ErrorAction SilentlyContinue) { exit 0 }
}

Start-ChanApp -repoRoot $envRoot -flutterDir $flutterDir -exePath $exePath
Write-Step "done"
