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
    this.loginPath,
    this.loginProblem,
    this.curl = false,
    this.wget = false,
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
    loginPath: json.optString('loginPath'),
    loginProblem: json.optString('loginProblem'),
    curl: json.optBool('curl') ?? false,
    wget: json.optBool('wget') ?? false,
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

  /// Absolute path of the omp binary the app drives, null when none was found. The probe looks on PATH and in
  /// the install locations and takes the first omp at least [minimumOmpVersion], else the first one it found.
  final String? ompPath;

  /// `18.3.1` from `omp --version`.
  final String? ompVersion;

  /// The `PATH` the account's login shell gives its own children, read with `$SHELL -l -i -c` (an interactive
  /// login shell, what a terminal runs); null when the probe could not read one ([loginProblem] says which way
  /// it failed), which is always the case on Windows.
  final String? loginPath;

  /// Why [loginPath] is null on a POSIX machine: no login shell, one that answered with no `PATH`, or no
  /// temporary file to take its answer.
  final String? loginProblem;

  final bool curl;
  final bool wget;

  /// Windows only.
  final String? powershellVersion;
  final String? localAppData;
  final String? sshdVersion;

  bool get isWindows => os == HostOs.windows;

  /// The shell statement that puts [loginPath] in front of a launch script's `PATH`, for a script that starts
  /// omp directly; empty when the probe read none. The login PATH goes first and the script's own `PATH`
  /// (sshd's, or launchd's on this computer) stays behind it, so the script keeps resolving the tools it
  /// uses itself.
  String get loginPathExport => loginPath == null ? '' : 'PATH=${shQuote('$loginPath:')}"\$PATH"; export PATH';

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
    'loginPath': loginPath,
    'loginProblem': loginProblem,
    'curl': curl,
    'wget': wget,
    'powershellVersion': powershellVersion,
    'localAppData': localAppData,
    'sshdVersion': sshdVersion,
  };
}

/// Probes a machine. Without [commandShell] (first contact) a polyglot command decides how the machine's
/// SSH exec parses commands; a POSIX shell that turns out to run on Windows (MSYS, Cygwin) is followed by
/// the Windows probe, because omp there is the Windows build. With [searchSystemPaths] false omp is looked
/// for only in the install locations under the home directory, never on PATH or in system directories
/// such as `/opt/homebrew/bin`, so a machine with an isolated home never runs the user's own omp.
Future<HostProbe> probeHost(HostLink link, {CommandShell? commandShell, bool searchSystemPaths = true}) async {
  final shell = commandShell ?? parseShellProbe((await runCommand(link, shellProbeCommand)).stdout);
  if (shell != CommandShell.posix) return _probeWindows(link, shell, searchSystemPaths);
  final marker = newMarker();
  final result = await runPosixScript(link, posixProbeScript(marker, searchSystemPaths: searchSystemPaths));
  final probe = parsePosixProbe(result.payload(marker));
  return probe.os == HostOs.windows ? _probeWindows(link, CommandShell.posix, searchSystemPaths) : probe;
}

Future<HostProbe> _probeWindows(HostLink link, CommandShell shell, bool searchSystemPaths) async {
  final marker = newMarker();
  final result = await runPowerShell(link, shell, windowsProbeScript(marker, searchSystemPaths: searchSystemPaths));
  return parseWindowsProbe(result.payload(marker), shell);
}

/// Polyglot: POSIX shells print `%OS%` literally and expand `$env` to nothing, cmd.exe expands only `%OS%`,
/// PowerShell expands only `$env:OS`, and a POSIX shell on Windows (MSYS) also has `$OS` set. Dots separate
/// the fields because PowerShell parses them the same with or without the surrounding quotes.
const shellProbeCommand = r'echo "OMPANION_SHELL.%OS%.$env:OS.$OS."';

/// Classifies the output of [shellProbeCommand]. Shells that print nothing usable (csh) still run `sh -s`,
/// so the fallback is [CommandShell.posix].
CommandShell parseShellProbe(String output) {
  const tag = 'OMPANION_SHELL.';
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

/// POSIX probe, printed as one JSON object between marker lines. `LC_ALL=C` keeps `tr` and `sed` from
/// rejecting non-UTF-8 bytes in paths. `omps` lists the omp on PATH and the first other one in the install
/// locations, `~/.local/bin` first (where both installers and `uploadOmp` put it), each with the first
/// line of its `--version`; [parsePosixProbe] picks one. The probe also asks the login shell for its `PATH`
/// ([HostProbe.loginPath]) and waits at most `loginWait` tenths of a second for each of its two attempts.
String posixProbeScript(String marker, {bool searchSystemPaths = true, int loginWait = 50}) =>
    'm=${shQuote(marker)}; sys=${searchSystemPaths ? '1' : ''}; lwait=$loginWait\n$_posixProbeBody';

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
# A terminal's shell is a login and interactive one, and that is where the user's PATH comes from: Homebrew's
# shellenv and path_helper in .zprofile, ~/.local/bin, version managers and Android in .zshrc/.bashrc. The exec
# channel this probe runs on is neither, so a program started from it sees sshd's default PATH, which is
# missing all of that. Ask the login shell for the PATH its own children get, in the account's home directory
# (the app may run omp with another HOME, e.g. an isolated one, which must not change the answer). `printenv
# PATH` is read instead of "$PATH" because fish joins its PATH list into the exported, colon-separated
# variable; nothing else of the shell's environment is printed, since an rc may export secrets. The answer
# arrives between markers in a mktemp file, so rc noise (motd, echoes, prompts, .zcompdump) cannot corrupt it
# and no one can plant the file; a shell that never answers is killed after lwait tenths of a second.
llogin=
lwhy=
luser=$(id -un 2>/dev/null)
lrow=
if has getent; then lrow=$(getent passwd "$luser" 2>/dev/null); fi
lhome=
if [ -n "$lrow" ]; then lhome=$(printf '%s' "$lrow" | cut -d: -f6); fi
if [ -z "$lhome" ] && has dscl; then lhome=$(dscl . -read "/Users/$luser" NFSHomeDirectory 2>/dev/null | cut -d' ' -f2-); fi
lshell=${SHELL:-}
if [ -n "$lshell" ] && [ ! -x "$lshell" ]; then lshell=; fi
if [ -z "$lshell" ] && [ -n "$lrow" ]; then lshell=$(printf '%s' "$lrow" | cut -d: -f7); fi
if [ -z "$lshell" ] && has dscl; then lshell=$(dscl . -read "/Users/$luser" UserShell 2>/dev/null | cut -d' ' -f2-); fi
if [ -z "$lhome" ]; then lhome=$HOME; fi
case $lhome in /*) ;; *) lhome=$HOME ;; esac
# A POSIX shell on Windows: the Windows probe that follows replaces this one, and omp there keeps its PATH.
case $kernel in *MINGW* | *MSYS* | *CYGWIN*) lshell= ;; esac
if [ -z "$lshell" ] || [ ! -x "$lshell" ]; then
  lwhy='no login shell'
elif ! lout=$(mktemp "${TMPDIR:-/tmp}/ompanion-login.XXXXXX" 2>/dev/null); then
  lwhy="cannot create a temporary file in ${TMPDIR:-/tmp}"
else
  lm=login-$m
  ltry() {
    : >"$lout"
    HOME="$lhome" "$lshell" "$@" "printf '\n%s\n' $lm; printenv PATH; printf '%s\n' $lm" </dev/null >"$lout" 2>/dev/null &
    lp=$!
    ln=0
    while [ "$(grep -c "$lm" "$lout" 2>/dev/null)" -lt 2 ] && kill -0 $lp 2>/dev/null && [ $ln -lt $lwait ]; do
      sleep 0.1 2>/dev/null || sleep 1
      ln=$((ln + 1))
    done
    kill $lp 2>/dev/null
    lk=0
    while kill -0 $lp 2>/dev/null && [ $lk -lt 10 ]; do
      sleep 0.1 2>/dev/null || sleep 1
      lk=$((lk + 1))
    done
    kill -9 $lp 2>/dev/null
    llogin=$(awk -v m="$lm" '$0 == m { if (n == 2) { print p; exit } n = 1; next } n == 1 { p = $0; n = 2; next } n == 2 { exit }' "$lout")
    if [ -z "$llogin" ]; then lwhy='the login shell reported no PATH'; else lwhy=; fi
  }
  ltry -l -i -c
  if [ -z "$llogin" ]; then ltry -l -c; fi
  rm -f "$lout"
fi
p=
if [ -n "$sys" ]; then
  p=$(command -v omp 2>/dev/null)
  case $p in /*) ;; *) p= ;; esac
  set -- "$HOME/.local/bin/omp" /opt/homebrew/bin/omp /usr/local/bin/omp "$HOME/.bun/bin/omp"
else
  set -- "$HOME/.local/bin/omp" "$HOME/.bun/bin/omp"
fi
c=
for x in "$@"; do
  if [ "$x" != "$p" ] && [ -f "$x" ] && [ -x "$x" ]; then c=$x; break; fi
done
ver() { "$1" --version </dev/null 2>/dev/null | head -n 1; }
pv=; if [ -n "$p" ]; then pv=$(ver "$p"); fi
cv=; if [ -n "$c" ]; then cv=$(ver "$c"); fi
e() { printf '{"path":'; q "$1"; printf ',"version":'; q "$2"; printf '}'; }
curl=; if has curl; then curl=1; fi
wget=; if has wget; then wget=1; fi
printf '\n%s:begin\n{"v":"1"' "$m"
o kernel "$kernel"; o machine "$machine"; o arm64 "$arm64"; o libc "$libc"; o shell "$SHELL"; o home "$HOME"
o agentDir "$agent"; o profile "$prof"; o curl "$curl"; o wget "$wget"
o loginPath "$llogin"; o loginProblem "$lwhy"
printf ',"omps":['
if [ -n "$p" ]; then e "$p" "$pv"; fi
if [ -n "$p" ] && [ -n "$c" ]; then printf ','; fi
if [ -n "$c" ]; then e "$c" "$cv"; fi
printf ']}\n%s:end\n' "$m"
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
  final omp = _pickOmp(json.objects('omps'));
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
    ompPath: omp?.path,
    ompVersion: omp?.version,
    loginPath: json.optString('loginPath'),
    loginProblem: json.optString('loginProblem'),
    curl: json.optString('curl') == '1',
    wget: json.optString('wget') == '1',
  );
}

/// Windows probe. Architecture follows omp's install.ps1: `PROCESSOR_ARCHITEW6432` wins under WOW64. `omps`
/// lists omp on PATH and the first other one in the install locations, as [posixProbeScript] does.
String windowsProbeScript(String marker, {bool searchSystemPaths = true}) =>
    '\$m = ${psQuote(marker)}; \$sys = \$$searchSystemPaths\n$_windowsProbeBody';

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
if ($sys) {
  $found = Get-Command -Name 'omp.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { $omp = $found.Source }
}
$candidates = @()
if ($env:PI_INSTALL_DIR) { $candidates += Join-Path $env:PI_INSTALL_DIR 'omp.exe' }
if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'omp\omp.exe' }
$candidates += Join-Path $env:USERPROFILE '.bun\bin\omp.exe'
$candidates += Join-Path $env:USERPROFILE '.local\bin\omp.exe'
$other = $null
foreach ($c in $candidates) { if ($c -ne $omp -and (Test-Path -LiteralPath $c -PathType Leaf)) { $other = $c; break } }
$omps = @(foreach ($c in @($omp, $other)) {
  if ($c) {
    $ver = $null
    try { $ver = & $c --version 2>$null | Select-Object -First 1 } catch { $ver = $null }
    [pscustomobject]@{ path = $c; version = $ver }
  }
})
$sshd = $null
foreach ($p in @((Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'), (Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'))) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { $sshd = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion; break }
}
$curl = $null
if (Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue) { $curl = '1' }
$o = [ordered]@{
  v = '1'; kernel = 'Windows_NT'; machine = $arch; shell = $defaultShell; home = $env:USERPROFILE
  agentDir = $agent; profile = $prof; omps = $omps; curl = $curl
  powershell = $PSVersionTable.PSVersion.ToString(); localAppData = $env:LOCALAPPDATA; sshd = $sshd
}
$json = ConvertTo-OmpAscii (ConvertTo-Json -InputObject $o -Compress -Depth 4)
[Console]::Out.Write("`n" + $m + ":begin`n" + $json + "`n" + $m + ":end`n")
''';

/// Parses the payload of [windowsProbeScript].
HostProbe parseWindowsProbe(String payload, CommandShell commandShell) {
  final json = asJsonObject(jsonDecode(payload), 'probe');
  final omp = _pickOmp(json.objects('omps'));
  return HostProbe(
    commandShell: commandShell,
    os: HostOs.windows,
    kernel: json.optString('kernel') ?? 'Windows_NT',
    arch: normalizeArch(json.optString('machine') ?? ''),
    home: _required(json, 'home'),
    agentDir: _required(json, 'agentDir'),
    shell: json.optString('shell'),
    profile: json.optString('profile'),
    ompPath: omp?.path,
    ompVersion: omp?.version,
    curl: json.optString('curl') == '1',
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

/// The oldest omp the app drives.
const minimumOmpVersion = '18.3.1';

/// Orders `major.minor.patch[-pre]` versions; a pre-release sorts before its release.
int compareOmpVersions(String a, String b) {
  (List<int>, String?) parse(String version) {
    final dash = version.indexOf('-');
    final core = dash < 0 ? version : version.substring(0, dash);
    final parts = core.split('.').map(int.parse).toList();
    if (parts.length != 3) throw FormatException('not a major.minor.patch version', version);
    return (parts, dash < 0 ? null : version.substring(dash + 1));
  }

  final (coreA, preA) = parse(a);
  final (coreB, preB) = parse(b);
  for (var i = 0; i < 3; i++) {
    final order = coreA[i].compareTo(coreB[i]);
    if (order != 0) return order;
  }
  if (preA == preB) return 0;
  if (preA == null) return 1;
  if (preB == null) return -1;
  return preA.compareTo(preB);
}

/// The omp the app drives out of those a probe found, in search order: the first one at least
/// [minimumOmpVersion], else the first one, whose problem the app then reports. So an older omp on PATH
/// gives way to the one an install put into the install directory.
({String path, String? version})? _pickOmp(List<Map<String, Object?>> found) {
  final omps = [
    for (final omp in found) (path: omp.string('path'), version: parseOmpVersion(omp.optString('version'))),
  ];
  for (final omp in omps) {
    final version = omp.version;
    if (version != null && compareOmpVersions(version, minimumOmpVersion) >= 0) return omp;
  }
  return omps.firstOrNull;
}

String _required(Map<String, Object?> json, String key) {
  final value = json.optString(key);
  if (value == null || value.isEmpty) throw FormatException('probe: "$key" is empty');
  return value;
}
