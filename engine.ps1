# engine.ps1 - shared GameSaveSync functions (used by sync.ps1 CLI and app.ps1 web server)
# PowerShell 5.1, ASCII only. Dot-source this file, then call the functions.

$script:Manifest = $null
$script:ExcludePatterns = @()

# ---------------------------------------------------------------- USB / manifest
function Find-UsbRoot {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
        $marker = Join-Path $d.Root 'GameSync\.usbsync-root'
        if (Test-Path -LiteralPath $marker) { return $d.Root.TrimEnd('\') }
    }
    return $null
}

function Load-Manifest {
    param([string]$ManifestPath)
    $script:Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $script:ExcludePatterns = @($script:Manifest.exclude)
    return $script:Manifest
}

function Find-ManifestPath {
    param([string]$BaseDir)
    $p = Join-Path $BaseDir 'manifest.json'
    if (Test-Path -LiteralPath $p) { return $p }
    $usb = Find-UsbRoot
    if ($usb) {
        $p2 = Join-Path $usb 'GameSync\manifest.json'
        if (Test-Path -LiteralPath $p2) { return $p2 }
    }
    return $null
}

function Resolve-Source {
    param([string]$Template)
    return [Environment]::ExpandEnvironmentVariables($Template)
}

function Is-Excluded {
    param([string]$Rel)
    foreach ($pat in $script:ExcludePatterns) {
        if ($Rel -like $pat) { return $true }
    }
    return $false
}

function New-SaveRoot {
    param([string]$UsbRoot)
    $root = Join-Path $UsbRoot $script:Manifest.usbRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

# ---------------------------------------------------------------- file maps
# Map of relative path -> FileInfo for one side. Excludes *.log etc.
function Get-FileMap {
    param([string]$Base)
    $map = @{}
    if (Test-Path -LiteralPath $Base) {
        Get-ChildItem -LiteralPath $Base -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($Base.Length).TrimStart('\')
            if (-not (Is-Excluded $rel)) { $map[$rel] = $_ }
        }
    }
    return $map
}

function Get-MapSummary {
    param($Map)
    $bytes = 0
    $newest = [datetime]::MinValue
    foreach ($k in $Map.Keys) {
        $bytes += $Map[$k].Length
        if ($Map[$k].LastWriteTime -gt $newest) { $newest = $Map[$k].LastWriteTime }
    }
    return [pscustomobject]@{ Files = $Map.Count; Bytes = $bytes; Newest = $newest }
}

# Build a temp dir that merges all existing sources of a game (PC side).
# Returns [pscustomobject]@{ Dir = <path>; HasData = <bool> }
function Get-PcMergedDir {
    param($Game)
    $tmp = Join-Path $env:TEMP ("gamesync-" + [guid]::NewGuid().ToString('N'))
    $any = $false
    foreach ($tpl in $Game.sources) {
        $s = Resolve-Source $tpl
        if (-not (Test-Path -LiteralPath $s)) { continue }
        $any = $true
        Get-ChildItem -LiteralPath $s -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($s.Length).TrimStart('\')
            if (Is-Excluded $rel) { return }
            $dstFull = Join-Path $tmp $rel
            $dstDir = Split-Path -Parent $dstFull
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $dstFull -Force | Out-Null
        }
    }
    return [pscustomobject]@{ Dir = $tmp; HasData = $any }
}

# ---------------------------------------------------------------- sync core
# Copy SrcBase -> DstBase. Conflict rule:
#   'newest' (auto): a file is overwritten only if the source copy is newer
#   'force'  (src is main): source wins, overwrite any different file
#   'fill'   (dst is main): only copy files missing on the destination
# Never deletes. Returns result object.
function Sync-OneWay {
    param(
        [string]$SrcBase,
        [string]$DstBase,
        [string]$GameName,
        [string]$Side,
        [string]$Conflict = 'newest',
        [bool]$DryRun = $false
    )
    $res = [pscustomobject]@{ Copied = 0; Updated = 0; Skipped = 0; Errors = 0 }
    if (-not (Test-Path -LiteralPath $SrcBase)) { return $res }

    $srcMap = Get-FileMap $SrcBase
    $dstMap = Get-FileMap $DstBase

    foreach ($rel in ($srcMap.Keys | Sort-Object)) {
        $f = $srcMap[$rel]
        $d = $dstMap[$rel]
        if ($d) {
            $sameTime = [Math]::Abs($f.LastWriteTime.Subtract($d.LastWriteTime).TotalSeconds) -lt 2
            if ($sameTime -and $d.Length -eq $f.Length) { $res.Skipped++; continue }
            if ($Conflict -eq 'fill') { $res.Skipped++; continue }
            if ($Conflict -eq 'newest' -and $f.LastWriteTime -lt $d.LastWriteTime) { $res.Skipped++; continue }
            $res.Updated++
        } else {
            $res.Copied++
        }
        if ($DryRun) { continue }
        try {
            $dstFull = Join-Path $DstBase $rel
            $dstDir = Split-Path -Parent $dstFull
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dstFull -Force -ErrorAction Stop | Out-Null
        } catch {
            $res.Errors++
        }
    }
    return $res
}

# Full per-game sync. Returns status strings per step.
# mode: 'push' | 'pull' | 'merge'. Conflict follows $script:Settings.MainSide
# ('auto' = newest wins, 'pc' = PC is main, 'usb' = USB is main).
function Sync-Game {
    param(
        $Game,
        [string]$UsbSaveRoot,
        [string]$Mode = 'merge',
        [bool]$DryRun = $false
    )
    $out = New-Object System.Collections.ArrayList
    $gameDir = Join-Path $UsbSaveRoot $Game.name
    $pcView = Get-PcMergedDir $Game
    $main = $script:Settings.MainSide
    $toUsb = if ($main -eq 'pc') { 'force' } elseif ($main -eq 'usb') { 'fill' } else { 'newest' }
    $toPc  = if ($main -eq 'usb') { 'force' } elseif ($main -eq 'pc') { 'fill' } else { 'newest' }
    try {
        if ($Mode -ne 'pull') {
            if ($pcView.HasData) {
                $r = Sync-OneWay $pcView.Dir $gameDir $Game.name 'PC->USB' $toUsb $DryRun
                $out.Add(("[{0}] {1}: PC->USB copied {2} updated {3} skipped {4}" -f $Game.name, $(if ($DryRun) {'DRY'} else {'push'}), $r.Copied, $r.Updated, $r.Skipped)) | Out-Null
            } elseif (-not (Test-Path -LiteralPath $gameDir)) {
                $out.Add(("[{0}] no save data on this PC and nothing on USB yet" -f $Game.name)) | Out-Null
            }
        }
        if ($Mode -ne 'push') {
            if (Test-Path -LiteralPath $gameDir) {
                $target = $null
                foreach ($tpl in $Game.sources) {
                    $s = Resolve-Source $tpl
                    if (Test-Path -LiteralPath $s) { $target = $s; break }
                }
                if (-not $target) { $target = Resolve-Source $Game.sources[0] }
                $r = Sync-OneWay $gameDir $target $Game.name 'USB->PC' $toPc $DryRun
                $out.Add(("[{0}] {1}: USB->PC copied {2} updated {3} skipped {4}" -f $Game.name, $(if ($DryRun) {'DRY'} else {'pull'}), $r.Copied, $r.Updated, $r.Skipped)) | Out-Null
            }
        }
    } finally {
        Remove-Item -LiteralPath $pcView.Dir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return $out
}

# ---------------------------------------------------------------- settings (main side, per-game toggles, cloud)
$script:Settings = $null

function Get-SettingsPath {
    param([string]$UsbRoot)
    return Join-Path $UsbRoot 'GameSync\settings.json'
}

function Load-Settings {
    param([string]$UsbRoot)
    $s = [pscustomobject]@{
        MainSide = 'auto'   # 'auto' (newest wins) | 'pc' | 'usb' (that side wins conflicts)
        CloudRepo = '%USERPROFILE%\GameSaveCloud'
        CloudRemote = 'https://github.com/DALI951/game-saves.git'
        Games = [pscustomobject]@{}
    }
    $path = Get-SettingsPath $UsbRoot
    if (Test-Path -LiteralPath $path) {
        try {
            $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($loaded.MainSide)   { $s.MainSide = $loaded.MainSide }
            if ($loaded.CloudRepo)  { $s.CloudRepo = $loaded.CloudRepo }
            if ($loaded.CloudRemote){ $s.CloudRemote = $loaded.CloudRemote }
            if ($loaded.Games)      { $s.Games = $loaded.Games }
        } catch { }
    }
    $script:Settings = $s
    return $s
}

function Save-Settings {
    param([string]$UsbRoot)
    $path = Get-SettingsPath $UsbRoot
    $script:Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
}

# per-game settings: enabled (persistent), cloudEnabled (persistent once set).
function Get-GameSetting {
    param($Game, [string]$UsbSaveRoot)
    $enabled = $true; $cloud = $null
    if ($script:Settings.Games) {
        $gs = $script:Settings.Games.$($Game.name)
        if ($gs) {
            if ($null -ne $gs.enabled) { $enabled = [bool]$gs.enabled }
            if ($null -ne $gs.cloud)   { $cloud = [bool]$gs.cloud }
        }
    }
    if ($null -eq $cloud) {
        $gameDir = Join-Path $UsbSaveRoot $Game.name
        $big = $false
        if (Test-Path -LiteralPath $gameDir) {
            Get-ChildItem -LiteralPath $gameDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Length -gt 90MB) { $big = $true }
            }
        }
        $cloud = -not $big   # GitHub caps files at 100 MB -> big games stay offline by default
    }
    return [pscustomobject]@{ Enabled = $enabled; Cloud = $cloud }
}

function Set-GameSetting {
    param([string]$GameName, [string]$Key, $Value)
    if (-not $script:Settings.Games) { $script:Settings.Games = [pscustomobject]@{} }
    $gs = $script:Settings.Games.$GameName
    if (-not $gs) { $gs = [pscustomobject]@{ enabled = $true; cloud = $true }; $script:Settings.Games | Add-Member -NotePropertyName $GameName -NotePropertyValue $gs }
    $gs | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

# ---------------------------------------------------------------- cloud (GitHub) sync
function Get-CloudRepoDir {
    $r = Resolve-Source $script:Settings.CloudRepo
    if (-not (Test-Path -LiteralPath $r)) { New-Item -ItemType Directory -Path $r -Force | Out-Null }
    return $r
}

function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $o = & git -C $Repo @GitArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
}

function Ensure-CloudRepo {
    $r = Get-CloudRepoDir
    $gitDir = Join-Path $r '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Invoke-Git $r @('init','-b','main') | Out-Null
        Invoke-Git $r @('remote','add','origin',$script:Settings.CloudRemote) | Out-Null
        Set-Content -LiteralPath (Join-Path $r '.gitignore') -Value "*.log`n*.tmp`nThumbs.db`ndesktop.ini`n" -Encoding UTF8
        Invoke-Git $r @('add','.') | Out-Null
        Invoke-Git $r @('commit','-m','GameSaveSync cloud repo init') | Out-Null
    }
    return $r
}

function Invoke-CloudSync {
    param($Games, [string]$UsbSaveRoot, [string]$Action = 'push')
    $out = New-Object System.Collections.ArrayList
    $repo = Ensure-CloudRepo
    if ($Action -eq 'push') {
        foreach ($g in $Games) {
            $src = Join-Path $UsbSaveRoot $g.name
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $dst = Join-Path $repo $g.name
            $r = Sync-OneWay $src $dst $g.name 'USB->cloud' $false
            $out.Add(("[{0}] cloud push: copied {1} updated {2}" -f $g.name, $r.Copied, $r.Updated)) | Out-Null
        }
        $gitAdd  = Invoke-Git $repo @('add','-A')
        $gitCmt  = Invoke-Git $repo @('commit','-m',("saves {0} from {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $env:COMPUTERNAME))
        if ($gitCmt.Code -ne 0 -and $gitAdd.Code -ne 0) {
            $out.Add(('cloud: nothing to commit - ' + $gitCmt.Out)) | Out-Null
        }
        $gitPush = Invoke-Git $repo @('push','origin','main')
        if ($gitPush.Code -eq 0) { $out.Add('cloud: pushed to GitHub') | Out-Null }
        else { $out.Add(('cloud: PUSH FAILED - ' + $gitPush.Out)) | Out-Null }
    } elseif ($Action -eq 'pull') {
        $gitPull = Invoke-Git $repo @('pull','--ff-only','origin','main')
        if ($gitPull.Code -ne 0) {
            $out.Add(('cloud: PULL FAILED - ' + $gitPull.Out)) | Out-Null
        } else {
            $out.Add('cloud: pulled from GitHub') | Out-Null
        }
        foreach ($g in $Games) {
            $src = Join-Path $repo $g.name
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $dst = Join-Path $UsbSaveRoot $g.name
            $r = Sync-OneWay $src $dst $g.name 'cloud->USB' $false
            $out.Add(("[{0}] cloud pull -> USB: copied {1} updated {2}" -f $g.name, $r.Copied, $r.Updated)) | Out-Null
        }
    }
    return $out
}

# ---------------------------------------------------------------- status
function Get-GameStatus {
    param($Game, [string]$UsbSaveRoot)
    $gameDir = Join-Path $UsbSaveRoot $Game.name
    $pcExists = $false
    $pcSource = $null
    foreach ($tpl in $Game.sources) {
        $s = Resolve-Source $tpl
        if (Test-Path -LiteralPath $s) { $pcExists = $true; if (-not $pcSource) { $pcSource = $s } }
    }
    if (-not $pcSource) { $pcSource = Resolve-Source $Game.sources[0] }

    $pcMap = Get-PcMergedDir $Game
    $pcSummary = Get-MapSummary (Get-FileMap $pcMap.Dir)
    Remove-Item -LiteralPath $pcMap.Dir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    $usbMap = Get-FileMap $gameDir
    $usbSummary = Get-MapSummary $usbMap

    $state = 'none'
    if ($pcSummary.Files -gt 0 -and $usbSummary.Files -eq 0) { $state = 'pc-only' }
    elseif ($pcSummary.Files -eq 0 -and $usbSummary.Files -gt 0) { $state = 'usb-only' }
    elseif ($pcSummary.Files -gt 0 -and $usbSummary.Files -gt 0) {
        $same = ($pcSummary.Files -eq $usbSummary.Files)
        if ($same) {
            $pcMap2 = Get-PcMergedDir $Game
            $a = Get-FileMap $pcMap2.Dir
            Remove-Item -LiteralPath $pcMap2.Dir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            foreach ($k in $a.Keys) {
                if (-not $usbMap.ContainsKey($k)) { $same = $false; break }
                if ($a[$k].Length -ne $usbMap[$k].Length) { $same = $false; break }
                if ([Math]::Abs($a[$k].LastWriteTime.Subtract($usbMap[$k].LastWriteTime).TotalSeconds) -ge 2) { $same = $false; break }
            }
        }
        if ($same) { $state = 'synced' }
        elseif ($pcSummary.Newest -ge $usbSummary.Newest) { $state = 'pc-newer' }
        else { $state = 'usb-newer' }
    }

    $gs = Get-GameSetting -Game $Game -UsbSaveRoot $UsbSaveRoot

    return [pscustomobject]@{
        Name       = $Game.name
        PcSource   = $pcSource
        PcExists   = $pcExists
        PcFiles    = $pcSummary.Files
        PcBytes    = $pcSummary.Bytes
        PcNewest   = $pcSummary.Newest
        UsbFiles   = $usbSummary.Files
        UsbBytes   = $usbSummary.Bytes
        UsbNewest  = $usbSummary.Newest
        State      = $state
        Enabled    = $gs.Enabled
        Cloud      = $gs.Cloud
    }
}