import 'dart:convert';

import '../store/external_writer.dart';
import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// Who else on the machine is writing the session file at [sessionPath], or null when nobody is. [runPid] is the omp
/// of the app's own live run for the file: it holds the file open once it appended, and is not someone else.
///
/// POSIX only. Windows has no equivalent of `/proc` or `lsof`, and omp's breadcrumb ids there name a Windows
/// Terminal session, not a device the process table shows: the probe reports null, and the app keeps the
/// behaviour it had (it may start a second omp for a session another process holds).
Future<ExternalWriter?> probeSessionWriter(HostLink link, HostProbe probe, String sessionPath, {int? runPid}) async {
  if (probe.isWindows) return null;
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    sessionWriterScript(marker, sessionPath, _breadcrumbDirs(probe, sessionPath)),
  );
  return parseSessionWriter(result.payload(marker), runPid: runPid);
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
/// The two are independent: omp opens its append descriptor at the first write after it opened or rewrote the file
/// and keeps it until it switches sessions, rewrites the file or exits, while the breadcrumb is written when omp
/// opens a session and survives even the terminal (omp never removes one), so it counts only with a live omp on
/// that tty.
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

/// On Linux, `/proc/<pid>/fd` answers with shell builtins only: `-ef` compares the device and inode each descriptor
/// resolves to with the file's, and `fdinfo/<fd>`'s octal `flags` carry the access mode in the low two bits (0 read,
/// 1 write, 2 read-write). A `readlink` per descriptor took 3 s for 10,000 descriptors on the test machine, and
/// BusyBox's `lsof` ignores its arguments and prints no access mode. Elsewhere (macOS) `lsof`'s FD column carries
/// the mode after the descriptor number (`30w`); its field output does not, so the plain table is parsed.
const _holdersBody = r'''
if [ -d /proc/self/fd ]; then
  for d in /proc/[0-9]*; do
    for f in "$d"/fd/*; do
      [ "$f" -ef "$s" ] || continue
      v=
      while read -r k v; do [ "$k" = flags: ] && break; v=; done 2>/dev/null < "$d/fdinfo/${f##*/}"
      case "$v" in ''|*[!0-7]*) continue ;; esac
      if [ $((0$v & 3)) -ne 0 ]; then echo "holder ${d#/proc/}"; break; fi
    done
  done
else
  lsof_path=
  if command -v lsof >/dev/null 2>&1; then
    lsof_path=lsof
  elif [ -x /usr/sbin/lsof ]; then
    lsof_path=/usr/sbin/lsof
  fi
  if [ -n "$lsof_path" ]; then
    "$lsof_path" -w -- "$s" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+[wu]/ { print "holder", $2 }'
  fi
fi
''';

/// The breadcrumb's second line is the session file omp last opened in that terminal. Only a terminal-shaped id
/// names a device the process table shows (`ttys004` on macOS, `pts-3` → `pts/3` on Linux); a multiplexer or
/// emulator id (`tmux-%7`, `kitty-3`, `apple-…`) names none, and is left alone rather than guessed at. omp never
/// removes a crumb, so the id is checked before the file is read.
const _breadcrumbBody = r'''
case "$s" in
  /private/*) s_alt=${s#/private} ;;
  *) s_alt=/private$s ;;
esac
for A in OMP_BREADCRUMB_DIRS; do
  for f in "$A"/terminal-sessions/*; do
    id=${f##*/}
    case "$id" in
      ttys*) tty=$id ;;
      pts-*) tty=pts/${id#pts-} ;;
      *) continue ;;
    esac
    p=
    { IFS= read -r c; IFS= read -r p; } 2>/dev/null < "$f"
    [ "$p" = "$s" ] || [ "$p" = "$s_alt" ] || continue
    pid=$(ps -eo pid=,tty=,args= 2>/dev/null | awk -v t="$tty" '
      $2 == t {
        c = $0
        sub(/^[ \t]*[0-9]+[ \t]+[^ \t]+[ \t]+/, "", c)
        if (c ~ /(^|[\/ \t])omp(\.(js|ts))?([ \t]|$)/) { print $1; exit }
      }')
    if [ -n "$pid" ]; then echo "terminal $id $pid"; break; fi
  done
done
''';

/// Reads [sessionWriterScript]'s payload, leaving out the holder [runPid] (see [probeSessionWriter]). Unparsable
/// lines are an empty answer, not an error: the probe is a guard, and a script that printed nothing useful must not
/// look like a holder.
ExternalWriter? parseSessionWriter(String payload, {int? runPid}) {
  final pids = <int>[];
  String? terminal;
  for (final line in const LineSplitter().convert(payload)) {
    final fields = line.split(' ');
    if (fields.length == 2 && fields[0] == 'holder') {
      if (int.tryParse(fields[1]) case final pid? when pid != runPid) pids.add(pid);
    } else if (fields.length == 3 && fields[0] == 'terminal' && fields[1].isNotEmpty) {
      if (int.tryParse(fields[2]) != null) terminal = fields[1];
    }
  }
  if (pids.isEmpty && terminal == null) return null;
  return ExternalWriter(pids: pids, terminal: terminal);
}
