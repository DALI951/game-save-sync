# GameSaveSync CLI - two-way game save sync between PCs via USB drive
# Thin wrapper over engine.ps1. Also used by GameSync-App (web UI).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1            (two-way merge, newest wins)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Push       (PC -> USB only)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Pull       (USB -> PC only)
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Game "Hollow Knight"
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Json       (machine-readable output)
#
# Never deletes anything. Conflict rule: the file with the newer write time wins.

param(
    [switch]$Push,
    [switch]$Pull,
    [switch]$DryRun,
    [switch]$Json,
    [string]$Game
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'engine.ps1')

$mode = if ($Push) { 'push' } elseif ($Pull) { 'pull' } else { 'merge' }

$usb = Find-UsbRoot
if (-not $usb) {
    Write-Output 'USB drive with GameSync not found. Plug it in and try again.'
    exit 1
}
$manifestPath = Find-ManifestPath $scriptDir
if (-not $manifestPath) { Write-Output 'manifest.json not found next to sync.ps1.'; exit 1 }
$m = Load-Manifest $manifestPath
$saveRoot = New-SaveRoot $usb

$logDir = Join-Path (Join-Path $usb 'GameSync') 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("sync-{0}-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))

$lines = New-Object System.Collections.ArrayList
$lines.Add(("=== GameSaveSync {0} on {1} === {2}" -f $mode, $env:COMPUTERNAME, $(if ($DryRun) { 'DRY RUN' } else { '' }))) | Out-Null

$games = @($m.games)
if ($Game) { $games = @($games | Where-Object { $_.name -eq $Game }) }
if ($games.Count -eq 0) { Write-Output ("No such game: " + $Game + ". Check manifest.json names."); exit 1 }

foreach ($g in $games) {
    $results = Sync-Game -Game $g -UsbSaveRoot $saveRoot -Mode $mode -DryRun $DryRun
    foreach ($r in $results) { $lines.Add($r) | Out-Null }
}
$lines.Add('=== done ===') | Out-Null

foreach ($l in $lines) {
    Add-Content -LiteralPath $logFile -Value $l -Encoding UTF8
    if (-not $Json) { Write-Output $l }
}

if ($Json) {
    $out = [pscustomobject]@{ Mode = $mode; DryRun = $DryRun; PC = $env:COMPUTERNAME; Usb = $usb; Log = $logFile; Lines = @($lines) }
    Write-Output ($out | ConvertTo-Json -Depth 4)
} else {
    Write-Output ''
    Write-Output ("Log: " + $logFile)
    Write-Output 'GameSaveSync finished. Safe to unplug the USB.'
}