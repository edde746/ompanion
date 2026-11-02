# The Windows app's end-to-end checks on a GitHub Windows runner, from the repo's root, in Windows PowerShell 5.1 (its
# WinRT projection reads the toast history):
#
#   ci.ps1 -App <dir> [-Seed <dir>]        build.sh's build\windows-<arch>, run as the zip's unpackaged app
#   ci.ps1 -Bundle <msixbundle> [-Seed <dir>]
#                                          msix\build-msix.ps1's bundle: signed here with a throwaway certificate of
#                                          the Store publisher's name, installed, and its app run with the package's
#                                          identity (the user environment carries the smoke variables to it)
#
# One smoke run (docs/contracts/bridge.md, Smoke runs) with every check, including those only a harness can drive:
# notify (after the app exited and the scheduled toast was due, the app's toast history must hold "shown now" and
# "scheduled" and neither "replaced" nor "cancelled"), paths (this script copies files, chooses in the open panels
# and drags files onto the window, test/Harness.cs), and with -Seed, the Flutter seed's Release folder
# (harness/flutter-seed/build.sh windows), flutter-import: the seed writes the Flutter app's data first (packaged:
# moved into the package's own view of %APPDATA%), and the run must import it as harness/flutter-seed/expected.json
# says. -NoDrop leaves the drag out of the paths check (windows-11-arm runners: a shell window keeps the front, so no
# drag can be made there; the drop code is the same C++ as x64's). Exits 0 when everything passed. The run's files
# stay in build\windows-ci\out (smoke.log, the app's stderr.txt). Removes what it made elsewhere: the app's data,
# credentials, registrations and toasts, the package and the certificate.
param([string]$App, [string]$Bundle, [string]$Seed, [int]$NotifySec = 60, [int]$TimeoutSec = 300, [switch]$NoDrop)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path $repo 'build\windows-ci'
$out = Join-Path $work 'out'
$appId = 'com.edde746.ompanion'
$flutterData = Join-Path $env:APPDATA 'com.edde746\ompanion'
$webData = Join-Path $env:LOCALAPPDATA $appId
$smokeVariables = 'OMPCORE_SMOKE', 'OMPCORE_LOG', 'OMPCORE_SMOKE_NOTIFY', 'OMPCORE_SMOKE_PATHS', 'OMPCORE_SMOKE_NO_DROP',
    'OMPCORE_EXPECT_IMPORT'
Add-Type -Path (Join-Path $PSScriptRoot 'test\Harness.cs') -ReferencedAssemblies System.Windows.Forms

function Get-Credentials {
    foreach ($line in cmdkey /list) {
        if ($line -match 'Target: (.*target=com\.edde746\.ompanion/.*)$') { $Matches[1].Trim() }
    }
}

function Assert-NoAppData {
    $left = @($flutterData, $webData | Where-Object { Test-Path $_ }) + @(Get-Credentials) +
        @(Get-AppxPackage edde746.ompanion | ForEach-Object PackageFullName)
    if ($left.Count) { throw "ompanion data is on this machine: $($left -join ', ')" }
}

function Remove-AppData {
    foreach ($target in Get-Credentials) { cmdkey "/delete:$target" | Out-Null }
    foreach ($key in "HKCU:\Software\Classes\AppUserModelId\$appId",
        'HKCU:\Software\Classes\CLSID\{75884955-9AE9-4917-B244-95258D7AA2C7}') {
        if (Test-Path $key) { Remove-Item -Recurse -Force $key }
    }
    foreach ($name in $smokeVariables) { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
    # The package takes its toasts along; the unpackaged app's stay in Action Center.
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($appId)
    Get-AppxPackage edde746.ompanion | Remove-AppxPackage
    # WebView2's processes may hold the user data for a moment after the app is gone.
    foreach ($path in $webData, (Split-Path $flutterData)) {
        for ($attempt = 0; $attempt -lt 10 -and (Test-Path $path); $attempt++) {
            Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
            if (Test-Path $path) { Start-Sleep -Seconds 2 }
        }
        if (Test-Path $path) { throw "$path could not be removed" }
    }
}

# The Windows SDK folder with makeappx (msix/build-msix.ps1 picks the same way) has signtool too.
function Get-SdkTool([string]$Name) {
    $tool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory |
        Where-Object { $_.Name -as [version] } | Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\$Name" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $tool) { throw "no $Name in the Windows SDK" }
    $tool
}

# Signs a copy of the bundle with a new self-signed certificate of the manifest's publisher, trusts it on this
# machine and installs the bundle; the package's family name.
function Install-Bundle {
    $cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=AA9C53CB-AD3C-48DA-B3E3-D1E8986D4E25' `
        -KeyUsage DigitalSignature -FriendlyName 'ompanion CI test' -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $script:certificate = $cert.Thumbprint
    $password = ConvertTo-SecureString -String 'ci' -Force -AsPlainText
    $pfx = Join-Path $work 'test.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $password | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $work 'test.cer') | Out-Null
    Import-Certificate -FilePath (Join-Path $work 'test.cer') -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' |
        Out-Null
    $signed = Join-Path $work 'ompanion-windows.msixbundle'
    Copy-Item $Bundle $signed
    & (Get-SdkTool 'signtool.exe') sign /q /fd SHA256 /f $pfx /p ci $signed
    if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }
    Add-AppxPackage -Path $signed
    $package = Get-AppxPackage edde746.ompanion
    "installed $($package.PackageFullName)"
    $script:family = $package.PackageFamilyName
}

function Remove-Certificate {
    if (-not $script:certificate) { return }
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\TrustedPeople') {
        Remove-Item (Join-Path $store $script:certificate) -ErrorAction SilentlyContinue
    }
}

# Runs the seed, which writes the Flutter app's database and secure storage to %APPDATA%\com.edde746\ompanion.
function Invoke-Seed {
    $seedOut = Join-Path $out 'seed.txt'
    $process = Start-Process -FilePath (Join-Path $Seed 'ompanion.exe') -RedirectStandardOutput $seedOut `
        -RedirectStandardError (Join-Path $out 'seed-stderr.txt') -PassThru
    if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'the seed ran over 120 s' }
    $line = Get-Content $seedOut | Where-Object { $_ -match '^(SEEDED|SEED-FAILED) ' } | Select-Object -Last 1
    if ($line -notmatch '^SEEDED ') { Get-Content $seedOut, (Join-Path $out 'seed-stderr.txt'); throw "the seed failed: $line" }
    "seed: $line"
    Get-ChildItem $flutterData | ForEach-Object { "  $($_.Name) $($_.Length)" }
}

# The SMOKE-STEP lines of the paths check, done once each while the app runs.
function Invoke-Steps([int]$ProcessId, [hashtable]$Done, [string]$Folder) {
    $log = Join-Path $out 'smoke.log'
    if (-not (Test-Path $log)) { return }
    foreach ($line in Get-Content $log) {
        if ($line -notmatch '^SMOKE-STEP (\S+)$' -or $Done.ContainsKey($Matches[1])) { continue }
        $step = $Matches[1]
        $Done[$step] = $true
        "step $step"
        switch ($step) {
            'pick-files' { [Harness]::Choose($ProcessId, '"a.txt" "b.txt"', 30000) }
            'pick-folder' { [Harness]::Choose($ProcessId, (Join-Path $Folder 'sub'), 30000) }
            'drop' {
                # A shell surface in front (Start, search; on windows-11-arm runners a WWAHost window) keeps the drag
                # from getting the mouse: it goes first.
                $pid_, $class = ([Harness]::Foreground()) -split ' ', 2
                $front = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
                "  in front: $($front.ProcessName) ($class)"
                if ($front -and $front.ProcessName -match '^(StartMenuExperienceHost|SearchHost|SearchApp|ShellExperienceHost|ShellHost|WWAHost)$') {
                    Stop-Process -Id $front.Id -Force
                    "  stopped $($front.ProcessName)"
                    Start-Sleep -Seconds 2
                }
                "  drop effect $([Harness]::Drag(@((Join-Path $Folder 'a.txt'), (Join-Path $Folder 'sub')), 3000))"
            }
            default { throw "unknown step $step" }
        }
    }
}

# The bodies of the toasts in the app's history (Action Center).
function Get-ToastBodies([string]$AppUserModelId) {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    foreach ($toast in [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($AppUserModelId)) {
        $texts = $toast.Content.GetElementsByTagName('text')
        $texts.Item($texts.Length - 1).InnerText
    }
}

New-Item -ItemType Directory -Force $work | Out-Null
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory $out | Out-Null
$folder = Join-Path $work 'paths'
New-Item -ItemType Directory -Force (Join-Path $folder 'sub') | Out-Null
Set-Content (Join-Path $folder 'a.txt') 'a'
Set-Content (Join-Path $folder 'b.txt') 'b'

Assert-NoAppData
$status = 1
try {
    if ($Bundle) { Install-Bundle }
    $appUserModelId = if ($Bundle) { "$family!ompanion" } else { $appId }
    if ($Seed) {
        Invoke-Seed
        if ($Bundle) {
            # Where Windows keeps the files a packaged app writes to %APPDATA%: the Flutter MSIX's data is there.
            $roaming = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalCache\Roaming\com.edde746"
            New-Item -ItemType Directory -Force $roaming | Out-Null
            Move-Item $flutterData $roaming
            "moved the seed's data to $roaming"
        }
    }

    [Harness]::CopyFiles(@((Join-Path $folder 'a.txt'), (Join-Path $folder 'sub')))
    $variables = @{
        OMPCORE_SMOKE = '1'
        OMPCORE_LOG = Join-Path $out 'smoke.log'
        OMPCORE_SMOKE_NOTIFY = "$NotifySec"
        OMPCORE_SMOKE_PATHS = $folder
    }
    if ($Seed) { $variables.OMPCORE_EXPECT_IMPORT = Join-Path $repo 'harness\flutter-seed\expected.json' }
    if ($NoDrop) {
        $variables.OMPCORE_SMOKE_NO_DROP = '1'
        'paths: drop skipped (-NoDrop: on this runner a shell window keeps the front, so no drag can be made; the drop is the same C++ as on x64, where it is proven)'
    }
    if ($Bundle) {
        # A packaged app gets the user's environment, not this process's.
        foreach ($name in $variables.Keys) { [Environment]::SetEnvironmentVariable($name, $variables[$name], 'User') }
        $process = Get-Process -Id ([Harness]::Activate($appUserModelId))
    } else {
        foreach ($name in $variables.Keys) { Set-Item "env:$name" $variables[$name] }
        $process = Start-Process -FilePath (Join-Path $App 'ompanion.exe') -PassThru `
            -RedirectStandardOutput (Join-Path $out 'stdout.txt') -RedirectStandardError (Join-Path $out 'stderr.txt')
        foreach ($name in $variables.Keys) { Remove-Item "env:$name" }
    }
    $null = $process.Handle # kept, so the exit code can be read after the exit
    "started process $($process.Id) as $appUserModelId"
    $steps = @{}
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
        Invoke-Steps $process.Id $steps $folder
        Start-Sleep -Milliseconds 250
    }
    $timedOut = -not $process.HasExited
    if ($timedOut) { $process.Kill() }
    $log = Join-Path $out 'smoke.log'
    $lines = @(if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^(SMOKE|shell timing)' } })
    $lines
    $stderr = Join-Path $out 'stderr.txt'
    if ((Test-Path $stderr) -and (Get-Item $stderr).Length) { "--- the app's stderr:"; Get-Content $stderr; '---' }
    if ($timedOut) { throw "the app was still running after $TimeoutSec s: stopped it" }
    "the app exited with $($process.ExitCode)"
    $done = $lines | Where-Object { $_ -match '^SMOKE-DONE ' }
    if ($process.ExitCode -ne 0 -or $done -notmatch '"passed": *(\d+), *"total": *(\d+)' -or $Matches[1] -ne $Matches[2]) {
        throw "the smoke run failed: $done"
    }

    # The scheduled toast comes at the notify check's atMs, while the app is gone.
    $notify = $lines | Where-Object { $_ -match '^SMOKE \{"check":"notify"' } | ForEach-Object { $_.Substring(6) | ConvertFrom-Json }
    if (-not $notify.atMs) { throw 'the notify check scheduled nothing' }
    $due = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$notify.atMs).LocalDateTime.AddSeconds(15)
    $wait = [math]::Max(0, ($due - (Get-Date)).TotalSeconds)
    "waiting $([math]::Round($wait)) s for the scheduled toast, the app having exited"
    Start-Sleep -Seconds $wait
    $bodies = @(Get-ToastBodies $appUserModelId)
    "toast history of $($appUserModelId): $($bodies -join ' | ')"
    foreach ($body in 'shown now', 'scheduled') {
        if ($bodies -notcontains $body) { throw "no toast `"$body`" in the history" }
    }
    foreach ($body in 'replaced', 'cancelled') {
        if ($bodies -contains $body) { throw "the toast `"$body`" came" }
    }

    if ($Seed) {
        $imported = if ($Bundle) { Join-Path $roaming 'ompanion' } else { $flutterData }
        "after the import, $($imported):"
        Get-ChildItem $imported | ForEach-Object { "  $($_.Name)" }
        if (-not (Test-Path (Join-Path $imported 'ompanion.sqlite.imported')) -or
            (Test-Path (Join-Path $imported 'flutter_secure_storage.dat'))) {
            throw 'the Flutter data was not cleared after the import'
        }
    }
    'ci.ps1: every check passed'
    $status = 0
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill() }
    Remove-AppData
    Remove-Certificate
    Remove-Item (Join-Path $work 'test.*')
}
exit $status
