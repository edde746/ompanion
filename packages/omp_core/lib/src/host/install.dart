import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// One omp release: SHA-256 digests of its assets, copied from the release's `SHA256SUMS.txt`.
final class OmpRelease {
  const OmpRelease(this.version, this.assets);

  final String version;

  /// Asset name → lowercase hex SHA-256.
  final Map<String, String> assets;

  Uri assetUrl(String asset) => Uri.https('github.com', '/can1357/oh-my-pi/releases/download/v$version/$asset');
}

/// Every omp release the app supports, oldest first.
const ompReleases = [
  OmpRelease('18.3.1', {
    'omp-darwin-arm64': '67b807a99454a4d8e1cf982dce7b3343b2c2fc148f33e403dbfb3f1049b22570',
    'omp-darwin-x64': 'f7ee52cc4d97c0c3af4b271dff940e2be31fe1e22d4fd125eda6e0c1bb97d5b0',
    'omp-linux-arm64': '95b9e3dc3c2096885be2c9c923bd45bb3bf81d172367db7e7090936729261e2c',
    'omp-linux-musl-arm64': 'f9fae7ccd077a0c386af6b979931c2875afcf79e53e230d3cbd1e19cfe6b3a8f',
    'omp-linux-musl-x64': '32a053aaabd3f0e24c513c52714594285cccc1c83057ebc7585c7b358a566db4',
    'omp-linux-x64': '0806df602bf2bb9b202d152204b1bef6450eb6bcbfbf31d66e3767d1bbb3b3a7',
    'omp-windows-arm64.exe': '401cab4f1f21ecff0952123103715976c0bdb115d676e74496a68bf012214537',
    'omp-windows-x64.exe': '66d1f0b193749782f119a776a2b02b0b71909c36ee12e8f1d310a3c53e66da26',
  }),
];

OmpRelease? ompRelease(String version) {
  for (final release in ompReleases) {
    if (release.version == version) return release;
  }
  return null;
}

/// Where omp's installers put the binary: `$HOME/.local/bin` (install.sh), `%LOCALAPPDATA%\omp`
/// (install.ps1). Host-native.
String defaultInstallDir(HostProbe probe) {
  if (!probe.isWindows) return '${probe.home}/.local/bin';
  final local = probe.localAppData;
  if (local == null) throw HostLinkException('LOCALAPPDATA is not set on ${probe.home}');
  return '$local\\omp';
}

/// How omp gets onto a machine.
enum InstallRoute {
  /// The machine downloads the pinned release asset itself: [posixInstallCommand], [windowsInstallCommand].
  download,

  /// The app downloads the release asset and uploads it over SFTP: [uploadOmp].
  upload,
}

/// Windows always has `Invoke-WebRequest`; a POSIX machine needs curl or wget, which stock Debian and Ubuntu
/// images lack.
InstallRoute installRoute(HostProbe probe) =>
    probe.isWindows || probe.curl || probe.wget ? InstallRoute.download : InstallRoute.upload;

/// The `sh` script that installs [version] on a POSIX host, shown in manual mode and run by automatic installs:
/// curl or wget downloads the pinned release asset next to the target, then it is checked and moved into
/// place as [uploadOmp] does. It runs in a subshell, so a failure in a pasted copy ends the script, not the
/// terminal. [assetBase] replaces the GitHub release URL in tests.
String posixInstallCommand(HostProbe probe, String version, {String? installDir, @visibleForTesting Uri? assetBase}) {
  final release = _release(version);
  final asset = _asset(probe, release);
  final url = assetBase?.resolve(asset) ?? release.assetUrl(asset);
  return '''
(
d=${shQuote(installDir ?? defaultInstallDir(probe))}; f="\$d/.omp-download-\$\$"; t="\$d/omp"
url=${shQuote('$url')}
want=${shQuote(release.assets[asset]!)}; v=${shQuote(version)}
$_posixFail$_posixDownloadBody$_posixPlaceBody)
''';
}

/// The PowerShell script that installs [version] on a Windows host, shown in manual mode and run by
/// automatic installs: `Invoke-WebRequest` downloads the pinned release asset next to the target, then it is
/// checked and moved into place as [uploadOmp] does. It runs in a script block, so its preferences do not
/// leak into a terminal it is pasted into. [assetBase] replaces the GitHub release URL in tests.
String windowsInstallCommand(HostProbe probe, String version, {String? installDir, @visibleForTesting Uri? assetBase}) {
  final release = _release(version);
  final asset = _asset(probe, release);
  final url = assetBase?.resolve(asset) ?? release.assetUrl(asset);
  return '''
& {
\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'
\$d = ${psQuote(installDir ?? defaultInstallDir(probe))}; \$m = "\$PID"; \$f = Join-Path \$d ".omp-download-\$m.exe"; \$t = Join-Path \$d 'omp.exe'
\$url = ${psQuote('$url')}
\$want = ${psQuote(release.assets[asset]!)}; \$v = ${psQuote(version)}
$_windowsDownloadBody$_windowsPlaceBody}
''';
}

/// Markers of this app's installs whose link dropped before they released `install.lock`. Each such lock still
/// holds a file named by its marker, so a later install from this app takes it over at once instead of waiting
/// until it is stale.
final _abandonedInstalls = <String>{};

/// Installs omp [version] from a release asset the app already downloaded ([asset], the bytes of
/// [HostProbe.releaseAsset]). Under a `mkdir` lock at `~/.omp-app/install.lock` it uploads the bytes next
/// to the target over SFTP, checks their SHA-256 on the host against [ompReleases], marks the file
/// executable, runs `--version`, and moves it over the target, so running omp processes keep their old
/// binary. A failed upload removes its partial file, and one left behind by an install that lost its link
/// is removed by the next. Returns the installed binary's host-native path.
Future<String> uploadOmp(
  HostLink link,
  HostProbe probe,
  String version, {
  required Stream<List<int>> asset,
  String? installDir,
  Duration lockTimeout = const Duration(minutes: 2),
  Duration staleLock = const Duration(hours: 1),
}) async {
  final release = _release(version);
  final assetName = _asset(probe, release);
  final digest = release.assets[assetName]!;
  final dir = installDir ?? defaultInstallDir(probe);
  final target = probe.isWindows ? '$dir\\omp.exe' : '$dir/omp';
  final files = await link.files();
  try {
    final lock = '${await ensureAppDir(files, '')}/install.lock';
    for (final abandoned in _abandonedInstalls.toList()) {
      if (await files.stat('$lock/$abandoned') == null) continue;
      await files.remove('$lock/$abandoned');
      await files.removeDir(lock);
      _abandonedInstalls.remove(abandoned);
    }
    await acquireDirLock(files, lock, timeout: lockTimeout, stale: staleLock);
    final marker = newMarker();
    final owner = '$lock/$marker';
    try {
      await files.write(owner, const []);
      final upload = probe.isWindows ? '$dir\\.omp-upload-$marker.exe' : '$dir/.omp-upload-$marker';
      final prepare = probe.isWindows
          ? await runPowerShell(link, probe.commandShell, 'New-Item -ItemType Directory -Force -Path ${psQuote(dir)} | Out-Null')
          : await runPosixScript(link, 'mkdir -p ${shQuote(dir)}');
      if (prepare.exit.code != 0) throw prepare.failure('cannot create $dir');
      final remoteDir = toSftpPath(dir);
      for (final entry in await files.list(remoteDir)) {
        // Uploads of installs that died; none runs while this one holds the lock.
        if (entry.name.startsWith('.omp-upload-')) await files.remove('$remoteDir/${entry.name}');
      }
      final remote = toSftpPath(upload);
      try {
        await _upload(files, remote, asset);
      } on Object catch (error, stack) {
        try {
          if (await files.stat(remote) != null) await files.remove(remote);
        } on Object {
          // The link is gone as well; the next install removes the partial upload.
          Error.throwWithStackTrace(error, stack);
        }
        rethrow;
      }
      final result = probe.isWindows
          ? await runPowerShell(link, probe.commandShell, _windowsPlaceScript(marker, upload, target, digest, version))
          : await runPosixScript(link, _posixPlaceScript(marker, upload, target, digest, version));
      if (result.exit.code != 0) throw result.failure('installing omp $version failed');
      return result.payload(marker);
    } finally {
      try {
        if (await files.stat(owner) != null) await files.remove(owner);
        await files.removeDir(lock);
      } on Object {
        _abandonedInstalls.add(marker);
        rethrow;
      }
    }
  } finally {
    await files.close();
  }
}

/// Streams [bytes] to [path] in 4 MiB appends, so a 200 MB binary is never held in memory at once.
Future<void> _upload(HostFiles files, String path, Stream<List<int>> bytes) async {
  const chunkSize = 4 << 20;
  final chunk = BytesBuilder(copy: false);
  var first = true;
  Future<void> flush() async {
    await files.write(path, chunk.takeBytes(), append: !first, mode: first ? 0x1C0 : null);
    first = false;
  }

  await for (final part in bytes) {
    chunk.add(part);
    if (chunk.length >= chunkSize) await flush();
  }
  if (first || chunk.length > 0) await flush();
}

String _posixPlaceScript(String marker, String upload, String target, String digest, String version) =>
    '''
m=${shQuote(marker)}; f=${shQuote(upload)}; t=${shQuote(target)}; want=${shQuote(digest)}; v=${shQuote(version)}
$_posixFail$_posixPlaceBody$_posixReport''';

/// The installed path between marker lines: the reply [uploadOmp] reads.
const _posixReport = r'''
printf '%s:begin\n%s\n%s:end\n' "$m" "$t" "$m"
''';

const _posixFail = r'''
fail() { echo "$1" >&2; rm -f "$f"; exit 1; }
''';

const _posixDownloadBody = r'''
mkdir -p "$d" || fail "cannot create $d"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$f" "$url" || fail "downloading $url failed"
elif command -v wget >/dev/null 2>&1; then
  wget -q -T 30 -O "$f" "$url" || fail "downloading $url failed"
else
  fail 'no curl or wget on this machine'
fi
''';

/// Checks the new binary `$f` against `$want`, runs it, and moves it to `$t`.
const _posixPlaceBody = r'''
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$f")
elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$f")
elif command -v openssl >/dev/null 2>&1; then got=$(openssl dgst -sha256 -r "$f")
else fail 'no sha256sum, shasum or openssl on this machine'; fi
got=${got%% *}
[ "$got" = "$want" ] || fail "SHA-256 mismatch: expected $want, got $got"
chmod 755 "$f" || fail "chmod failed"
out=$("$f" --version </dev/null 2>&1) || fail "the new binary does not start: $out"
case $out in *"$v"*) ;; *) fail "the new binary reports $out, expected $v" ;; esac
mv -f "$f" "$t" || fail "cannot move the binary to $t"
''';

String _windowsPlaceScript(String marker, String upload, String target, String digest, String version) =>
    '''
\$m = ${psQuote(marker)}; \$f = ${psQuote(upload)}; \$t = ${psQuote(target)}; \$want = ${psQuote(digest)}; \$v = ${psQuote(version)}
$_windowsPlaceBody$_windowsReport''';

const _windowsReport = r'''
[Console]::Out.Write($m + ":begin`n" + (ConvertTo-OmpAscii $t) + "`n" + $m + ":end`n")
''';

const _windowsDownloadBody = r'''
New-Item -ItemType Directory -Force -Path $d | Out-Null
try {
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -Uri $url -OutFile $f
} catch {
  Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  throw
}
''';

/// Checks the new binary `$f` against `$want`, runs it, and moves it to `$t`. A running omp.exe cannot be
/// overwritten but can be renamed, so an existing target is moved aside first (omp's own `omp update` does
/// the same).
const _windowsPlaceBody = r'''
try {
  $got = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($got -ne $want) { throw "SHA-256 mismatch: expected $want, got $got" }
  $out = (& $f --version 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "the new binary does not start: $out" }
  if (-not $out.Contains($v)) { throw "the new binary reports $out, expected $v" }
  if (Test-Path -LiteralPath $t) {
    $old = "$t.old-$m"
    Move-Item -LiteralPath $t -Destination $old -Force
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
  }
  Move-Item -LiteralPath $f -Destination $t -Force
} catch {
  Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  throw
}
''';

OmpRelease _release(String version) =>
    ompRelease(version) ?? (throw ArgumentError.value(version, 'version', 'no digests for this omp release'));

String _asset(HostProbe probe, OmpRelease release) {
  final asset = probe.releaseAsset;
  if (asset == null || !release.assets.containsKey(asset)) {
    throw HostLinkException('omp ${release.version} has no build for ${probe.kernel} ${probe.arch}');
  }
  return asset;
}
