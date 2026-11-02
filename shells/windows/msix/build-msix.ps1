#!/usr/bin/env pwsh
# Packs the Windows app that shells/windows/build.sh built into the release's two Windows files, under
# build\windows-package\:
#
#   ompanion-windows.msixbundle  the Microsoft Store package: every architecture that was built (build\windows-x64,
#                                build\windows-arm64), unsigned. The Store re-signs after certification, and a package
#                                signed with any other certificate fails publisher-identity validation.
#   ompanion-windows-x64.zip     the GitHub release's download: build\windows-x64 as it is.
#
# Needs the Windows SDK's makeappx.exe and makepri.exe. -EmitManifestOnly writes the generated AppxManifest.<arch>.xml
# files and stops, so they can be inspected without the SDK or a build.

param(
    [string]$X64BuildDir,
    [string]$Arm64BuildDir,
    [switch]$EmitManifestOnly
)

function ConvertTo-MsixVersion {
    param([Parameter(Mandatory)][string]$Version)

    # The Store reserves the fourth (revision) field, so VERSION's major.minor.patch+build maps to major.minor.patch.0
    # and the build number is dropped. Two releases differing only by build number therefore collide in the Store:
    # every submission needs a semver bump.
    $Semver = ($Version -split '\+')[0]
    if ($Semver -notmatch '^\d+\.\d+\.\d+$') {
        throw "Version must be major.minor.patch, optionally with +build metadata; got '$Version'"
    }
    return "$Semver.0"
}

function New-AppxManifest {
    param(
        [Parameter(Mandatory)][string]$MsixVersion,
        [Parameter(Mandatory)][string]$Architecture
    )

    # Copied from Partner Center's Product management -> Product identity for Store ID 9P9DVTKZ3SB9 (package family
    # name edde746.ompanion_13q3sv6jzathm); Store validation rejects the upload if any of the three differs by a single
    # character. The schema constrains Identity/@Name to '[-.A-Za-z0-9]+', so it can never carry an underscore.
    $IdentityName = "edde746.ompanion"
    $Publisher = "CN=AA9C53CB-AD3C-48DA-B3E3-D1E8986D4E25"
    $PublisherDisplayName = "edde746"
    # The toast activator's COM class (src/notifications.cpp): a click on a toast reaches the running app through it,
    # or starts the app first.
    $ToastActivator = "75884955-9AE9-4917-B244-95258D7AA2C7"

    # One template for every architecture, which can therefore not drift apart; ProcessorArchitecture is the only
    # difference between them.
    #
    # Child element order is fixed by the foundation schema and makeappx rejects a reordered manifest: Identity,
    # Properties, Resources, Dependencies, Capabilities, Applications. Resources sitting before Dependencies is the
    # opposite of what older Visual Studio UWP templates used - do not tidy it.
    #
    # runFullTrust is restricted (hence rescap) and standard for a packaged Win32 app: it runs omp and shells on this
    # computer as child processes. Those children carry no package identity, so they read and write the real AppData,
    # and unvirtualizedResources is not needed. privateNetworkClientServer covers SSH to machines on the LAN: a
    # full-trust package is not AppContainer-isolated, but certification looks for declared network intent.
    return @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"
         xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/windows10"
         IgnorableNamespaces="uap rescap com desktop">

  <Identity Name="$IdentityName"
            Publisher="$Publisher"
            Version="$MsixVersion"
            ProcessorArchitecture="$Architecture" />

  <Properties>
    <DisplayName>ompanion</DisplayName>
    <PublisherDisplayName>$PublisherDisplayName</PublisherDisplayName>
    <Logo>assets\StoreLogo.png</Logo>
  </Properties>

  <Resources>
    <Resource Language="en-us" />
  </Resources>

  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop"
                        MinVersion="10.0.17763.0"
                        MaxVersionTested="10.0.26100.0" />
  </Dependencies>

  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
    <Capability Name="internetClient" />
    <Capability Name="privateNetworkClientServer" />
  </Capabilities>

  <Applications>
    <Application Id="ompanion" Executable="ompanion.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="ompanion"
                          Description="A client for omp, the oh-my-pi coding agent"
                          BackgroundColor="transparent"
                          Square150x150Logo="assets\Square150x150Logo.png"
                          Square44x44Logo="assets\Square44x44Logo.png">
        <uap:DefaultTile Wide310x150Logo="assets\Wide310x150Logo.png"
                         Square310x310Logo="assets\Square310x310Logo.png" />
        <uap:SplashScreen Image="assets\SplashScreen.png" />
      </uap:VisualElements>
      <Extensions>
        <desktop:Extension Category="windows.toastNotificationActivation">
          <desktop:ToastNotificationActivation ToastActivatorCLSID="$ToastActivator" />
        </desktop:Extension>
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:ExeServer Executable="ompanion.exe" DisplayName="ompanion">
              <com:Class Id="$ToastActivator" DisplayName="ompanion toast activator" />
            </com:ExeServer>
          </com:ComServer>
        </com:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
"@
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    # The manifest declares encoding="utf-8", and Out-File -Encoding utf8 writes a BOM on Windows PowerShell but not
    # on pwsh 7. Write the bytes directly so the manifest is identical whichever host runs this script.
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-SdkTool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # $ErrorActionPreference does not apply to native executables, so every SDK tool call goes through this one
    # checked invocation.
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path -Leaf $Tool) $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
Set-Location $ProjectRoot

# VERSION is the one every platform ships.
$MsixVersion = ConvertTo-MsixVersion -Version (Get-Content "VERSION" -TotalCount 1).Trim()
Write-Host "Package version: $MsixVersion" -ForegroundColor Green
# makeappx accepts a first field of 0; Partner Center does not ("App package requirements for MSIX app", Package
# version numbering).
if ($MsixVersion.StartsWith("0.")) {
    Write-Host "::warning title=Store version::Partner Center rejects package version $MsixVersion because its first field is 0. Set VERSION to 1.0.0 or later before submitting this bundle."
}

$OutputDir = Join-Path $ProjectRoot "build\windows-package"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# The manifest does not vary with which architectures were built, so the inspection path always emits both.
if ($EmitManifestOnly) {
    foreach ($Architecture in @("x64", "arm64")) {
        $EmittedManifest = Join-Path $OutputDir "AppxManifest.$Architecture.xml"
        Write-Utf8File -Path $EmittedManifest `
            -Content (New-AppxManifest -MsixVersion $MsixVersion -Architecture $Architecture)
        Write-Host "Created: $EmittedManifest" -ForegroundColor Green
    }
    exit 0
}

if (-not $X64BuildDir -and (Test-Path "build\windows-x64\ompanion.exe")) { $X64BuildDir = "build\windows-x64" }
if (-not $Arm64BuildDir -and (Test-Path "build\windows-arm64\ompanion.exe")) { $Arm64BuildDir = "build\windows-arm64" }

$BuildDirs = [ordered]@{}
if ($X64BuildDir) { $BuildDirs["x64"] = $X64BuildDir }
if ($Arm64BuildDir) { $BuildDirs["arm64"] = $Arm64BuildDir }
if (-not $BuildDirs.Contains("x64")) {
    throw "No x64 build: run shells/windows/build.sh x64 [arm64] first, or pass -X64BuildDir."
}
foreach ($Architecture in $BuildDirs.Keys) {
    if (-not (Test-Path (Join-Path $BuildDirs[$Architecture] "ompanion.exe"))) {
        throw "$($BuildDirs[$Architecture]) holds no ompanion.exe"
    }
    Write-Host "$($Architecture): $($BuildDirs[$Architecture])"
}

# The newest kit that ships both tools wins; older installed kits are frequently partial.
$SdkRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
$SdkBin = $null
if (Test-Path $SdkRoot) {
    $SdkBin = Get-ChildItem $SdkRoot -Directory |
        Where-Object { $_.Name -as [version] } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64" } |
        Where-Object { (Test-Path (Join-Path $_ "makeappx.exe")) -and (Test-Path (Join-Path $_ "makepri.exe")) } |
        Select-Object -First 1
}
if (-not $SdkBin) {
    throw "makeappx.exe and makepri.exe not found under $SdkRoot. Install the Windows 10/11 SDK, or run with -EmitManifestOnly to inspect the manifests."
}
$MakeAppx = Join-Path $SdkBin "makeappx.exe"
$MakePri = Join-Path $SdkBin "makepri.exe"
Write-Host "Using $SdkBin" -ForegroundColor Cyan

$Zip = Join-Path $OutputDir "ompanion-windows-x64.zip"
Remove-Item $Zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $BuildDirs["x64"] "*") -DestinationPath $Zip
Write-Host "Created: $Zip" -ForegroundColor Green

# Stage payload, assets and manifest per architecture. The .msix packages are collected in a sibling directory
# because makeappx bundle treats every file under its /d directory as a package to bundle.
$StagingRoot = Join-Path $OutputDir "staging"
$PackageDir = Join-Path $StagingRoot "packages"
if (Test-Path $StagingRoot) { Remove-Item $StagingRoot -Recurse -Force }
New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null

# The resource index that makes the qualified assets resolvable. Without it the targetsize/altform-unplated logos are
# inert payload, and the shell plates the taskbar icon with the user's accent colour. Kept outside the staged payload
# so it is not packed. autoResourcePackage would move qualified assets out into resource-package indexes that a
# per-architecture .msix never carries, so the shell would stop finding them; strip that.
$PriConfig = Join-Path $StagingRoot "priconfig.xml"
Invoke-SdkTool -Tool $MakePri -Arguments @("createconfig", "/cf", $PriConfig, "/dq", "en-US", "/o")
$PriConfigXml = [xml](Get-Content $PriConfig)
$Packaging = $PriConfigXml.resources.packaging
if ($Packaging) {
    $PriConfigXml.resources.RemoveChild($Packaging) | Out-Null
    $PriConfigXml.Save($PriConfig)
}

foreach ($Architecture in $BuildDirs.Keys) {
    Write-Host "Staging $Architecture..." -ForegroundColor Cyan
    $Staging = Join-Path $StagingRoot $Architecture
    New-Item -ItemType Directory -Path $Staging -Force | Out-Null
    Copy-Item -Path "$($BuildDirs[$Architecture])\*" -Destination $Staging -Recurse
    Copy-Item -Path (Join-Path $PSScriptRoot "assets") -Destination $Staging -Recurse

    Write-Utf8File -Path (Join-Path $Staging "AppxManifest.xml") `
        -Content (New-AppxManifest -MsixVersion $MsixVersion -Architecture $Architecture)

    # Indexed after the manifest is in place: makepri reads the package identity from it.
    Invoke-SdkTool -Tool $MakePri -Arguments @(
        "new", "/pr", $Staging, "/cf", $PriConfig, "/of", (Join-Path $Staging "resources.pri"), "/o"
    )
    Invoke-SdkTool -Tool $MakeAppx -Arguments @(
        "pack", "/d", $Staging, "/p", (Join-Path $PackageDir "ompanion-$Architecture.msix"), "/o"
    )
}

$Bundle = Join-Path $OutputDir "ompanion-windows.msixbundle"
Invoke-SdkTool -Tool $MakeAppx -Arguments @(
    "bundle", "/d", $PackageDir, "/p", $Bundle, "/bv", $MsixVersion, "/o"
)
Remove-Item $StagingRoot -Recurse -Force

Write-Host "Architectures: $($BuildDirs.Keys -join ', ')" -ForegroundColor White
Write-Host "Store package: $Bundle (unsigned: the Store signs it during certification)" -ForegroundColor White
Write-Host "Zip:           $Zip" -ForegroundColor White
