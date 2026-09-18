# GameSaveSync - two-way game save sync between PCs via USB drive
# Runs on the PC side. The USB must contain GameSync\sync.ps1 and the
# marker file GameSync\.usbsync-root so the USB is found no matter what
# letter Windows assigned to it.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1            (two-way merge, newest wins)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Push       (PC -> USB only)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Pull       (USB -> PC only)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -DryRun     (show what would happen, do nothing)
#
# Never deletes anything. Conflict rule: the file with the newer write time
# wins and is copied over the other side. Nothing is ever removed, so a save
# deleted on one PC is kept on the other until you clean it manually.

param(
    [switch]$Push,
    [switch]$Pull,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = $null

# ---------------------------------------------------------------- helpers
function Write-Log {
    param([string]$Msg)
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Output $line
    if ($logFile) { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 }
}

function Find-UsbRoot {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
        $marker = Join-Path $d.Root 'GameSync\.usbsync-root'
        if (Test-Path -LiteralPath $marker) { return $d.Root.TrimEnd('\') }
    }
    return $null
}

function Resolve-Source {
    param([string]$Template)
    return [Environment]::ExpandEnvironmentVariables($Template)
}

function Is-Excluded {
    param([string]$Rel)
    foreach ($pat in $excludePatterns) {
        if ($Rel -like $pat) { return $true }
    }
    return $false
}

# Copy SrcBase -> DstBase, newest-wins (a file is only overwritten if the
# source copy is newer). Returns nothing, logs a summary.
function Sync-OneWay {
    param(
        [string]$SrcBase,
        [string]$DstBase,
        [string]$GameName,
        [string]$Side      # 'PC->USB' or 'USB->PC'
    )
    if (-not (Test-Path -LiteralPath $SrcBase)) { return }
    $copied = 0; $updated = 0; $skipped = 0; $errors = 0

    $dstIndex = @{}
    if (Test-Path -LiteralPath $DstBase) {
        Get-ChildItem -LiteralPath $DstBase -Recurse -File | ForEach-Object {
            $dstIndex[$_.FullName.Substring($DstBase.Length).TrimStart('\')] = $_
        }
    }

    Get-ChildItem -LiteralPath $SrcBase -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($SrcBase.Length).TrimStart('\')
        if (Is-Excluded $rel) { return }
        $dstFile = $dstIndex[$rel]
        if ($dstFile) {
            $sameTime = [Math]::Abs($_.LastWriteTime.Subtract($dstFile.LastWriteTime).TotalSeconds) -lt 2
            if ($sameTime -and $dstFile.Length -eq $_.Length) { $skipped++; return }
            if ($_.LastWriteTime -lt $dstFile.LastWriteTime) { $skipped++; return }  # dest newer: keep dest
            $updated++
        } else {
            $copied++
        }
        if ($DryRun) { Write-Log ("  [" + $Side + "] " + $rel); return }
        try {
            $dstFull = Join-Path $DstBase $rel
            $dstDir = Split-Path -Parent $dstFull
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $dstFull -Force -ErrorAction Stop | Out-Null
        } catch {
            $errors++
            Write-Log ("  ERROR [" + $Side + "] " + $rel + " : " + $_.Exception.Message)
        }
    }
    Write-Log ("  [{0}] {1}: copied {2} / updated {3} / skipped {4} / errors {5}" -f $Side, $GameName, $copied, $updated, $skipped, $errors)
}

# ---------------------------------------------------------------- main
$mode = if ($Push) { 'push' } elseif ($Pull) { 'pull' } else { 'merge' }
if ($DryRun) { Write-Output '== DRY RUN - nothing will be copied ==' }

$usb = Find-UsbRoot
if (-not $usb) {
    Write-Output 'USB drive with GameSync not found. Plug it in and try again.'
    exit 1
}
Write-Output ("USB drive found at: " + $usb)

$manifestPath = Join-Path $scriptDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $usb 'GameSync\manifest.json' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$excludePatterns = @($manifest.exclude)

$saveRoot = Join-Path $usb $manifest.usbRoot
New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null
$logDir = Join-Path (Join-Path $usb 'GameSync') 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("sync-{0}-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Log ("=== GameSaveSync {0} on {1} ===" -f $mode, $env:COMPUTERNAME)

foreach ($game in $manifest.games) {
    Write-Log ("-- " + $game.name)
    $gameDir = Join-Path $saveRoot $game.name

    # build the merged PC-side view (all existing sources combined)
    $tmpParent = Join-Path $env:TEMP ("gamesync-" + [guid]::NewGuid().ToString('N'))
    $pcMerged = Join-Path $tmpParent 'pc'
    $pcHasData = $false
    foreach ($tpl in $game.sources) {
        $s = Resolve-Source $tpl
        if (-not (Test-Path -LiteralPath $s)) { continue }
        $pcHasData = $true
        Get-ChildItem -LiteralPath $s -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($s.Length).TrimStart('\')
            if (Is-Excluded $rel) { return }
            $dstFull = Join-Path $pcMerged $rel
            $dstDir = Split-Path -Parent $dstFull
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $dstFull -Force | Out-Null
        }
    }

    if ($mode -ne 'pull') {
        # PC -> USB
        if ($pcHasData) {
            Sync-OneWay $pcMerged $gameDir $game.name 'PC->USB'
        } elseif (-not (Test-Path -LiteralPath $gameDir)) {
            Write-Log ("  {0}: no save data on this PC and nothing on USB yet" -f $game.name)
        }
    }

    if ($mode -ne 'push') {
        # USB -> PC (restore into first existing source, else first template)
        if (Test-Path -LiteralPath $gameDir) {
            $target = $null
            foreach ($tpl in $game.sources) {
                $s = Resolve-Source $tpl
                if (Test-Path -LiteralPath $s) { $target = $s; break }
            }
            if (-not $target) { $target = Resolve-Source $game.sources[0] }
            Sync-OneWay $gameDir $target $game.name 'USB->PC'
        }
    }

    Remove-Item -LiteralPath $tmpParent -Recurse -Force | Out-Null
}

Write-Log "=== done ==="
Write-Output ''
Write-Output ("Log: " + $logFile)
Write-Output 'GameSaveSync finished. Safe to unplug the USB.'