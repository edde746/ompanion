import 'dart:convert';

import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// One omp session file on a machine, from its fixed-width title slot and its header line.
final class SessionSummary {
  const SessionSummary({
    required this.path,
    required this.size,
    required this.modified,
    required this.id,
    this.profile,
    this.title,
    this.titleSource,
    this.cwd,
    this.created,
    this.parentSession,
    this.version,
    this.firstMessage,
    this.runId,
  });

  /// Host-native absolute path of the `.jsonl` file.
  final String path;
  final int size;
  final DateTime modified;

  /// The omp profile whose sessions directory holds the file; null for the default profile and for
  /// explicitly listed directories.
  final String? profile;

  /// Session id from the header.
  final String id;

  /// Current title: the title slot's, or the header's in files written before the slot existed.
  final String? title;

  /// `auto` or `user`.
  final String? titleSource;
  final String? cwd;

  /// Header timestamp.
  final DateTime? created;
  final String? parentSession;

  /// Session format version; null for v1 files.
  final int? version;

  /// Text of the first user message, on one line and at most [firstMessageLength] characters; null when the
  /// file's first 16 KiB hold none.
  final String? firstMessage;

  /// The live run holding this session on the machine; set by `MachineRuntime.listSessions`, null from the plain
  /// listing and for sessions no omp process holds.
  final String? runId;

  bool get running => runId != null;

  SessionSummary withRun(String? runId) => SessionSummary(
    path: path,
    size: size,
    modified: modified,
    id: id,
    profile: profile,
    title: title,
    titleSource: titleSource,
    cwd: cwd,
    created: created,
    parentSession: parentSession,
    version: version,
    firstMessage: firstMessage,
    runId: runId,
  );
}

/// Lists the session files of every omp profile on the machine in one round trip: `<sessions>/*/*.jsonl`
/// under the default agent directory, `PI_CODING_AGENT_DIR`, `$XDG_DATA_HOME/omp` (POSIX), and each
/// `profiles/<name>`, plus `*.jsonl` directly inside each of [sessionDirs] (omp's `--session-dir`).
/// Newest first.
Future<List<SessionSummary>> listSessions(HostLink link, HostProbe probe, {List<String> sessionDirs = const []}) async {
  final marker = newMarker();
  final result = probe.isWindows
      ? await runPowerShell(link, probe.commandShell, windowsSessionListScript(marker, sessionDirs))
      : await runPosixScript(link, posixSessionListScript(marker, sessionDirs));
  return parseSessionList(result.payload(marker));
}

/// Prints one `F<TAB>size<TAB>mtime<TAB>profile<TAB>path` record per file, then the first 16 KiB of every file
/// under `==> path <==` headers (one `head` for many files), and turns them into JSON lines with a single awk:
/// the title slot, the header, and the start of the first user message's text.
String posixSessionListScript(String marker, List<String> sessionDirs) =>
    'm=${shQuote(marker)}\nset --${sessionDirs.map((d) => ' ${shQuote(d)}').join()}\n$_posixListBody';

const _posixListBody = r"""
LC_ALL=C; export LC_ALL
if stat -c %s / >/dev/null 2>&1; then gnu=1; else gnu=0; fi
seen='
'
root() {
  [ -d "$1" ] || return 0
  case $seen in *"
$1
"*) return 0 ;; esac
  seen="$seen$1
"
  if [ "$gnu" = 1 ]; then
    find "$1" -mindepth "$3" -maxdepth "$3" -name '*.jsonl' -type f -exec stat -c '%s %Y %n' {} + 2>/dev/null
  else
    find "$1" -mindepth "$3" -maxdepth "$3" -name '*.jsonl' -type f -exec stat -f '%z %m %N' {} + 2>/dev/null
  fi | while IFS= read -r rec; do
    size=${rec%% *}; rest=${rec#* }; mtime=${rest%% *}; f=${rest#* }
    printf 'F\t%s\t%s\t%s\t%s\n' "$size" "$mtime" "$2" "$f"
  done
  # /dev/null first: head prints the `==> path <==` headers only for two files or more.
  find "$1" -mindepth "$3" -maxdepth "$3" -name '*.jsonl' -type f -exec head -c 16384 /dev/null {} + 2>/dev/null
  # Ends a prefix cut mid-line, so the next record starts a line.
  printf '\n'
}
{
  cfg="$HOME/${PI_CONFIG_DIR:-.omp}"
  root "$cfg/agent/sessions" "" 2
  if [ -n "${PI_CODING_AGENT_DIR-}" ]; then root "$PI_CODING_AGENT_DIR/sessions" "" 2; fi
  if [ -n "${XDG_DATA_HOME-}" ]; then root "$XDG_DATA_HOME/omp/sessions" "" 2; fi
  for p in "$cfg"/profiles/*; do [ -d "$p" ] && root "$p/agent/sessions" "${p##*/}" 2; done
  if [ -n "${XDG_DATA_HOME-}" ]; then
    for p in "$XDG_DATA_HOME"/omp/profiles/*; do [ -d "$p" ] && root "$p/sessions" "${p##*/}" 2; done
  fi
  for d in "$@"; do root "$d" "" 1; done
} | awk -v m="$m" '
# Character by character: gsub replacement strings treat backslashes differently across awks.
function esc(s,   out, i, n, c) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" || c == "\"") out = out "\\" c
    else if (c == "\t") out = out "\\t"
    else if (c >= " ") out = out c
  }
  return out
}
function str(s) { return s == "" ? "null" : "\"" esc(s) "\"" }
function num(s) { return s ~ /^[0-9]+$/ ? s : "0" }
function flush() {
  if (cur != "" && (cur in size))
    printf "{\"path\":%s,\"size\":%s,\"mtime\":%s,\"profile\":%s,\"title\":%s,\"header\":%s,\"first\":%s}\n", str(cur), num(size[cur]), num(mtime[cur]), str(prof[cur]), str(slot), str(header), str(first)
  cur = ""
}
BEGIN { printf "\n%s:begin\n", m }
/^F\t/ {
  split($0, a, "\t")
  p = substr($0, length(a[2]) + length(a[3]) + length(a[4]) + 6)
  size[p] = a[2]; mtime[p] = a[3]; prof[p] = a[4]
  next
}
/^==> .* <==$/ {
  flush()
  cur = substr($0, 5, length($0) - 8); n = 0; slot = ""; header = ""; first = ""
  next
}
cur == "" || $0 == "" { next }
{
  n++
  if (n == 1 && index($0, "{\"type\":\"title\"") == 1) { slot = $0; next }
  if (header == "") { header = $0; next }
  # The escaped JSON text of the first user message: string content or its first text part, cut to 1 KiB.
  if (first == "" && index($0, "{\"type\":\"message\"") == 1 && (u = index($0, "\"message\":{\"role\":\"user\"")) > 0) {
    rest = substr($0, u)
    if (match(rest, /"(content|text)":"/)) first = substr(rest, RSTART + RLENGTH, 1024)
  }
}
END { flush(); printf "%s:end\n", m }'
""";

/// Windows PowerShell equivalent of [posixSessionListScript]: reads up to 16 KiB of each file with
/// `ReadWrite, Delete` sharing, so files omp is writing stay readable.
String windowsSessionListScript(String marker, List<String> sessionDirs) =>
    '\$m = ${psQuote(marker)}\n\$extra = @(${sessionDirs.map(psQuote).join(', ')})\n$_windowsListBody';

const _windowsListBody = r'''
$roots = New-Object System.Collections.Generic.List[object]
function Add-Root([string]$Dir, $ProfileName, [int]$Depth) {
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
  $full = (Resolve-Path -LiteralPath $Dir).ProviderPath
  foreach ($r in $roots) { if ($r.Dir -eq $full) { return } }
  $roots.Add([pscustomobject]@{ Dir = $full; ProfileName = $ProfileName; Depth = $Depth })
}
$cfgName = '.omp'
if ($env:PI_CONFIG_DIR) { $cfgName = $env:PI_CONFIG_DIR }
$cfg = Join-Path $env:USERPROFILE $cfgName
Add-Root (Join-Path $cfg 'agent\sessions') $null 2
if ($env:PI_CODING_AGENT_DIR) { Add-Root (Join-Path $env:PI_CODING_AGENT_DIR 'sessions') $null 2 }
$profiles = Join-Path $cfg 'profiles'
if (Test-Path -LiteralPath $profiles -PathType Container) {
  foreach ($p in Get-ChildItem -LiteralPath $profiles -Directory) { Add-Root (Join-Path $p.FullName 'agent\sessions') $p.Name 2 }
}
foreach ($d in $extra) { Add-Root $d $null 1 }
$buf = New-Object byte[] 16384
$out = New-Object System.Text.StringBuilder
foreach ($r in $roots) {
  if ($r.Depth -eq 2) { $dirs = @(Get-ChildItem -LiteralPath $r.Dir -Directory) } else { $dirs = @(Get-Item -LiteralPath $r.Dir) }
  foreach ($dir in $dirs) {
    foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File) {
      if (-not $f.Name.EndsWith('.jsonl')) { continue }
      $slot = $null; $header = $null; $first = $null
      try {
        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
        try { $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
        $lines = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n).Split([char]10)
        $next = 1
        if ($lines[0].StartsWith('{"type":"title"')) { if ($lines.Length -gt 1) { $header = $lines[1] }; $slot = $lines[0]; $next = 2 } else { $header = $lines[0] }
        for ($i = $next; $i -lt $lines.Length -and $null -eq $first; $i++) {
          $l = $lines[$i]
          $u = $l.IndexOf('"message":{"role":"user"', [System.StringComparison]::Ordinal)
          if (-not $l.StartsWith('{"type":"message"', [System.StringComparison]::Ordinal) -or $u -lt 0) { continue }
          $t = [regex]::Match($l.Substring($u), '"(content|text)":"')
          if ($t.Success) {
            $rest = $l.Substring($u + $t.Index + $t.Length)
            $first = $rest.Substring(0, [Math]::Min(1024, $rest.Length))
          }
        }
      } catch { $header = $null }
      $rec = [ordered]@{
        path = $f.FullName; size = $f.Length; mtime = [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeSeconds()
        profile = $r.ProfileName; title = $slot; header = $header; first = $first
      }
      [void]$out.Append((ConvertTo-OmpAscii (ConvertTo-Json -InputObject $rec -Compress))).Append("`n")
    }
  }
}
[Console]::Out.Write("`n" + $m + ":begin`n" + $out.ToString() + $m + ":end`n")
''';

/// Parses the JSON lines both listing scripts print. Files whose header is not a session header (being
/// written, or not a session) are skipped, as omp's own listing does.
List<SessionSummary> parseSessionList(String payload) {
  final sessions = <SessionSummary>[];
  for (final line in const LineSplitter().convert(payload)) {
    if (line.isEmpty) continue;
    final record = asJsonObject(jsonDecode(line), 'session record');
    final header = _jsonLine(record.optString('header'));
    if (header == null || header['type'] != 'session') continue;
    final id = header['id'];
    if (id is! String) continue;
    // The slot, when there is one, holds the current title; files written before it existed keep the title
    // in the header. An empty title means none.
    final slot = _jsonLine(record.optString('title'));
    final slotValid = slot != null && slot['type'] == 'title' && slot['title'] is String;
    final title = _text(slotValid ? slot['title'] : header['title']);
    final created = header['timestamp'];
    final version = header['version'];
    final parent = header['parentSession'];
    final cwd = header['cwd'];
    sessions.add(
      SessionSummary(
        path: record.string('path'),
        size: record.integer('size'),
        modified: DateTime.fromMillisecondsSinceEpoch(record.integer('mtime') * 1000, isUtc: true),
        profile: record.optString('profile'),
        id: id,
        title: title,
        titleSource: title == null ? null : _text(slotValid ? slot['source'] : header['titleSource']),
        cwd: cwd is String ? cwd : null,
        created: created is String ? DateTime.tryParse(created) : null,
        parentSession: parent is String ? parent : null,
        version: version is int ? version : null,
        firstMessage: _firstMessage(record.optString('first')),
      ),
    );
  }
  sessions.sort((a, b) => b.modified.compareTo(a.modified));
  return sessions;
}

/// A session file line decoded as a JSON object, or null when it is missing or cut short.
Map<String, Object?>? _jsonLine(String? line) {
  if (line == null || line.isEmpty) return null;
  try {
    final value = jsonDecode(line);
    return value is Map<String, Object?> ? value : null;
  } on FormatException {
    // A header still being written, or a slot overwritten mid-read, is a partial line.
    return null;
  }
}

/// Longest [SessionSummary.firstMessage].
const firstMessageLength = 200;

/// Decodes the escaped JSON text both scripts cut from the first user message (up to its closing quote, or
/// wherever the cut fell), collapses whitespace and caps it at [firstMessageLength].
String? _firstMessage(String? escaped) {
  if (escaped == null) return null;
  var end = escaped.length;
  for (var i = 0; i < escaped.length; i++) {
    final c = escaped[i];
    if (c == '"') {
      end = i;
      break;
    }
    if (c == '\\') i++;
  }
  // A cut inside an escape leaves `\` or a short `\u` sequence; drop characters until the rest decodes.
  var decoded = '';
  for (var cut = end; cut > end - 6 && cut >= 0; cut--) {
    try {
      decoded = jsonDecode('"${escaped.substring(0, cut)}"') as String;
      break;
    } on FormatException {
      continue;
    }
  }
  // U+FFFD: a multi-byte character the byte-bounded read cut in half.
  final text = decoded.replaceAll('\uFFFD', '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return String.fromCharCodes(text.runes.take(firstMessageLength));
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;
