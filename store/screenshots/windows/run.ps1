# The Windows half of `store/screenshots/capture.sh ms-desktop`. capture.sh copies the checkout to
# ~\ompanion-shots\repo on the Windows machine, writes the test's defines to ~\ompanion-shots\defines.json, and calls
# this script over SSH:
#
#   run.ps1 -Launch    runs the capture in the logged-on user's console session (a program started over SSH runs
#                      in session 0, which has no desktop to show a window on) through a scheduled task that runs
#                      this script with -Console; prints the run's log as it grows and exits with its exit code
#   run.ps1 -Console   the capture: builds winshot, sets the display to 3840x2160 at 200 %, runs `flutter drive`
#                      with its own profile, temp and pub cache under ~\ompanion-shots, and puts the display back
#   run.ps1 -Cleanup   ends a run that is still going (its task and every process of it), puts the display back if
#                      the run could not, and deletes ~\ompanion-shots unless -KeepClone
#
# Everything the run writes stays under ~\ompanion-shots: the app's database and secrets (OMPANION_DATA_DIR,
# OMPANION_SECRET_PREFIX), "this computer"'s home (OMPANION_LOCAL_HOME), and USERPROFILE, TEMP and PUB_CACHE of
# `flutter drive` and the app, so nothing of the user's profile is read or changed.
param(
    [switch]$Launch,
    [switch]$Console,
    [switch]$Cleanup,
    [switch]$RestoreDisplay,
    [switch]$KeepClone,
    [int]$Width = 3840,
    [int]$Height = 2160,
    [int]$Scale = 200,
    [int]$TimeoutMinutes = 60
)
$ErrorActionPreference = 'Stop'

$work = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$repo = Join-Path $work 'repo'
$winshot = Join-Path $work 'winshot.exe'
$log = Join-Path $work 'run.log'
$exitFile = Join-Path $work 'run.exit'
# The display's mode and scale from before the run, until they are back.
$displayFile = Join-Path $work 'display.txt'
$task = 'ompanion-shots'

function Say([string]$message) {
    "$(Get-Date -Format HH:mm:ss) $message" | Out-File -Append -Encoding utf8 $log
}

# Runs this script with $arguments in the console session through a scheduled task and waits for $marker.
function Invoke-InConsole([string]$name, [string]$arguments, [string]$marker, [int]$minutes, [switch]$Follow) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $arguments"
    # Interactive: runs only while the user is logged on, in their session, and needs no password.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes ($minutes + 5))
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $name
        $deadline = (Get-Date).AddMinutes($minutes)
        $offset = 0
        while ($true) {
            $finished = Test-Path $marker
            if ($Follow -and (Test-Path $log)) {
                $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
                try {
                    [void]$stream.Seek($offset, 'Begin')
                    $text = (New-Object IO.StreamReader($stream)).ReadToEnd()
                    $offset = $stream.Position
                } finally {
                    $stream.Dispose()
                }
                if ($text) { [Console]::Out.Write($text) }
            }
            if ($finished) { break }
            if ((Get-Date) -gt $deadline) { throw "the console run did not finish within $minutes minutes" }
            Start-Sleep -Seconds 2
        }
    } finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

# winshot with its output, errors included, in the log. Windows PowerShell turns a native program's stderr into
# errors, which 'Stop' would end the script on.
function Invoke-Winshot {
    $ErrorActionPreference = 'Continue'
    & $winshot @args 2>&1 | ForEach-Object { "$_" } | Out-File -Append -Encoding utf8 $log
    if ($LASTEXITCODE) { throw "winshot $($args -join ' ') failed" }
}

function Restore-Display {
    if (-not (Test-Path $displayFile)) { return }
    $before = (Get-Content $displayFile -Raw).Trim() -split ' '
    Say "display back to $($before[0])x$($before[1]) at $($before[2]) %"
    Invoke-Winshot display $before[0] $before[1] $before[2]
    Remove-Item $displayFile
}

if ($Launch) {
    Remove-Item $log, $exitFile -ErrorAction SilentlyContinue
    Invoke-InConsole $task "-Console -Width $Width -Height $Height -Scale $Scale" $exitFile $TimeoutMinutes -Follow
    $status = [int](Get-Content $exitFile -Raw).Trim()
    exit $status
}

if ($Console) {
    $status = 1
    try {
        Say "console session $((Get-Process -Id $PID).SessionId)"
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $csc /nologo /target:exe /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$winshot" (Join-Path $PSScriptRoot 'winshot.cs') |
            Out-File -Append -Encoding utf8 $log
        if ($LASTEXITCODE) { throw 'winshot did not build' }

        # A display left over from a run that was cut short is already the capture's; keep the one from before it.
        if (-not (Test-Path $displayFile)) {
            $before = & $winshot display
            if ($LASTEXITCODE -or -not $before) { throw 'winshot could not read the display' }
            $before | Out-File -Encoding ascii $displayFile
        }
        Say "display $((Get-Content $displayFile -Raw).Trim()), capturing at ${Width}x${Height} at $Scale %"
        Invoke-Winshot display $Width $Height $Scale
        Start-Sleep -Seconds 3

        # A fresh profile, database and channel every run; the pub cache and the build may stay (-KeepClone).
        foreach ($directory in 'home', 'tmp', 'data', 'raw') {
            $path = Join-Path $work $directory
            if (Test-Path $path) { Remove-Item -Recurse -Force $path }
            New-Item -ItemType Directory $path | Out-Null
        }
        New-Item -ItemType Directory -Force (Join-Path $work 'pub-cache') | Out-Null
        $defines = Get-Content -Raw (Join-Path $work 'defines.json') | ConvertFrom-Json
        $defines | Add-Member -NotePropertyName OMPANION_DATA_DIR -NotePropertyValue (Join-Path $work 'data')
        $defines | Add-Member -NotePropertyName OMPANION_LOCAL_HOME -NotePropertyValue (Join-Path $work 'home')
        $defines | Add-Member -NotePropertyName OMPANION_SECRET_PREFIX -NotePropertyValue "ompanion-shots-$([guid]::NewGuid().ToString('N'))-"
        $definesFile = Join-Path $work 'drive-defines.json'
        [IO.File]::WriteAllText($definesFile, ($defines | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

        $flutter = (Get-Command flutter).Source
        $env:USERPROFILE = Join-Path $work 'home'
        $env:HOME = $env:USERPROFILE
        $env:TEMP = Join-Path $work 'tmp'
        $env:TMP = $env:TEMP
        $env:PUB_CACHE = Join-Path $work 'pub-cache'
        $env:MSBUILDDISABLENODEREUSE = '1'
        $env:OMPANION_SHOT_TARGET = "windows:$(Join-Path $repo 'build')"
        $env:OMPANION_SHOT_DIR = Join-Path $work 'raw'
        $env:OMPANION_SHOT_WINSHOT = $winshot
        Say "flutter drive in $repo"
        Push-Location $repo
        try {
            & $winshot run $log $flutter drive -d windows --suppress-analytics `
                --driver=integration_test/driver/store_driver.dart `
                --target=integration_test/store_screenshots_test.dart `
                "--dart-define-from-file=$definesFile"
            $status = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        Say "flutter drive exited $status"
    } catch {
        Say "failed: $_"
    } finally {
        try { Restore-Display } catch { Say "failed: $_"; $status = 1 }
        "$status" | Out-File -Encoding ascii $exitFile
    }
    exit $status
}

if ($RestoreDisplay) {
    try { Restore-Display } finally { 'done' | Out-File -Encoding ascii (Join-Path $work 'restore.done') }
    exit 0
}

if ($Cleanup) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    # The console run, then its winshot: closing winshot's job ends flutter, the driver, the build and the app.
    $escaped = [regex]::Escape($work)
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match $escaped -and $_.CommandLine -match '-Console' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $displayFile) {
        $marker = Join-Path $work 'restore.done'
        Remove-Item $marker -ErrorAction SilentlyContinue
        Invoke-InConsole "$task-restore" '-RestoreDisplay' $marker 2
        if (Test-Path $displayFile) { throw "the display is still at the capture's mode; its old one is in $displayFile" }
    }
    # capture.sh's copy of the checkout, if it never got unpacked.
    Remove-Item (Join-Path (Split-Path $work) 'ompanion-shots.tgz') -ErrorAction SilentlyContinue
    if (-not $KeepClone) {
        # The app and the build may hold files for a moment after they end.
        for ($attempt = 0; $attempt -lt 10 -and (Test-Path $work); $attempt++) {
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
            if (Test-Path $work) { Start-Sleep -Seconds 2 }
        }
        if (Test-Path $work) { throw "$work could not be removed" }
    }
    exit 0
}

Write-Error 'usage: run.ps1 -Launch | -Console | -Cleanup [-KeepClone]'
exit 2
