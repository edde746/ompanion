import 'dart:convert';

import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'scripts.dart';

enum HostOs { macos, linux, windows, other }

/// Facts about a machine, from one probe. Paths are host-native (`C:\Users\x` on Windows).
final class HostProbe {
  const HostProbe({
    required this.commandShell,
    required this.os,
    required this.kernel,
    required this.arch,
    required this.home,
    required this.agentDir,
    this.libc,
    this.shell,
    this.profile,
    this.ompPath,
    this.ompVersion,
    this.curl = false,
    this.wget = false,
    this.sha256Tool,
    this.powershellVersion,
    this.localAppData,
    this.sshdVersion,
  });

  /// Parses the JSON that [toJson] writes.
  factory HostProbe.fromJson(Map<String, Object?> json) => HostProbe(
    commandShell: enumByName(CommandShell.values, json.string('commandShell')),
    os: enumByName(HostOs.values, json.string('os')),
    kernel: json.string('kernel'),
    arch: json.string('arch'),
    home: json.string('home'),
    agentDir: json.string('agentDir'),
    libc: json.optString('libc'),
    shell: json.optString('shell'),
    profile: json.optString('profile'),
    ompPath: json.optString('ompPath'),
    ompVersion: json.optString('ompVersion'),
    curl: json.optBool('curl') ?? false,
    wget: json.optBool('wget') ?? false,
    sha256Tool: json.optString('sha256Tool'),
    powershellVersion: json.optString('powershellVersion'),
    localAppData: json.optString('localAppData'),
    sshdVersion: json.optString('sshdVersion'),
  );

  /// How SSH exec parses commands on this machine.
  final CommandShell commandShell;
  final HostOs os;

  /// `uname -s`, or `Windows_NT`.
  final String kernel;

  /// `x64` or `arm64` (Rosetta-safe on macOS), otherwise the raw machine name.
  final String arch;

  /// `glibc` or `musl` on Linux, null elsewhere.
  final String? libc;

  /// The login shell (`$SHELL`); on Windows the OpenSSH `DefaultShell`, null meaning cmd.exe.
  final String? shell;
  final String home;

  /// omp's agent directory for the default environment (`PI_CODING_AGENT_DIR`, `OMP_PROFILE` honoured).
  final String agentDir;

  /// The active omp profile from `OMP_PROFILE`/`PI_PROFILE`, if any.
  final String? profile;

  /// Absolute path of the omp binary, null when none was found.
  final String? ompPath;

  /// `18.3.1` from `omp --version`.
  final String? ompVersion;
  final bool curl;
  final bool wget;

  /// `sha256sum`, `shasum`, `openssl` or `Get-FileHash`; null when the machine has none.
  final String? sha256Tool;

  /// Windows only.
  final String? powershellVersion;
  final String? localAppData;
  final String? sshdVersion;

  bool get isWindows => os == HostOs.windows;

  /// The omp release asset that runs here, e.g. `omp-linux-musl-arm64`; null when omp ships none.
  String? get releaseAsset {
    if (arch != 'x64' && arch != 'arm64') return null;
    return switch (os) {
      HostOs.macos => 'omp-darwin-$arch',
      HostOs.linux => libc == 'musl' ? 'omp-linux-musl-$arch' : 'omp-linux-$arch',
      HostOs.windows => 'omp-windows-$arch.exe',
      HostOs.other => null,
    };
  }

  Map<String, Object?> toJson() => {
    'commandShell': commandShell.name,
    'os': os.name,
    'kernel': kernel,
    'arch': arch,
    'home': home,
    'agentDir': agentDir,
    'libc': libc,
    'shell': shell,
    'profile': profile,
    'ompPath': ompPath,
    'ompVersion': ompVersion,
    'curl': curl,
    'wget': wget,
    'sha256Tool': sha256Tool,
    'powershellVersion': powershellVersion,
    'localAppData': localAppData,
    'sshdVersion': sshdVersion,
  };
}

/// Probes a machine. Without [commandShell] (first contact) a polyglot command decides how the machine's
/// SSH exec parses commands; a POSIX shell that turns out to run on Windows (MSYS, Cygwin) is followed by
/// the Windows probe, because omp there is the Windows build.
Future<HostProbe> probeHost(HostLink link, {CommandShell? commandShell}) async {
  final shell = commandShell ?? parseShellProbe((await runCommand(link, shellProbeCommand)).stdout);
  if (shell != CommandShell.posix) return _probeWindows(link, shell);
  final marker = newMarker();
  final result = await runPosixScript(link, posixProbeScript(marker));
  final probe = parsePosixProbe(result.payload(marker));
  return probe.os == HostOs.windows ? _probeWindows(link, CommandShell.posix) : probe;
}

Future<HostProbe> _probeWindows(HostLink link, CommandShell shell) async {
  final marker = newMarker();
  final result = await runPowerShell(link, shell, windowsProbeScript(marker));
  return parseWindowsProbe(result.payload(marker), shell);
}

/// Polyglot: POSIX shells print `%OS%` literally and expand `$env` to nothing, cmd.exe expands only `%OS%`,
/// PowerShell expands only `$env:OS`, and a POSIX shell on Windows (MSYS) also has `$OS` set. Dots separate
/// the fields because PowerShell parses them the same with or without the surrounding quotes.
const shellProbeCommand = r'echo "OMPAPP_SHELL.%OS%.$env:OS.$OS."';

/// Classifies the output of [shellProbeCommand]. Shells that print nothing usable (csh) still run `sh -s`,
/// so the fallback is [CommandShell.posix].
CommandShell parseShellProbe(String output) {
  const tag = 'OMPAPP_SHELL.';
  for (final line in const LineSplitter().convert(output)) {
    final at = line.indexOf(tag);
    if (at < 0) continue;
    final fields = line.substring(at + tag.length).replaceAll('"', '').trim().split('.');
    if (fields.first == 'Windows_NT') return CommandShell.cmd;
    if (fields.length > 1 && fields[1] == 'Windows_NT') return CommandShell.powershell;
    return CommandShell.posix;
  }
  return CommandShell.posix;
}

/// POSIX probe, printed as one JSON object of strings between marker lines. `LC_ALL=C` keeps `tr` and `sed`
/// from rejecting non-UTF-8 bytes in paths.
String posixProbeScript(String marker) => 'm=${shQuote(marker)}\n$_posixProbeBody';

const _posixProbeBody = r'''
LC_ALL=C; export LC_ALL
q() { v=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '"%s"' "$v"; }
o() { [ -n "$2" ] || return 0; printf ',"%s":' "$1"; q "$2"; }
has() { command -v "$1" >/dev/null 2>&1; }
kernel=$(uname -s 2>/dev/null)
machine=$(uname -m 2>/dev/null)
arm64=
if [ "$kernel" = Darwin ]; then
  arm64=$(sysctl -in hw.optional.arm64 2>/dev/null || /usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)
fi
libc=
if [ "$kernel" = Linux ]; then
  if [ -f /etc/alpine-release ] || ls /lib/ld-musl-* >/dev/null 2>&1 || { has ldd && ldd --version 2>&1 | grep -qi musl; }; then
    libc=musl
  else
    libc=glibc
  fi
fi
cfg="$HOME/${PI_CONFIG_DIR:-.omp}"
prof=${OMP_PROFILE-${PI_PROFILE-}}
if [ -n "$prof" ]; then agent="$cfg/profiles/$prof/agent"; else agent=${PI_CODING_AGENT_DIR:-$cfg/agent}; fi
omp=$(command -v omp 2>/dev/null)
case $omp in /*) ;; *) omp= ;; esac
if [ -z "$omp" ]; then
  for c in "$HOME/.local/bin/omp" /opt/homebrew/bin/omp /usr/local/bin/omp "$HOME/.bun/bin/omp"; do
    if [ -f "$c" ] && [ -x "$c" ]; then omp=$c; break; fi
  done
fi
ver=
if [ -n "$omp" ]; then ver=$("$omp" --version </dev/null 2>/dev/null | head -n 1); fi
sha=
if has sha256sum; then sha=sha256sum; elif has shasum; then sha=shasum; elif has openssl; then sha=openssl; fi
curl=; if has curl; then curl=1; fi
wget=; if has wget; then wget=1; fi
printf '\n%s:begin\n{"v":"1"' "$m"
o kernel "$kernel"; o machine "$machine"; o arm64 "$arm64"; o libc "$libc"; o shell "$SHELL"; o home "$HOME"
o agentDir "$agent"; o profile "$prof"; o omp "$omp"; o ompVersion "$ver"; o sha256 "$sha"; o curl "$curl"; o wget "$wget"
printf '}\n%s:end\n' "$m"
''';

/// Parses the payload of [posixProbeScript].
HostProbe parsePosixProbe(String payload) {
  final json = asJsonObject(jsonDecode(payload), 'probe');
  final kernel = json.optString('kernel') ?? '';
  final upper = kernel.toUpperCase();
  final os = switch (kernel) {
    'Darwin' => HostOs.macos,
    'Linux' => HostOs.linux,
    _ when upper.contains('MINGW') || upper.contains('MSYS') || upper.contains('CYGWIN') => HostOs.windows,
    _ => HostOs.other,
  };
  final machine = json.optString('machine') ?? '';
  final arch = os == HostOs.macos ? (json.optString('arm64') == '1' ? 'arm64' : 'x64') : normalizeArch(machine);
  return HostProbe(
    commandShell: CommandShell.posix,
    os: os,
    kernel: kernel,
    arch: arch,
    home: _required(json, 'home'),
    agentDir: _required(json, 'agentDir'),
    libc: json.optString('libc'),
    shell: json.optString('shell'),
    profile: json.optString('profile'),
    ompPath: json.optString('omp'),
    ompVersion: parseOmpVersion(json.optString('ompVersion')),
    curl: json.optString('curl') == '1',
    wget: json.optString('wget') == '1',
    sha256Tool: json.optString('sha256'),
  );
}

/// Windows probe. Architecture follows omp's install.ps1: `PROCESSOR_ARCHITEW6432` wins under WOW64.
String windowsProbeScript(String marker) => '\$m = ${psQuote(marker)}\n$_windowsProbeBody';

const _windowsProbeBody = r'''
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
$defaultShell = $null
try { $defaultShell = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell } catch { $defaultShell = $null }
$cfgName = '.omp'
if ($env:PI_CONFIG_DIR) { $cfgName = $env:PI_CONFIG_DIR }
$cfg = Join-Path $env:USERPROFILE $cfgName
$prof = $env:PI_PROFILE
if (Test-Path Env:OMP_PROFILE) { $prof = $env:OMP_PROFILE }
if ($prof) { $agent = Join-Path $cfg "profiles\$prof\agent" }
elseif ($env:PI_CODING_AGENT_DIR) { $agent = $env:PI_CODING_AGENT_DIR }
else { $agent = Join-Path $cfg 'agent' }
$omp = $null
$found = Get-Command -Name 'omp.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($found) { $omp = $found.Source }
if (-not $omp) {
  $candidates = @()
  if ($env:PI_INSTALL_DIR) { $candidates += Join-Path $env:PI_INSTALL_DIR 'omp.exe' }
  if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'omp\omp.exe' }
  $candidates += Join-Path $env:USERPROFILE '.bun\bin\omp.exe'
  $candidates += Join-Path $env:USERPROFILE '.local\bin\omp.exe'
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { $omp = $c; break } }
}
$ver = $null
if ($omp) { try { $ver = & $omp --version 2>$null | Select-Object -First 1 } catch { $ver = $null } }
$sshd = $null
foreach ($p in @((Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'), (Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'))) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { $sshd = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion; break }
}
$curl = $null
if (Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue) { $curl = '1' }
$o = [ordered]@{
  v = '1'; kernel = 'Windows_NT'; machine = $arch; shell = $defaultShell; home = $env:USERPROFILE
  agentDir = $agent; profile = $prof; omp = $omp; ompVersion = $ver; sha256 = 'Get-FileHash'; curl = $curl
  powershell = $PSVersionTable.PSVersion.ToString(); localAppData = $env:LOCALAPPDATA; sshd = $sshd
}
$json = ConvertTo-OmpAscii (ConvertTo-Json -InputObject $o -Compress)
[Console]::Out.Write("`n" + $m + ":begin`n" + $json + "`n" + $m + ":end`n")
''';

/// Parses the payload of [windowsProbeScript].
HostProbe parseWindowsProbe(String payload, CommandShell commandShell) {
  final json = asJsonObject(jsonDecode(payload), 'probe');
  return HostProbe(
    commandShell: commandShell,
    os: HostOs.windows,
    kernel: json.optString('kernel') ?? 'Windows_NT',
    arch: normalizeArch(json.optString('machine') ?? ''),
    home: _required(json, 'home'),
    agentDir: _required(json, 'agentDir'),
    shell: json.optString('shell'),
    profile: json.optString('profile'),
    ompPath: json.optString('omp'),
    ompVersion: parseOmpVersion(json.optString('ompVersion')),
    curl: json.optString('curl') == '1',
    sha256Tool: json.optString('sha256'),
    powershellVersion: json.optString('powershell'),
    localAppData: json.optString('localAppData'),
    sshdVersion: json.optString('sshd'),
  );
}

/// `x86_64`/`amd64` → `x64`, `aarch64`/`arm64` → `arm64`, anything else unchanged.
String normalizeArch(String machine) => switch (machine.toLowerCase()) {
  'x86_64' || 'amd64' || 'x64' => 'x64',
  'aarch64' || 'arm64' => 'arm64',
  _ => machine,
};

/// The version in `omp --version` output (`omp/18.3.1`), or null.
String? parseOmpVersion(String? output) =>
    output == null ? null : RegExp(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?').firstMatch(output)?.group(0);

String _required(Map<String, Object?> json, String key) {
  final value = json.optString(key);
  if (value == null || value.isEmpty) throw FormatException('probe: "$key" is empty');
  return value;
}
