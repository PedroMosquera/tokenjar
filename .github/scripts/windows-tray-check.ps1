# Drives the packaged tray on the runner's desktop as a user would, and saves screenshots to look at. Claude answers
# through a stand-in npm shim that prints a recorded signed-in answer, so the menu shows real windows; Codex and Copilot
# stay signed out. Run from the repository root after the package step.
$ErrorActionPreference = 'Stop'
$folder = Resolve-Path ./tokenjar-windows
$tray = Join-Path $folder TokenjarTray.exe
$fixtures = Resolve-Path Tests/TokenjarCoreTests/Fixtures/Claude
New-Item -ItemType Directory -Force shots | Out-Null

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string className, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
}
"@

function Shot($name) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save("shots/$name.png")
    $graphics.Dispose(); $bitmap.Dispose()
}
function Fail($message) { Write-Host "FAIL: $message"; Shot 'failure'; exit 1 }
function TrayWindow { [Win]::FindWindowW('TokenjarTray', 'TokenjarTray') }
function Post($message, $wParam, $lParam) {
    if (-not [Win]::PostMessageW((TrayWindow), $message, [UIntPtr]::new($wParam), [IntPtr]::new($lParam))) { Fail "could not post $message" }
}
$WM_APP = 0x8000; $WM_COMMAND = 0x0111; $WM_RBUTTONUP = 0x0205; $WM_CANCELMODE = 0x001F

# The recorded answer, its resets moved to the coming days so the windows are current.
$today = Get-Date
$shift = { param($text) $text -replace '2026-10-10', $today.AddDays(1).ToString('yyyy-MM-dd') -replace '2026-10-11', $today.AddDays(2).ToString('yyyy-MM-dd') -replace '2026-10-12', $today.AddDays(3).ToString('yyyy-MM-dd') }
New-Item -ItemType Directory -Force "$HOME\.claude", "$HOME\.local\bin\node_modules\fake-claude" | Out-Null
& $shift (Get-Content -Raw "$fixtures\claude-json-max.json") | Set-Content -NoNewline -Encoding utf8NoBOM "$HOME\.claude.json"
& $shift (Get-Content -Raw "$fixtures\stream-plan-limits.jsonl") | Set-Content -NoNewline -Encoding utf8NoBOM "$HOME\claude-answer.jsonl"
"process.stdout.write(require('fs').readFileSync(require('path').join(process.env.USERPROFILE, 'claude-answer.jsonl')))" |
    Set-Content -Encoding utf8NoBOM "$HOME\.local\bin\node_modules\fake-claude\cli.js"
# What npm's cmd-shim writes. ~\.local\bin comes before npm's folder, so this one answers instead of the real claude.
@(
    '@ECHO off', 'GOTO start', ':find_dp0', 'SET dp0=%~dp0', 'EXIT /b', ':start', 'SETLOCAL', 'CALL :find_dp0', '',
    'IF EXIST "%dp0%\node.exe" (', '  SET "_prog=%dp0%\node.exe"', ') ELSE (', '  SET "_prog=node"', '  SET PATHEXT=%PATHEXT:;.JS;=;%', ')', '',
    'endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\fake-claude\cli.js" %*'
) -join "`r`n" | Set-Content -NoNewline -Encoding ascii "$HOME\.local\bin\claude.cmd"

$process = Start-Process $tray -PassThru
Start-Sleep -Seconds 15
if ($process.HasExited) { Fail "the tray exited with $($process.ExitCode)" }
if ([Win]::FindWindowW('#32770', 'Tokenjar') -ne [IntPtr]::Zero) { Fail 'the tray showed an error box' }
if ((TrayWindow) -eq [IntPtr]::Zero) { Fail 'no tray window' }

$status = & "$folder\tokenjar.exe" --status | ConvertFrom-Json
$claude = $status.accounts | Where-Object id -eq 'claude'
Write-Host "claude windows: $(($claude.windows | ForEach-Object { "$($_.label) $($_.usedPercent)%" }) -join ', ')"
if ($claude.windows.Count -lt 1) { Fail 'the tray stored no Claude windows' }

# Windows 11 hides new tray icons behind the overflow arrow. Showing ours and restarting Explorer also proves the icon
# comes back after Explorer forgets it.
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue |
    Where-Object { (Get-ItemProperty $_.PSPath).ExecutablePath -like '*TokenjarTray.exe' } |
    ForEach-Object { Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWord }
Shot '1-before-explorer-restart'
Stop-Process -Name explorer -Force
Start-Sleep -Seconds 5
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer; Start-Sleep -Seconds 5 }
Start-Sleep -Seconds 5
if ($process.HasExited) { Fail 'the tray exited when Explorer restarted' }
Shot '2-after-explorer-restart'

# A right click on the icon, as Explorer reports it.
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point 700, 500
Post ($WM_APP + 1) 1 $WM_RBUTTONUP
Start-Sleep -Seconds 2
Shot '3-menu'
Post $WM_CANCELMODE 0 0
Start-Sleep -Seconds 1

$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Post $WM_COMMAND 2 0
Start-Sleep -Seconds 1
$value = (Get-ItemProperty $run -ErrorAction SilentlyContinue).Tokenjar
Write-Host "Run value: $value"
if ($value -ne "`"$tray`"") { Fail "Start at login wrote '$value'" }
Post $WM_COMMAND 2 0
Start-Sleep -Seconds 1
if ($null -ne (Get-ItemProperty $run -ErrorAction SilentlyContinue).Tokenjar) { Fail 'Start at login did not turn off' }

Post $WM_COMMAND 1 0
Start-Sleep -Seconds 5
if ($process.HasExited) { Fail 'the tray exited on Refresh now' }

Post $WM_COMMAND 4 0
if (-not $process.WaitForExit(10000)) { Fail 'Quit did not end the tray' }
Start-Sleep -Seconds 2
Shot '4-after-quit'
Write-Host 'tray check passed'
