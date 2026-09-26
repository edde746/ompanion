import 'dart:convert';

import '../store/external_writer.dart';
import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// Who else on the machine is writing the session file at [sessionPath], or null when nobody is.
///
/// POSIX only. Windows has no equivalent of `/proc` or `lsof`, and omp's breadcrumb ids there name a Windows
/// Terminal session, not a device the process table shows: the probe reports null, and the app keeps the
/// behaviour it had (it may start a second omp for a session another process holds).
Future<ExternalWriter?> probeSessionWriter(HostLink link, HostProbe probe, String sessionPath) async {
  if (probe.isWindows) return null;
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    sessionWriterScript(marker, sessionPath, _breadcrumbDirs(probe, sessionPath)),
  );
  return parseSessionWriter(result.payload(marker));
}

/// Directories holding omp's terminal breadcrumbs for [sessionPath]: the probed agent directory, and the one
/// the file's own path names (`<agentDir>/sessions/<bucket>/<file>`), which is where a non-default profile's
/// breadcrumbs live.
Iterable<String> _breadcrumbDirs(HostProbe probe, String sessionPath) sync* {
  yield probe.agentDir;
  final file = sessionPath.split('/');
  if (file.length >= 3 && file[file.length - 3] == 'sessions') {
    final derived = file.sublist(0, file.length - 3).join('/');
    if (derived.isNotEmpty && derived != probe.agentDir) yield derived;
  }
}

/// Prints `holder <pid>` for every process holding [sessionPath] open for writing, and `terminal <id> <pid>` for
/// omp's breadcrumb of [sessionPath] whose terminal still runs an omp. [breadcrumbDirs] are the candidate
/// `<agentDir>`s (`terminal-sessions` is appended).
///
/// The two are independent: the descriptor is held for the length of a turn, while the breadcrumb survives the
/// turn and even the terminal (omp never removes one), so it counts only with a live omp on that tty.
String sessionWriterScript(String marker, String sessionPath, Iterable<String> breadcrumbDirs) {
  final dirs = breadcrumbDirs.map(shQuote).join(' ');
  return '''
m=${shQuote(marker)}; s=${shQuote(sessionPath)}
printf '%s:begin\\n' "\$m"
$_holdersBody
${_breadcrumbBody.replaceFirst('OMP_BREADCRUMB_DIRS', dirs)}
printf '%s:end\\n' "\$m"
''';
}

/// `lsof`'s FD column carries the access mode (`30w`); its field output does not, so the plain table is parsed.
/// On a Linux host without `lsof`, `/proc/<pid>/fd` symlinks and the octal `flags` of `fdinfo` answer the same
/// question: the low two bits are the access mode (0 read, 1 write, 2 read-write).
const _holdersBody = r'''
lsof_path=
if command -v lsof >/dev/null 2>&1; then
  lsof_path=lsof
elif [ -x /usr/sbin/lsof ]; then
  lsof_path=/usr/sbin/lsof
elif [ -x /usr/bin/lsof ]; then
  lsof_path=/usr/bin/lsof
fi
if [ -n "$lsof_path" ]; then
  "$lsof_path" -w -- "$s" 2>/dev/null | awk 'NR > 1 && $4 ~ /[wu]$/ { print "holder", $2 }'
elif [ -d /proc ]; then
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    held=0
    for f in "$d"/fd/*; do
      [ -L "$f" ] || continue
      t=$(readlink "$f" 2>/dev/null) || continue
      [ "$t" = "$s" ] || continue
      v=$(awk '/^flags:/ { print $2 }' "$d/fdinfo/${f##*/}" 2>/dev/null)
      if [ -n "$v" ] && [ "$((0$v & 3))" -ne 0 ]; then held=1; break; fi
    done
    [ "$held" = 1 ] && echo "holder $p"
  done
fi
''';

/// The breadcrumb's second line is the session file omp last opened in that terminal. Only a terminal-shaped id
/// names a device the process table shows (`ttys004` on macOS, `pts-3` → `pts/3` on Linux); a multiplexer or
/// emulator id (`tmux-%7`, `kitty-3`, `apple-…`) names none, and is left alone rather than guessed at.
const _breadcrumbBody = r'''
case "$s" in
  /private/*) s_alt=${s#/private} ;;
  *) s_alt=/private$s ;;
esac
for A in OMP_BREADCRUMB_DIRS; do
  [ -d "$A/terminal-sessions" ] || continue
  for f in "$A"/terminal-sessions/*; do
    [ -f "$f" ] || continue
    p=$(sed -n 2p "$f" 2>/dev/null)
    if [ "$p" != "$s" ] && [ "$p" != "$s_alt" ]; then continue; fi
    id=${f##*/}
    case "$id" in
      ttys*) tty=$id ;;
      pts-*) tty=pts/${id#pts-} ;;
      *) continue ;;
    esac
    pid=$(ps -eo pid=,tty=,command= 2>/dev/null | awk -v t="$tty" '
      $2 == t {
        c = $0
        sub(/^[ \t]*[0-9]+[ \t]+[^ \t]+[ \t]+/, "", c)
        if (c ~ /(^|[\/ \t])omp(\.(js|ts))?([ \t]|$)/) { print $1; exit }
      }')
    if [ -n "$pid" ]; then echo "terminal $id $pid"; break; fi
  done
done
''';

/// Reads [sessionWriterScript]'s payload. Unparsable lines are an empty answer, not an error: the probe is a
/// guard, and a script that printed nothing useful must not look like a holder.
ExternalWriter? parseSessionWriter(String payload) {
  final pids = <int>[];
  String? terminal;
  for (final line in const LineSplitter().convert(payload)) {
    final fields = line.split(' ');
    if (fields.length == 2 && fields[0] == 'holder') {
      if (int.tryParse(fields[1]) case final pid?) pids.add(pid);
    } else if (fields.length == 3 && fields[0] == 'terminal' && fields[1].isNotEmpty) {
      if (int.tryParse(fields[2]) != null) terminal = fields[1];
    }
  }
  if (pids.isEmpty && terminal == null) return null;
  return ExternalWriter(pids: pids, terminal: terminal);
}
