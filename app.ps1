# GameSync-App - local web UI for GameSaveSync
# Starts a small HTTP server on 127.0.0.1 and serves web\index.html.
# No admin needed, no installs, works on both PCs (PowerShell 5.1 only).
#
# Launch:  powershell -NoProfile -ExecutionPolicy Bypass -File app.ps1
# UI:      http://127.0.0.1:8771   (Stop button in the UI shuts the server down)

param([int]$Port = 8771)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'engine.ps1')

$script:Running = $true
$script:Logs = New-Object System.Collections.ArrayList

function Add-Msg {
    param([string]$Msg)
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    [void]$script:Logs.Add($line)
    if ($script:Logs.Count -gt 500) { $script:Logs.RemoveRange(0, $script:Logs.Count - 500) }
    Write-Output $line
}

function Get-RequestBody {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

function Send-Response {
    param($Context, [string]$Body, [string]$ContentType = 'application/json; charset=utf-8')
    $buf = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $buf.Length
    $Context.Response.OutputStream.Write($buf, 0, $buf.Length)
    $Context.Response.Close()
}

function Write-ErrorJson {
    param($Context, [string]$Msg, [int]$Code = 400)
    $Context.Response.StatusCode = $Code
    Send-Response $Context (([pscustomobject]@{ Error = $Msg } | ConvertTo-Json))
}

# ---------------------------------------------------------------- wire up
$usb = Find-UsbRoot
$manifestPath = Find-ManifestPath $scriptDir
if (-not $usb -or -not $manifestPath) {
    Write-Output 'USB drive with GameSync not found. Plug it in and restart.'
    exit 1
}
$m = Load-Manifest $manifestPath
$saveRoot = New-SaveRoot $usb
$script:Settings = Load-Settings $usb
$uiFile = Join-Path $scriptDir 'web\index.html'
Add-Msg ("GameSync-App ready: http://127.0.0.1:{0}  (USB at {1})" -f $Port, $usb)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add(("http://127.0.0.1:{0}/" -f $Port))
try { $listener.Start() } catch {
    if (-not $listener.IsListening) {
        Write-Output ("Port {0} already in use - is GameSync-App already running? Open http://127.0.0.1:{0}" -f $Port)
        exit 1
    }
}

# ---------------------------------------------------------------- routes
while ($script:Running -and $listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod

        if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            if (Test-Path -LiteralPath $uiFile) {
                Send-Response $ctx ([System.IO.File]::ReadAllText($uiFile)) 'text/html; charset=utf-8'
            } else {
                Write-ErrorJson $ctx 'web/index.html missing next to app.ps1' 500
            }

        } elseif ($method -eq 'GET' -and $path -eq '/api/status') {
            $status = @()
            foreach ($g in $m.games) { $status += Get-GameStatus -Game $g -UsbSaveRoot $saveRoot }
            $body = [pscustomobject]@{
                PC = $env:COMPUTERNAME
                Usb = $usb
                Port = $Port
                Games = @($status)
            } | ConvertTo-Json -Depth 4
            Send-Response $ctx $body

        } elseif ($method -eq 'POST' -and $path -eq '/api/sync') {
            $req = Get-RequestBody $ctx | ConvertFrom-Json
            $names = @($req.games)
            $mode  = $req.mode
            $dry   = [bool]$req.dryRun
            if (-not $mode) { $mode = 'merge' }
            $games = @($m.games | Where-Object { $names -contains $_.name })
            if ($names.Count -eq 1 -and $names[0] -eq '*') {
                # '*' = every game with its persistent 'enabled' toggle on
                $games = @()
                foreach ($g in $m.games) {
                    $gs = Get-GameSetting -Game $g -UsbSaveRoot $saveRoot
                    if ($gs.Enabled) { $games += $g }
                }
            }
            $lines = New-Object System.Collections.ArrayList
            foreach ($g in $games) {
                $res = Sync-Game -Game $g -UsbSaveRoot $saveRoot -Mode $mode -DryRun $dry
                foreach ($r in $res) {
                    [void]$lines.Add($r)
                    Add-Msg $r
                }
            }
            $body = [pscustomobject]@{ Done = @($games).Count; Lines = @($lines); DryRun = $dry } | ConvertTo-Json -Depth 4
            Send-Response $ctx $body

        } elseif ($method -eq 'GET' -and $path -eq '/api/settings') {
            $settings = [pscustomobject]@{
                MainSide = $script:Settings.MainSide
                CloudRepo = $script:Settings.CloudRepo
                CloudRepoResolved = Resolve-Source $script:Settings.CloudRepo
                CloudRemote = $script:Settings.CloudRemote
                Games = [pscustomobject]{}
            }
            foreach ($g in $m.games) {
                $gs = Get-GameSetting -Game $g -UsbSaveRoot $saveRoot
                $settings.Games | Add-Member -NotePropertyName $g.name -NotePropertyValue ([pscustomobject]@{ enabled = $gs.Enabled; cloud = $gs.Cloud })
            }
            Send-Response $ctx ($settings | ConvertTo-Json -Depth 4)

        } elseif ($method -eq 'POST' -and $path -eq '/api/settings') {
            $req = Get-RequestBody $ctx | ConvertFrom-Json
            if ($req.MainSide -and @('auto','pc','usb') -contains $req.MainSide) {
                $script:Settings.MainSide = $req.MainSide
            }
            if ($req.CloudRepo)   { $script:Settings.CloudRepo = [string]$req.CloudRepo }
            if ($req.CloudRemote) { $script:Settings.CloudRemote = [string]$req.CloudRemote }
            if ($req.Games) {
                foreach ($p in $req.Games.PSObject.Properties) {
                    $gv = $p.Value
                    if ($null -ne $gv.enabled) { Set-GameSetting $p.Name 'enabled' ([bool]$gv.enabled) }
                    if ($null -ne $gv.cloud)   { Set-GameSetting $p.Name 'cloud' ([bool]$gv.cloud) }
                }
            }
            Save-Settings $usb
            Add-Msg ("Settings saved: main={0}" -f $script:Settings.MainSide)
            Send-Response $ctx (([pscustomobject]@{ Saved = $true; MainSide = $script:Settings.MainSide } | ConvertTo-Json))

        } elseif ($method -eq 'POST' -and $path -eq '/api/cloud') {
            $req = Get-RequestBody $ctx | ConvertFrom-Json
            $action = $req.action   # 'push' | 'pull'
            if ($action -ne 'push' -and $action -ne 'pull') { Write-ErrorJson $ctx 'action must be push or pull'; continue }
            $names = @($req.games)
            if ($names.Count -eq 1 -and $names[0] -eq '*') { $names = $null }
            $games = @()
            foreach ($g in $m.games) {
                $gs = Get-GameSetting -Game $g -UsbSaveRoot $saveRoot
                if (-not $gs.Cloud) { continue }
                if ($names -and $names -notcontains $g.name) { continue }
                $games += $g
            }
            if ($games.Count -eq 0) { Send-Response $ctx (([pscustomobject]@{ Done = 0; Lines = @('cloud: no cloud-enabled games selected'); DryRun = $false } | ConvertTo-Json)); continue }
            $lines = @(Invoke-CloudSync -Games $games -UsbSaveRoot $saveRoot -Action $action)
            foreach ($l in $lines) { Add-Msg $l }
            $body = [pscustomobject]@{ Done = $games.Count; Lines = $lines; Action = $action } | ConvertTo-Json -Depth 4
            Send-Response $ctx $body

        } elseif ($method -eq 'GET' -and $path -eq '/api/logs') {
            $n = 100
            if ($ctx.Request.QueryString['n']) { $n = [int]$ctx.Request.QueryString['n'] }
            $start = [Math]::Max(0, $script:Logs.Count - $n)
            $tail = @($script:Logs.GetRange($start, $script:Logs.Count - $start))
            Send-Response $ctx (([pscustomobject]@{ Logs = $tail } | ConvertTo-Json -Depth 3))

        } elseif ($method -eq 'POST' -and $path -eq '/api/shutdown') {
            Send-Response $ctx (([pscustomobject]@{ Bye = $true } | ConvertTo-Json))
            Add-Msg 'Shutdown requested - stopping server.'
            $script:Running = $false

        } else {
            Write-ErrorJson $ctx 'Not found' 404
        }
    } catch {
        Add-Msg ("Route error " + $path + " : " + $_.Exception.Message)
        try { Write-ErrorJson $ctx $_.Exception.Message 500 } catch { }
    }
}

$listener.Stop(); $listener.Close()
Add-Msg 'Server stopped.'