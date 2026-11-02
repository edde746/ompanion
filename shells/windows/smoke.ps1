# The Windows half of smoke.sh, run over SSH from the folder smoke.sh copied to the leased host:
#
#   smoke.ps1           stops when the host has any com.edde746.ompanion app or data (the user's own ompanion), else
#                       unpacks app.tar and starts ompanion.exe with OMPCORE_SMOKE=1 and OMPCORE_LOG=out\smoke.log in
#                       the logged-on user's console session: a program started over SSH runs in session 0, which has
#                       no desktop, so an interactive-only scheduled task (schtasks /it) starts it, as tortuga's
#                       lab/win-remote does. Waits for it to exit (out\exit.txt)
#                       and exits with its exit code, or 124 after stopping it when it ran longer than -TimeoutSec.
#   smoke.ps1 -Cleanup  stops what a run left running, removes its task and this folder, and, when the run got past
#                       its check, what the app keeps on the host: %LOCALAPPDATA%\com.edde746.ompanion (the core's data
#                       and cache, WebView2's user data), the com.edde746.ompanion/* credentials a failed secret check
#                       leaves, and the toast registration.
param([switch]$Cleanup, [int]$TimeoutSec = 180)
$ErrorActionPreference = 'Stop'

$work = $PSScriptRoot
$app = Join-Path $work 'app'
$out = Join-Path $work 'out'
$exe = Join-Path $app 'ompanion.exe'
$task = 'OmpanionSmoke'
$checked = Join-Path $work 'checked' # the host had no ompanion data: what is there now is the run's
$appId = 'com.edde746.ompanion'
$data = Join-Path $env:LOCALAPPDATA $appId

# Every process started from this folder; one may have exited since the query.
function Stop-App {
    Get-CimInstance Win32_Process |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-Credentials {
    foreach ($line in cmdkey /list) {
        if ($line -match 'Target: (.*target=com\.edde746\.ompanion/.*)$') { $Matches[1].Trim() }
    }
}

if ($Cleanup) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    Stop-App
    $paths = @($work)
    if (Test-Path $checked) {
        foreach ($target in Get-Credentials) {
            cmdkey "/delete:$target" | Out-Null
            if ($LASTEXITCODE) { "cmdkey could not delete $target ($LASTEXITCODE)" }
        }
        # notifications.cpp's AppUserModelID and toast activator.
        foreach ($key in "HKCU:\Software\Classes\AppUserModelId\$appId",
            'HKCU:\Software\Classes\CLSID\{75884955-9AE9-4917-B244-95258D7AA2C7}') {
            if (Test-Path $key) { Remove-Item -Recurse -Force $key }
        }
        $paths += $data
    }
    # WebView2's processes may hold the user data for a moment after the app is gone.
    foreach ($path in $paths) {
        for ($attempt = 0; $attempt -lt 10 -and (Test-Path $path); $attempt++) {
            Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
            if (Test-Path $path) { Start-Sleep -Seconds 2 }
        }
        if (Test-Path $path) { throw "$path could not be removed" }
    }
    exit 0
}

$found = @((Join-Path $env:APPDATA 'com.edde746'), $data | Where-Object { Test-Path $_ }) + @(Get-Credentials) +
    @(Get-AppxPackage edde746.ompanion | ForEach-Object PackageFullName) +
    @("HKCU:\Software\Classes\AppUserModelId\$appId" | Where-Object { Test-Path $_ })
if ($found.Count) {
    "this host has ompanion's app or data, so nothing was run: $($found -join ', ')"
    exit 3
}
New-Item -ItemType File $checked | Out-Null

New-Item -ItemType Directory $app, $out | Out-Null
tar -xf (Join-Path $work 'app.tar') -C $app
if ($LASTEXITCODE) { throw "tar -xf app.tar failed ($LASTEXITCODE)" }

# The task runs with the console session's environment, so the smoke variables are set in its script. exit.txt is
# written whole and then renamed: the wait below never reads half of it.
$exitFile = Join-Path $out 'exit.txt'
$cmd = Join-Path $work 'smoke.cmd'
Set-Content -Path $cmd -Encoding ASCII -Value @(
    '@echo off',
    'set OMPCORE_SMOKE=1',
    "set `"OMPCORE_LOG=$out\smoke.log`"",
    "`"$exe`" > `"$out\stdout.txt`" 2> `"$out\stderr.txt`"",
    "> `"$exitFile.tmp`" echo %ERRORLEVEL%",
    "move /y `"$exitFile.tmp`" `"$exitFile`" > nul"
)

# conhost --headless: the cmd wrapper opens no console window on the desktop.
schtasks /create /tn $task /tr "conhost.exe --headless cmd /c `"$cmd`"" /sc once /st 23:59 /it /f | Out-Null
if ($LASTEXITCODE) { throw "schtasks /create failed ($LASTEXITCODE)" }
$started = Get-Date
try {
    schtasks /run /tn $task | Out-Null
    if ($LASTEXITCODE) { throw "schtasks /run failed ($LASTEXITCODE)" }
    $deadline = $started.AddSeconds($TimeoutSec)
    while (-not (Test-Path $exitFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
} finally {
    schtasks /delete /tn $task /f | Out-Null
}
$seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
if (-not (Test-Path $exitFile)) {
    Stop-App
    "the app was still running after $TimeoutSec s: stopped it"
    exit 124
}
$code = [int](Get-Content $exitFile -Raw).Trim()
"the app exited with $code after $seconds s"
exit $code
