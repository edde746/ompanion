import 'dart:convert';

import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// What the machine sums its activity over: the last 7, 30 and 365 local days, and all time (0). Each range ends
/// on the device's today.
const activityRanges = [7, 30, 365, 0];

/// What the stats script needs from the device: its time zone, as UTC offsets from the instants they start at, so
/// every machine puts a request on the day and hour the device's calendar shows; and the device's today, so every
/// machine ends its ranges on the same day.
final class ActivityQuery {
  const ActivityQuery({required this.zone, required this.today});

  /// The device's zone from 2020 (before omp existed) to two days after [now].
  factory ActivityQuery.local(DateTime now) {
    final from = DateTime.utc(2020).millisecondsSinceEpoch;
    final to = now.millisecondsSinceEpoch + 2 * _dayMs;
    int offsetAt(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset.inMinutes;
    final zone = [(from, offsetAt(from))];
    for (var ms = from; ms < to; ms += _dayMs) {
      if (offsetAt(ms + _dayMs) == zone.last.$2) continue;
      // The first minute of the day that has the new offset.
      var lo = ms;
      var hi = ms + _dayMs;
      while (hi - lo > 60000) {
        final mid = lo + (hi - lo) ~/ 2;
        if (offsetAt(mid) == zone.last.$2) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      zone.add((hi, offsetAt(hi)));
    }
    return ActivityQuery(zone: zone, today: localDay(now));
  }

  /// `(start, offset minutes)` pairs, oldest first; the first one also covers everything before it.
  final List<(int, int)> zone;

  /// The device's today as [localDay] numbers it.
  final int today;

  Map<String, Object?> toJson() => {
    'zone': [
      for (final (start, offset) in zone) [start, offset],
    ],
    'today': today,
    'ranges': activityRanges,
  };
}

const _dayMs = 24 * 60 * 60 * 1000;

/// A local calendar day as the stats number it: days since 1970-01-01.
int localDay(DateTime time) => DateTime.utc(time.year, time.month, time.day).millisecondsSinceEpoch ~/ _dayMs;

/// The local date of a [localDay] number.
DateTime dayDate(int day) {
  final utc = DateTime.fromMillisecondsSinceEpoch(day * _dayMs, isUtc: true);
  return DateTime(utc.year, utc.month, utc.day);
}

/// Model requests summed: how many, how many failed, their tokens and cost, and the sums behind the averages.
final class RequestTotals {
  const RequestTotals({
    this.requests = 0,
    this.errors = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost = 0,
    this.durationSum = 0,
    this.durationCount = 0,
    this.ttftSum = 0,
    this.ttftCount = 0,
    this.tokensPerSecondSum = 0,
    this.tokensPerSecondCount = 0,
  });

  /// The 13 numbers the script writes from [at] on, in the order of the fields.
  RequestTotals.fromRow(List<Object?> row, int at)
    : requests = _int(row, at),
      errors = _int(row, at + 1),
      input = _int(row, at + 2),
      output = _int(row, at + 3),
      cacheRead = _int(row, at + 4),
      cacheWrite = _int(row, at + 5),
      cost = _double(row, at + 6),
      durationSum = _double(row, at + 7),
      durationCount = _int(row, at + 8),
      ttftSum = _double(row, at + 9),
      ttftCount = _int(row, at + 10),
      tokensPerSecondSum = _double(row, at + 11),
      tokensPerSecondCount = _int(row, at + 12);

  final int requests;

  /// Requests that stopped with an error.
  final int errors;
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;

  /// US dollars, as omp priced each request.
  final double cost;
  final double durationSum;
  final int durationCount;
  final double ttftSum;
  final int ttftCount;
  final double tokensPerSecondSum;
  final int tokensPerSecondCount;

  int get tokens => input + output + cacheRead + cacheWrite;

  double get errorRate => requests == 0 ? 0 : errors / requests;

  /// The share of prompt tokens read from the cache, as omp's stats compute it.
  double get cacheRate => input + cacheRead == 0 ? 0 : cacheRead / (input + cacheRead);

  double? get averageTtftMs => ttftCount == 0 ? null : ttftSum / ttftCount;

  double? get averageTokensPerSecond => tokensPerSecondCount == 0 ? null : tokensPerSecondSum / tokensPerSecondCount;

  RequestTotals operator +(RequestTotals other) => RequestTotals(
    requests: requests + other.requests,
    errors: errors + other.errors,
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cacheWrite: cacheWrite + other.cacheWrite,
    cost: cost + other.cost,
    durationSum: durationSum + other.durationSum,
    durationCount: durationCount + other.durationCount,
    ttftSum: ttftSum + other.ttftSum,
    ttftCount: ttftCount + other.ttftCount,
    tokensPerSecondSum: tokensPerSecondSum + other.tokensPerSecondSum,
    tokensPerSecondCount: tokensPerSecondCount + other.tokensPerSecondCount,
  );
}

/// One local day. [sessions] counts the main sessions that started on it; [tokens] is input, output and cache;
/// [words] is what the day's prompts held.
typedef ActivityDay = ({
  int day,
  int requests,
  int errors,
  int tokens,
  double cost,
  int prompts,
  int sessions,
  int toolCalls,
  int words,
});

/// A model as `provider/id`.
typedef ModelActivity = ({String model, RequestTotals totals});

/// A project by its working directory, host-native; empty for session files without a header.
typedef ProjectActivity = ({String cwd, int requests, int tokens, double cost, int sessions, int prompts});

/// [errors] counts the tool results omp marked as errors.
typedef ToolActivity = ({String name, int calls, int errors});

typedef AgentActivity = ({int requests, int tokens, double cost});

/// A word of the prompts' prose and how many prompts use it.
typedef WordUse = ({String word, int prompts});

/// What the prompts of a range held, measured per prompt as omp's stats do (`user-metrics.ts`): [words]
/// (whitespace-separated) and [characters] over the whole text; [questions], the prompts whose prose (the text
/// without code, links, paths and quotes) has a `?`; and omp's tone signals, matches counted in prose of under three
/// lines.
final class PromptTotals {
  PromptTotals.fromJson(Map<String, Object?> json)
    : words = _int(json.list('sums'), 0),
      characters = _int(json.list('sums'), 1),
      questions = _int(json.list('sums'), 2),
      yelling = _int(json.list('sums'), 3),
      profanity = _int(json.list('sums'), 4),
      anguish = _int(json.list('sums'), 5),
      negation = _int(json.list('sums'), 6),
      repetition = _int(json.list('sums'), 7),
      blame = _int(json.list('sums'), 8),
      lengths = json.integers('lengths'),
      lengthBounds = json.integers('bounds'),
      longest = switch (json['longest']) {
        null => null,
        final List<Object?> row => (words: _int(row, 0), day: _int(row, 1)),
        final value => throw FormatException('activity prompts: longest is ${describeJson(value)}'),
      },
      hours = json.integers('hours'),
      cloud = [for (final row in _rows(json, 'words')) (word: _string(row, 0), prompts: _int(row, 1))] {
    if (lengths.length != lengthBounds.length + 1) {
      throw FormatException('activity prompts: ${lengths.length} lengths for ${lengthBounds.length} bounds');
    }
    if (hours.length != 168) throw FormatException('activity prompts: ${hours.length} hours, not 168');
  }

  PromptTotals({
    required this.words,
    required this.characters,
    required this.questions,
    required this.yelling,
    required this.profanity,
    required this.anguish,
    required this.negation,
    required this.repetition,
    required this.blame,
    required this.lengths,
    required this.lengthBounds,
    required this.longest,
    required this.hours,
    required this.cloud,
  });

  final int words;
  final int characters;
  final int questions;

  /// Sentences mostly in capitals.
  final int yelling;
  final int profanity;

  /// `!!!`, `argh`, `ugh`, `dude`, `:(`.
  final int anguish;

  /// `no, …`, `that's not what I meant`.
  final int negation;

  /// `as I said`, `still broken`.
  final int repetition;

  /// `you broke`, `why did you`, `stop doing`.
  final int blame;

  /// Prompts by words: up to `lengthBounds[0]` words, then up to each next bound, then over the last.
  final List<int> lengths;
  final List<int> lengthBounds;

  /// The most words in one prompt, on the [localDay] of the latest prompt that long.
  final ({int words, int day})? longest;

  /// Prompts per local weekday and hour: Monday 00:00 is the first of the 168, Sunday 23:00 the last.
  final List<int> hours;

  /// The words most prompts use, most first; the script sends at most 100 and leaves out the words every sentence
  /// has. A word counts once per prompt.
  final List<WordUse> cloud;
}

/// Everything summed over the [days] local days that end today (0: all time).
final class ActivityRange {
  ActivityRange.fromJson(Map<String, Object?> json)
    : days = json.integer('days'),
      requests = RequestTotals.fromRow(json.list('totals'), 0),
      prompts = _int(json.list('totals'), 13),
      sessions = _int(json.list('totals'), 14),
      toolCalls = _int(json.list('totals'), 15),
      toolErrors = _int(json.list('totals'), 16),
      models = [
        for (final row in _rows(json, 'models')) (model: _string(row, 0), totals: RequestTotals.fromRow(row, 1)),
      ],
      projects = [
        for (final row in _rows(json, 'projects'))
          (
            cwd: _string(row, 0),
            requests: _int(row, 1),
            tokens: _int(row, 2),
            cost: _double(row, 3),
            sessions: _int(row, 4),
            prompts: _int(row, 5),
          ),
      ],
      tools = [
        for (final row in _rows(json, 'tools')) (name: _string(row, 0), calls: _int(row, 1), errors: _int(row, 2)),
      ],
      hours = json.integers('hours'),
      agents = [
        for (final row in _rows(json, 'agents')) (requests: _int(row, 0), tokens: _int(row, 1), cost: _double(row, 2)),
      ],
      typed = PromptTotals.fromJson(json.object('prompts')) {
    if (hours.length != 168) throw FormatException('activity range $days: ${hours.length} hours, not 168');
    if (agents.length != 3) throw FormatException('activity range $days: ${agents.length} agent kinds, not 3');
  }

  ActivityRange({
    required this.days,
    required this.requests,
    required this.prompts,
    required this.sessions,
    required this.toolCalls,
    required this.toolErrors,
    required this.models,
    required this.projects,
    required this.tools,
    required this.hours,
    required this.agents,
    required this.typed,
  });

  final int days;
  final RequestTotals requests;

  /// Messages a person typed; omp's injected ones are not counted.
  final int prompts;

  /// Main sessions that started in the range and made a request.
  final int sessions;
  final int toolCalls;
  final int toolErrors;

  /// Most requests first.
  final List<ModelActivity> models;

  /// Most tokens first; the script sends at most 50.
  final List<ProjectActivity> projects;

  /// Most calls first.
  final List<ToolActivity> tools;

  /// Requests per local weekday and hour: Monday 00:00 is the first of the 168, Sunday 23:00 the last.
  final List<int> hours;

  /// Main sessions, subagents, the advisor.
  final List<AgentActivity> agents;

  /// What the [prompts] held.
  final PromptTotals typed;
}

/// How the machine came by its numbers: [files] session files of [bytes] in all; [parsed] of them were read whole
/// and [appended] from where the cache left off, [read] bytes together. [errors] files could not be read; [error]
/// says why for the first.
typedef ActivityScan = ({
  int files,
  int bytes,
  int parsed,
  int appended,
  int read,
  int errors,
  String? error,
  Duration elapsed,
});

/// A machine's activity from its session files: every day it was used, and the totals of each of [activityRanges].
final class ActivityStats {
  ActivityStats.fromJson(Map<String, Object?> json)
    : first = _time(json.optNumber('first')),
      last = _time(json.optNumber('last')),
      days = [
        for (final row in _rows(json, 'days'))
          (
            day: _int(row, 0),
            requests: _int(row, 1),
            errors: _int(row, 2),
            tokens: _int(row, 3),
            cost: _double(row, 4),
            prompts: _int(row, 5),
            sessions: _int(row, 6),
            toolCalls: _int(row, 7),
            words: _int(row, 8),
          ),
      ],
      ranges = [for (final range in json.objects('ranges')) ActivityRange.fromJson(range)],
      scan = _scan(json.object('scan')) {
    if (json.integer('v') != 2) throw FormatException('activity stats version ${json['v']}');
  }

  /// The first and last hour with a request.
  final DateTime? first;
  final DateTime? last;

  /// Days with any activity, oldest first.
  final List<ActivityDay> days;

  /// One per [activityRanges], in that order.
  final List<ActivityRange> ranges;
  final ActivityScan scan;
}

/// Sums the activity in every omp session file on the machine (docs/contracts/activity-stats.md) with omp's own Bun
/// runtime, and keeps per-file numbers in `~/.ompanion/stats/` so the next call reads only what was appended since.
Future<ActivityStats> readActivityStats(HostLink link, HostProbe probe, ActivityQuery query) async {
  final omp = probe.ompPath;
  if (omp == null) throw StateError('omp is not installed on ${link.label}');
  final marker = newMarker();
  final script = 'const input = ${jsonEncode({...query.toJson(), 'marker': marker})};\n$activityStatsScript';
  final result = probe.isWindows
      ? await runPowerShell(link, probe.commandShell, _windowsScript(omp, marker, script))
      : await runPosixScript(
          link,
          [probe.loginPathExport, 'omp=${shQuote(omp)}', _posixRun, script, _posixEnd].join('\n'),
        );
  if (result.exit.code != 0) throw result.failure('activity stats failed');
  return ActivityStats.fromJson(asJsonObject(jsonDecode(result.payload(marker)), 'activity stats'));
}

/// omp's standalone binary is a Bun executable that runs a script instead of omp while `BUN_BE_BUN` is set, and then
/// prints Bun's version (`1.4.2`) for `--version`. omp installed as a package prints its own (`omp/18.6.3`); the `bun`
/// that installed it runs the script instead. Bun's transpiler cache is off: the script differs on every call (its
/// marker), so each call would leave another 25 KB file in the machine's cache directory (`./bun` when
/// `XDG_CACHE_HOME` is empty) that no call reads again.
const _posixRun = r"""
export BUN_RUNTIME_TRANSPILER_CACHE_PATH=0
case $(BUN_BE_BUN=1 "$omp" --version 2>/dev/null) in
[0-9]*) set -- env BUN_BE_BUN=1 "$omp" ;;
*)
  if command -v bun >/dev/null 2>&1; then set -- bun; else
    echo "$omp is not omp's standalone binary and bun is not on PATH: nothing can run the stats script" >&2
    exit 3
  fi
  ;;
esac
"$@" run - <<'OMPANION_ACTIVITY_JS'""";

const _posixEnd = 'OMPANION_ACTIVITY_JS';

/// [_posixRun] for Windows PowerShell. The script goes to a file of its own: Windows PowerShell would pipe it to stdin
/// in the console's code page.
String _windowsScript(String omp, String marker, String script) => [
  '\$omp = ${psQuote(omp)}',
  '\$file = Join-Path \$env:USERPROFILE ${psQuote('.ompanion\\stats\\$marker.js')}',
  r"""
$env:BUN_BE_BUN = '1'
$env:BUN_RUNTIME_TRANSPILER_CACHE_PATH = '0'
$runtime = $omp
if (((& $omp --version 2>$null) -join '') -notmatch '^\d') {
  if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "$omp is not omp's standalone binary and bun is not on PATH: nothing can run the stats script"
  }
  $runtime = 'bun'
}
[void](New-Item -ItemType Directory -Force -Path (Split-Path $file))
[IO.File]::WriteAllText($file, @'""",
  script,
  r'''
'@)
try { & $runtime $file; $code = $LASTEXITCODE } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
exit $code''',
].join('\n');

List<List<Object?>> _rows(Map<String, Object?> json, String key) => [
  for (final (index, row) in json.list(key).indexed)
    if (row is List<Object?>) row else throw FormatException('activity $key[$index]: expected a list'),
];

num _number(List<Object?> row, int index) => switch (index < row.length ? row[index] : null) {
  final num value => value,
  final value => throw FormatException('activity row: expected a number at $index, got ${describeJson(value)}'),
};

int _int(List<Object?> row, int index) => _number(row, index).toInt();

double _double(List<Object?> row, int index) => _number(row, index).toDouble();

String _string(List<Object?> row, int index) => switch (index < row.length ? row[index] : null) {
  final String value => value,
  final value => throw FormatException('activity row: expected a string at $index, got ${describeJson(value)}'),
};

DateTime? _time(num? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms.toInt());

ActivityScan _scan(Map<String, Object?> json) => (
  files: json.integer('files'),
  bytes: json.integer('bytes'),
  parsed: json.integer('parsed'),
  appended: json.integer('appended'),
  read: json.integer('read'),
  errors: json.integer('errors'),
  error: json.optString('error'),
  elapsed: Duration(milliseconds: json.integer('ms')),
);

/// The stats script (docs/contracts/activity-stats.md); `input` is put in front of it.
const activityStatsScript = r'''
// ompanion activity stats (docs/contracts/activity-stats.md). Runs on omp's Bun; `input` is defined above.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const started = performance.now();
const HOUR = 3600000;
const CACHE_VERSION = 2;
const home = os.homedir();
const cacheDir = path.join(home, ".ompanion", "stats");
const cachePath = path.join(cacheDir, `cache-v${CACHE_VERSION}.json`);
// Request row: [hour, model, requests, errors, input, output, cacheRead, cacheWrite, cost, durationSum,
// durationCount, ttftSum, ttftCount, tokensPerSecondSum, tokensPerSecondCount].
const REQUEST_FIELDS = 13;
// The most words a range sends, by the number of prompts that use them.
const TOP_WORDS = 100;
// Under this many bytes to read, starting workers costs more than it saves.
const PARALLEL_BYTES = 32 * 1024 * 1024;

// Everything that reads one session file. A function of its own: the workers that read many files at once are
// built from its source.
function sessionReader() {
	const fs = require("node:fs");
	const HOUR = 3600000;
	// Prompt row: [hour, prompts, words, characters, questions, yelling, profanity, anguish, negation, repetition,
	// blame, prompts by words (one per LENGTHS bound, then one over the last), the most words in one prompt].
	const LENGTHS = [5, 10, 20, 50, 100, 250];
	const PROMPT_SUMS = 10 + LENGTHS.length + 1;

	const latin1 = (text) => Buffer.from(text, "latin1");
	const MESSAGE = latin1('{"type":"message"');
	const MODEL_USAGE = latin1('{"type":"model_usage"');
	const SESSION = latin1('{"type":"session"');
	const ROLE = latin1('"role":"');
	const ASSISTANT = latin1('assistant"');
	const USER = latin1('user"');
	const TOOL_RESULT = latin1('toolResult"');
	const TIMESTAMP = latin1('"timestamp":"');
	const API = latin1(',"api":"');
	const TOOL_CALL = latin1('{"type":"toolCall"');
	const NAME = latin1('"name":"');
	const TOOL_NAME = latin1('"toolName":"');
	const IS_ERROR = latin1('"isError":true');
	const ATTRIBUTION = latin1('"attribution":"');
	const SYNTHETIC = latin1('"synthetic":true');

	function startsWith(buf, at, needle) {
		if (at + needle.length > buf.length) return false;
		for (let i = 0; i < needle.length; i++) if (buf[at + i] !== needle[i]) return false;
		return true;
	}

	// The first [needle] in buf[from, to), or -1. A bounded search: Buffer.indexOf alone would run on past the line.
	function find(buf, needle, from, to) {
		const at = buf.subarray(from, to).indexOf(needle);
		return at < 0 ? -1 : from + at;
	}

	// The JSON string whose text starts at [from], up to its closing quote before [limit]. Model, tool and role names
	// carry no escapes.
	function stringAt(buf, from, limit) {
		const end = buf.subarray(from, limit).indexOf(34);
		return end < 0 ? null : buf.toString("utf8", from, from + end);
	}

	function digits(buf, at, count) {
		let value = 0;
		for (let i = 0; i < count; i++) {
			const digit = buf[at + i] - 48;
			if (digit < 0 || digit > 9) return NaN;
			value = value * 10 + digit;
		}
		return value;
	}

	// An ISO time (`2026-10-07T16:36:58.486Z`, what omp writes) starting at [at], as epoch milliseconds, without
	// building a string.
	function isoAt(buf, at, limit) {
		const ms = buf[at + 4] === 45 && buf[at + 10] === 84 && buf[at + 23] === 90
			? Date.UTC(digits(buf, at, 4), digits(buf, at + 5, 2) - 1, digits(buf, at + 8, 2), digits(buf, at + 11, 2),
				digits(buf, at + 14, 2), digits(buf, at + 17, 2), digits(buf, at + 20, 3))
			: NaN;
		if (Number.isFinite(ms)) return ms;
		const text = stringAt(buf, at, limit);
		return text === null ? NaN : Date.parse(text);
	}

	const finite = (value) => (typeof value === "number" && Number.isFinite(value) ? value : 0);

	// ---- Prompts: omp's own metrics (packages/stats/src/user-metrics.ts in omp 18.6.3), and the words of the prose.

	const PROFANITY = new RegExp(String.raw`\b(?:${"fuck fucks fucked fucking fuckin fucker fuckers fuckup fuckups fuckhead fuckheads fuckface fuckwit fuckwits fucktard fuckery fuckoff motherfucker motherfuckers motherfucking clusterfuck ratfuck unfuck fk fks fking fkin fker fck fcks fcking fckin fcker fuk fuking fukin eff effs effed effing frick fricks fricked fricking frickin freaking freakin freaked shit shits shat shitty shittier shittiest shite shites shited shitting shitter shitters shithead shitheads shitshow shitstorm shitstain shitfaced shitload shitbag shitcan shitcanned shitpost shitposting bullshit bullshits bullshitting bullshitter horseshit batshit dogshit dipshit jackshit dumbshit holyshit damn damns damned damning dammit goddamn goddamned goddamnit goddammit darn darns darned darnit dang danged dangit hell hells heck hecks heckin gosh bloody bollocks bollox crap craps crappy crappier crappiest crapped crapping crapload crapola piss pisses pissed pissing pisser pisspoor pisstake pisshead ass asses asshole assholes asshat asshats asswipe asswipes assclown assbag asskisser dumbass dumbasses jackass jackasses smartass smartasses badass badasses lazyass fatass hardass halfass halfassed arse arsed arsehole arseholes arsewipe bitch bitches bitched bitching bitchy bitchier bitchiest sonofabitch biatch biotch cunt cunts cunty cuntish twat twats twatty bastard bastards dick dicks dickhead dickheads dickish dickwad dickwads dickface dickbag prick pricks prickish cock cocks cocky cockier cockiest cockhead cockblock cocksucker cocksuckers knobhead knobheads knobend wanker wankers wankery tosser tossers jerkoff jerkoffs douche douches douchebag douchebags douchey scumbag scumbags scum sleazebag sleazeball slimeball lowlife lowlifes deadbeat idiot idiots idiotic idiocy stupid stupider stupidest stupidity moron morons moronic imbecile imbeciles retard retards retarded dumb dumber dumbest dumbo fool fools foolish foolery clown clowns clownish buffoon buffoons simpleton halfwit halfwits nitwit nitwits dimwit dimwits dolt dolts doltish knucklehead knuckleheads blockhead blockheads lamebrain airhead airheads scatterbrain numbnuts numbskull numpty numpties muppet muppets pillock pillocks plonker plonkers prat prats berk berks ninny ninnies dingbat dingbats putz putzes schmuck schmucks jerk jerks jerkface gits sod sodding bugger buggered suck sucks sucked sucking sucky suckage trashy jesus christ jeez jeezus sheesh godsake wtf wth wtaf stfu gtfo omfg omg ffs jfc kys fml smh smdh smfh idgaf idfc lmfao fubar snafu".split(" ").join("|")})\b`, "gi");
	const SENTENCE = /[^.!?\n]+/g;
	const LETTER = /\p{L}/gu;
	const CAPITAL = /\p{Lu}/gu;
	const CAPS_RUN = /\p{Lu}{2,}/gu;
	const TRIPLED = /(\p{Lu})\1\1/u;
	const NON_SPACE = /\S+/g;
	const BANGS = /[!?][!?1]{2,}/g;
	const WAILS = /\b(?:no{3,}|a+h{2,}|u+r?g+h+|a+r+g+h+|g+r{2,}|st+o{3,}p+|w+h+y{3,}|f+u{3,}c*k*|wtf{3,}|o+m+g{2,}|ye+s{3,}|g+o+d{3,}|br+u+h{2,})\b/gi;
	const DUDE = /\bdude\b/gi;
	const FROWNS = /(?<=^|[\s.!?])[:;]-?\(+/g;
	const NO = /^[ \t]*(?:(?:nope|nah|nvm|wrong|incorrect)\b|no(?=\s*(?:[,.!?;:\u2013\u2014]|-(?!\w)|$|(?:i|im|u|you|ur|we|it|its|that|thats|this|the|they|theyre|he|she|man|dude|bro|wait|dont|not|stop|just|again|please|plz|but|actually|literally|seriously|sorry|no|never|nothing|wtf|why|what|wrong)\b)))/gi;
	const NOT_WHAT_I_MEANT = /\b(?:that['\u2019]?s\s+not\s+(?:what|right|it)|not\s+what\s+i\s+(?:meant|asked|said|wanted)|makes\s+(?:no|zero)\s+sense)\b/gi;
	const AS_I_SAID = /\b(?:(?:like|as)\s+i\s+(?:said|told\s+you|asked)|i\s+(?:meant|said|told\s+you|asked\s+you|already\s+(?:said|told|did|asked|wrote)))\b/gi;
	const STILL_BROKEN = /\bstill\s+(?:doesn['\u2019]?t|doesnt|isn['\u2019]?t|isnt|not|broken|wrong|fails|failing|the\s+same|same)\b/gi;
	const YOU_BROKE = /\byou\s+(?:didn['\u2019]?t|did\s+not|broke|missed|forgot|keep|always|never|still|ignored)\b/gi;
	const WHY_DID_YOU = /\bwhy\s+(?:would|did)\s+(?:you|u)\b/gi;
	const STOP_DOING = /(?:^|(?<=[.!?\n]))\s*stop\s+\w+ing\b/gim;
	// What is not prose: code, markup, links, @paths, file names, quotes, image placeholders, terminal colours.
	const FENCES = /```[\s\S]*?```/g;
	const ELEMENTS = /<([A-Za-z][\w-]*)\b[^>]*>[\s\S]*?<\/\1>/g;
	const TAGS = /<\/?[A-Za-z][\w-]*\b[^>]*\/?>/g;
	const INLINE_CODE = /`[^`\n]*`/g;
	const LINKS = /\bhttps?:\/\/\S+/gi;
	const MENTIONS = /(^|\s)@[\w./-]+/g;
	const FILE_NAMES = /(?<=^|[\s("'[])[\w-]+(?:\.[\w-]+)+(?=$|[\s)"'\],:;!?]|\.(?!\w))/g;
	const QUOTES = /^[ \t]*>.*$/gm;
	const IMAGES = /\[Image #\d+\]/g;
	const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
	// Cloud words: letters (an apostrophe inside), 3 to 24 of them, not one of the words every sentence has.
	const WORD = /\p{L}[\p{L}\p{M}'\u2019]*/gu;
	const STOPWORDS = new Set(`about above after again against all also and any are aren't because been before being below
		between both but can can't cannot could couldn't did didn't does doesn't doing don't down during each etc even
		few for from further get gets got had hadn't has hasn't have haven't having her here here's hers herself him
		himself his how how's i'd i'll i'm i've into isn't it's its itself just let let's like lot make many may maybe
		might more most much must mustn't myself need nor not now off once one only other ought our ours ourselves out
		over own really same shall shan't she she'd she'll she's should shouldn't some something such sure than that
		that's the their theirs them themselves then there there's these they they'd they'll they're they've thing
		things this those through too under until very want was wasn't way we'd we'll we're we've well were weren't
		what what's when when's where where's which while who who's whom why why's will with won't would wouldn't yeah
		yes yet you you'd you'll you're you've your yours yourself yourselves`.split(/\s+/));

	function count(text, pattern) {
		let n = 0;
		pattern.lastIndex = 0;
		while (pattern.exec(text) !== null) n++;
		return n;
	}

	// A sentence of 4 letters or more, over half of them capitals, with two runs of capitals or one with a letter
	// three times over. The runs are checked first: most sentences have none, and counting letters is the slow part.
	function yelling(text) {
		if (!/\p{Lu}{2}/u.test(text)) return 0;
		let n = 0;
		SENTENCE.lastIndex = 0;
		for (let match = SENTENCE.exec(text); match !== null; match = SENTENCE.exec(text)) {
			const sentence = match[0];
			const runs = sentence.match(CAPS_RUN);
			if (!runs || (runs.length < 2 && !(runs[0].length >= 4 && TRIPLED.test(runs[0])))) continue;
			const letters = count(sentence, LETTER);
			if (letters >= 4 && count(sentence, CAPITAL) / letters > 0.5) n++;
		}
		return n;
	}

	// Each pattern runs only on text that holds the character it starts with.
	function prose(text) {
		if (text.includes("```")) text = text.replace(FENCES, "\n");
		if (text.includes("<")) text = text.replace(ELEMENTS, "\n").replace(TAGS, " ");
		if (text.includes("`")) text = text.replace(INLINE_CODE, " ");
		if (text.includes("://")) text = text.replace(LINKS, " ");
		if (text.includes("@")) text = text.replace(MENTIONS, "$1 ");
		if (text.includes(".")) text = text.replace(FILE_NAMES, " ");
		if (text.includes(">")) text = text.replace(QUOTES, "");
		if (text.includes("[Image #")) text = text.replace(IMAGES, " ");
		if (text.includes("\x1b")) text = text.replace(ANSI, "");
		return text.trim();
	}

	// A user message's text, as omp's stats join its text parts.
	function textOf(content) {
		if (typeof content === "string") return content;
		if (!Array.isArray(content)) return "";
		let text = "";
		for (const part of content) if (part?.type === "text" && typeof part.text === "string") text += part.text;
		return text;
	}

	// ---- One session file's numbers by UTC hour, so any time zone can put them on its own days. The cache holds them.

	class FileStats {
		constructor(kind) {
			this.kind = kind;
			this.cwd = null;
			this.start = null;
			this.models = [];
			this.tools = [];
			this.requests = new Map();
			this.prompts = new Map();
			this.words = new Map();
			this.toolUse = new Map();
		}

		static fromCache(cached) {
			const stats = new FileStats(cached.k);
			stats.cwd = cached.c;
			stats.start = cached.t;
			stats.models = cached.M;
			stats.tools = cached.T;
			for (const row of cached.r) stats.requests.set(row[0] * 4096 + row[1], row);
			for (const row of cached.u) stats.prompts.set(row[0], row);
			for (const row of cached.w) {
				const counts = new Map();
				for (let i = 1; i < row.length; i += 2) counts.set(row[i], row[i + 1]);
				stats.words.set(row[0], counts);
			}
			for (const row of cached.x) stats.toolUse.set(row[0] * 4096 + row[1], row);
			return stats;
		}

		toCache(file) {
			return {
				...file,
				k: this.kind,
				c: this.cwd,
				t: this.start,
				M: this.models,
				T: this.tools,
				r: [...this.requests.values()],
				u: [...this.prompts.values()],
				w: [...this.words].map(([hour, counts]) => [hour, ...[...counts].flat()]),
				x: [...this.toolUse.values()],
			};
		}

		// omp counts an assistant message (or a `model_usage` entry) with an api, a provider, a model and a usage
		// object as one request; `error` is the only stop reason that fails it.
		request(ms, api, provider, model, usage, stopReason, duration, ttft) {
			if (typeof api !== "string" || typeof provider !== "string" || typeof model !== "string") return;
			if (!usage || typeof usage !== "object") return;
			if (!(ms > 0)) return;
			const hour = Math.floor(ms / HOUR);
			const name = `${provider}/${model}`;
			let index = this.models.indexOf(name);
			if (index < 0) index = this.models.push(name) - 1;
			const key = hour * 4096 + index;
			let row = this.requests.get(key);
			if (!row) this.requests.set(key, (row = [hour, index, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
			const output = finite(usage.output);
			row[2]++;
			if (stopReason === "error") row[3]++;
			row[4] += finite(usage.input);
			row[5] += output;
			row[6] += finite(usage.cacheRead);
			row[7] += finite(usage.cacheWrite);
			row[8] += finite(usage.cost?.total);
			if (finite(duration) > 0) {
				row[9] += duration;
				row[10]++;
				row[13] += (output * 1000) / duration;
				row[14]++;
			}
			if (finite(ttft) > 0) {
				row[11] += ttft;
				row[12]++;
			}
		}

		tool(ms, name, calls, errors) {
			if (!(ms > 0)) return;
			const hour = Math.floor(ms / HOUR);
			let index = this.tools.indexOf(name);
			if (index < 0) index = this.tools.push(name) - 1;
			const key = hour * 4096 + index;
			const row = this.toolUse.get(key);
			if (!row) this.toolUse.set(key, [hour, index, calls, errors]);
			else {
				row[2] += calls;
				row[3] += errors;
			}
		}

		// A prompt: its words and characters, as omp counts them, over the whole text; whether its prose asks a
		// question; omp's tone signals in prose of under three lines (more is a paste or a list, as omp sees it); and
		// each cloud word of the prose once.
		prompt(ms, text) {
			if (!(ms > 0)) return;
			const hour = Math.floor(ms / HOUR);
			let row = this.prompts.get(hour);
			if (!row) this.prompts.set(hour, (row = [hour, ...new Array(PROMPT_SUMS + 1).fill(0)]));
			row[1]++;
			const trimmed = text.trim();
			const words = trimmed ? count(trimmed, NON_SPACE) : 0;
			row[2] += words;
			row[3] += trimmed.length;
			let length = 0;
			while (length < LENGTHS.length && words > LENGTHS[length]) length++;
			row[11 + length]++;
			row[PROMPT_SUMS + 1] = Math.max(row[PROMPT_SUMS + 1], words);
			if (!trimmed) return;
			const said = prose(trimmed);
			if (said.includes("?")) row[4]++;
			let lines = 0;
			for (const line of said.split("\n")) if (line.trim() && ++lines === 3) break;
			if (said && lines < 3) {
				row[5] += yelling(said);
				row[6] += count(said, PROFANITY);
				row[7] += count(said, BANGS) + count(said, WAILS) + count(said, DUDE) + count(said, FROWNS);
				row[8] += count(said, NO) + count(said, NOT_WHAT_I_MEANT);
				row[9] += count(said, AS_I_SAID) + count(said, STILL_BROKEN);
				row[10] += count(said, YOU_BROKE) + count(said, WHY_DID_YOU) + count(said, STOP_DOING);
			}
			// A paste repeats its words, so each spelling is normalized once.
			const lower = said.toLowerCase();
			const spellings = new Set();
			WORD.lastIndex = 0;
			for (let match = WORD.exec(lower); match !== null; match = WORD.exec(lower)) spellings.add(match[0]);
			const seen = new Set();
			for (let word of spellings) {
				if (word.includes("'") || word.includes("\u2019")) {
					word = word.replaceAll("\u2019", "'").replace(/'s$/, "").replace(/'+$/, "");
				}
				if (word.length >= 3 && word.length <= 24 && !STOPWORDS.has(word)) seen.add(word);
			}
			if (seen.size === 0) return;
			let counts = this.words.get(hour);
			if (!counts) this.words.set(hour, (counts = new Map()));
			for (const word of seen) counts.set(word, (counts.get(word) ?? 0) + 1);
		}

		// Reads the complete lines of [buf] and returns how many bytes they span. Only the lines stats need are
		// decoded: tool results and omp's injected messages, often the bulk of a file, are read by their first and last
		// bytes.
		parse(buf) {
			const end = buf.lastIndexOf(10) + 1;
			let pos = 0;
			while (pos < end) {
				const nl = buf.indexOf(10, pos);
				// `{"type":"` is 9 bytes: `m` starts message and model_usage, `s` the session header.
				const c = buf[pos + 9];
				if (c === 109) {
					if (startsWith(buf, pos, MESSAGE)) this.message(buf, pos, nl);
					else if (startsWith(buf, pos, MODEL_USAGE)) this.modelUsage(buf, pos, nl);
				} else if (c === 115 && this.start === null && startsWith(buf, pos, SESSION)) {
					const header = JSON.parse(buf.toString("utf8", pos, nl));
					this.cwd = typeof header.cwd === "string" ? header.cwd : null;
					this.start = Date.parse(header.timestamp) || null;
				}
				pos = nl + 1;
			}
			return end;
		}

		message(buf, pos, nl) {
			const head = Math.min(nl, pos + 512);
			const role = find(buf, ROLE, pos, head);
			const stamp = find(buf, TIMESTAMP, pos, head);
			if (role < 0 || stamp < 0) return this.parsedMessage(buf, pos, nl);
			const entryMs = isoAt(buf, stamp + TIMESTAMP.length, head);
			const name = role + ROLE.length;
			if (startsWith(buf, name, ASSISTANT)) this.assistant(buf, pos, nl, entryMs);
			else if (startsWith(buf, name, USER)) {
				// omp writes `attribution` after the content: `user` for what a person typed, `agent` (with `synthetic`)
				// for what omp injected. Only what a person typed is decoded.
				const tail = Math.max(pos, nl - 256);
				const attribution = find(buf, ATTRIBUTION, tail, nl);
				const typed = attribution >= 0
					? startsWith(buf, attribution + ATTRIBUTION.length, USER)
					: find(buf, SYNTHETIC, tail, nl) < 0;
				if (!typed) return;
				let text = "";
				try {
					text = textOf(JSON.parse(buf.toString("utf8", pos, nl)).message?.content);
				} catch {}
				this.prompt(entryMs, text);
			} else if (startsWith(buf, name, TOOL_RESULT)) {
				// `toolName` follows `toolCallId` at the start; `isError` sits after the content, before the timestamp.
				if (find(buf, IS_ERROR, Math.max(pos, nl - 192), nl) < 0) return;
				const at = find(buf, TOOL_NAME, pos, Math.min(nl, pos + 1024));
				const tool = at < 0 ? null : stringAt(buf, at + TOOL_NAME.length, nl);
				if (tool) this.tool(entryMs, tool, 0, 1);
			}
		}

		// The fields after an assistant message's content parse on their own (`{"api":...,"usage":...}`), which skips
		// decoding the content; the content is only searched for tool call names. Any other shape is parsed whole.
		assistant(buf, pos, nl, entryMs) {
			const api = buf.subarray(pos, nl).lastIndexOf(API);
			let fields = null;
			if (api >= 0 && buf[nl - 1] === 125) {
				try {
					fields = JSON.parse(`{${buf.toString("utf8", pos + api + 1, nl - 1)}`);
				} catch {}
			}
			if (typeof fields?.provider !== "string" || typeof fields.model !== "string") return this.parsedMessage(buf, pos, nl);
			const ms = finite(fields.timestamp) > 0 ? fields.timestamp : entryMs;
			const stop = fields.stopReason ?? (fields.errorMessage ? "error" : "aborted");
			this.request(ms, fields.api, fields.provider, fields.model, fields.usage, stop, fields.duration, fields.ttft);
			const content = buf.subarray(pos, pos + api);
			for (let at = content.indexOf(TOOL_CALL); at >= 0; at = content.indexOf(TOOL_CALL, at + TOOL_CALL.length)) {
				const nameAt = find(content, NAME, at, Math.min(content.length, at + 256));
				const tool = nameAt < 0 ? null : stringAt(content, nameAt + NAME.length, content.length);
				if (tool) this.tool(ms, tool, 1, 0);
			}
		}

		parsedMessage(buf, pos, nl) {
			let entry;
			try {
				entry = JSON.parse(buf.toString("utf8", pos, nl));
			} catch {
				return;
			}
			const message = entry?.message;
			const entryMs = Date.parse(entry?.timestamp);
			if (message?.role === "assistant") {
				const ms = finite(message.timestamp) > 0 ? message.timestamp : entryMs;
				const stop = message.stopReason ?? (message.errorMessage ? "error" : "aborted");
				this.request(ms, message.api, message.provider, message.model, message.usage, stop, message.duration, message.ttft);
				if (!Array.isArray(message.content)) return;
				for (const part of message.content) {
					if (part?.type === "toolCall" && typeof part.name === "string") this.tool(ms, part.name, 1, 0);
				}
			} else if (message?.role === "user") {
				if (message.synthetic !== true && message.attribution !== "agent") this.prompt(entryMs, textOf(message.content));
			} else if (message?.role === "toolResult" && message.isError === true && typeof message.toolName === "string") {
				this.tool(entryMs, message.toolName, 0, 1);
			}
		}

		modelUsage(buf, pos, nl) {
			let entry;
			try {
				entry = JSON.parse(buf.toString("utf8", pos, nl));
			} catch {
				return;
			}
			// omp gives a `model_usage` entry no duration or ttft, and `stop` unless it names its stop reason.
			const ms = Date.parse(entry.timestamp);
			this.request(ms, entry.api, entry.provider, entry.model, entry.usage, entry.stopReason ?? "stop", null, null);
		}
	}

	function readRange(fd, from, to) {
		const buf = Buffer.allocUnsafe(to - from);
		let read = 0;
		while (read < buf.length) {
			const n = fs.readSync(fd, buf, read, buf.length - read, from + read);
			if (n === 0) break;
			read += n;
		}
		return read === buf.length ? buf : buf.subarray(0, read);
	}

	// What tells an append from a rewrite: a hash of the 256 bytes before the read offset.
	function tailHash(fd, offset) {
		return offset === 0 ? "" : Bun.hash(readRange(fd, Math.max(0, offset - 256), offset)).toString(16);
	}

	// Reads [job] (a file, its kind, size, mtime and inode, and its cache entry if it has one) and returns its new
	// cache entry, whether it was read from the cached offset on, and how many bytes were read; or an error.
	function read(job) {
		let fd;
		try {
			fd = fs.openSync(job.file, "r");
			const cached = job.cached;
			// omp appends; a file that grew with its bytes before the cached offset unchanged is read from there on.
			// Anything else (a rewrite, a shorter file, a new inode) is read again from the start.
			const appended =
				cached !== undefined && cached.i === job.ino && job.size >= cached.o && tailHash(fd, cached.o) === cached.h;
			const stats = appended ? FileStats.fromCache(cached) : new FileStats(job.kind);
			const from = appended ? cached.o : 0;
			const buf = readRange(fd, from, job.size);
			const offset = from + stats.parse(buf);
			const file = { s: job.size, m: job.mtime, i: job.ino, o: offset, h: tailHash(fd, offset) };
			return { appended, read: buf.length, entry: stats.toCache(file) };
		} catch (error) {
			return { error: `${job.file}: ${error?.message ?? error}` };
		} finally {
			if (fd !== undefined) fs.closeSync(fd);
		}
	}

	return { read, LENGTHS, PROMPT_SUMS };
}

// Reads [jobs] on up to 8 threads, the biggest files first, each to the least loaded thread; the results come in the
// jobs' order.
async function readInWorkers(jobs, threads) {
	const shares = Array.from({ length: threads }, () => ({ bytes: 0, jobs: [] }));
	const order = jobs.map((_, index) => index).sort((a, b) => jobs[b].size - jobs[a].size);
	for (const index of order) {
		const share = shares.reduce((least, share) => (share.bytes < least.bytes ? share : least));
		share.jobs.push([index, jobs[index]]);
		share.bytes += jobs[index].size;
	}
	const source = `const { read } = (${sessionReader})();
self.onmessage = (event) => postMessage(event.data.map(([index, job]) => [index, read(job)]));`;
	const url = URL.createObjectURL(new Blob([source], { type: "application/javascript" }));
	const results = new Array(jobs.length);
	await Promise.all(
		shares.map((share) => {
			const { promise, resolve, reject } = Promise.withResolvers();
			const worker = new Worker(url);
			worker.onmessage = (event) => {
				for (const [index, result] of event.data) results[index] = result;
				worker.terminate();
				resolve();
			};
			worker.onerror = (event) => {
				worker.terminate();
				reject(new Error(`a stats worker failed: ${event.message ?? event}`));
			};
			worker.postMessage(share.jobs);
			return promise;
		}),
	);
	URL.revokeObjectURL(url);
	return results;
}

function subdirectories(dir) {
	try {
		return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => path.join(dir, d.name));
	} catch {
		return [];
	}
}

// The session directories of every omp profile, as the app's session listing finds them.
function sessionRoots() {
	const env = process.env;
	const config = path.join(home, env.PI_CONFIG_DIR || ".omp");
	const roots = [path.join(config, "agent", "sessions")];
	if (env.PI_CODING_AGENT_DIR) roots.push(path.join(env.PI_CODING_AGENT_DIR, "sessions"));
	if (env.XDG_DATA_HOME) roots.push(path.join(env.XDG_DATA_HOME, "omp", "sessions"));
	for (const profile of subdirectories(path.join(config, "profiles"))) roots.push(path.join(profile, "agent", "sessions"));
	if (env.XDG_DATA_HOME) {
		for (const profile of subdirectories(path.join(env.XDG_DATA_HOME, "omp", "profiles"))) {
			roots.push(path.join(profile, "sessions"));
		}
	}
	return [...new Set(roots.map((root) => path.resolve(root)))];
}

// 0 a main session, 1 a subagent's, 2 the advisor's; omp's stats tell them apart the same way.
function kindOf(root, file) {
	const name = path.basename(file);
	if (name === "__advisor.jsonl" || (name.startsWith("__advisor.") && name.endsWith(".jsonl"))) return 2;
	return path.relative(root, file).split(path.sep).length <= 2 ? 0 : 1;
}

// ---- Scan: every session file, read only past what the cache already holds.

const { read, LENGTHS, PROMPT_SUMS } = sessionReader();

// The cache: per-file numbers, and the cloud words they use by index in [words].
let cache = {};
let words = [];
try {
	const loaded = JSON.parse(fs.readFileSync(cachePath, "utf8"));
	if (loaded?.v === CACHE_VERSION && loaded.files && Array.isArray(loaded.words)) {
		cache = loaded.files;
		words = loaded.words;
	}
} catch {}
const cacheRead = performance.now();

// A file's word rows are `[hour, word, prompts, word, prompts, ...]`: in the cache a word is its index in [words],
// on the way to and from the reader its text.
const spelled = (rows) => rows.map((row) => row.map((value, i) => (i % 2 === 1 ? words[value] : value)));
let indices = null;
function indexOf(word) {
	indices ??= new Map(words.map((word, index) => [word, index]));
	let index = indices.get(word);
	if (index === undefined) indices.set(word, (index = words.push(word) - 1));
	return index;
}

// Files in the order they were found; the ones the cache cannot answer are read below.
const files = new Map();
const jobs = [];
let toRead = 0;
const scan = { files: 0, bytes: 0, parsed: 0, appended: 0, read: 0, errors: 0, error: null, threads: 1 };
for (const root of sessionRoots()) {
	let entries;
	try {
		entries = fs.readdirSync(root, { withFileTypes: true, recursive: true });
	} catch {
		continue;
	}
	for (const dirent of entries) {
		if (!dirent.isFile() || !dirent.name.endsWith(".jsonl")) continue;
		const file = path.join(dirent.parentPath ?? dirent.path, dirent.name);
		if (files.has(file)) continue;
		let st;
		try {
			st = fs.statSync(file);
		} catch (error) {
			scan.errors++;
			scan.error ??= `${file}: ${error?.message ?? error}`;
			continue;
		}
		scan.files++;
		scan.bytes += st.size;
		const cached = cache[file];
		if (cached && cached.i === st.ino && cached.s === st.size && cached.m === st.mtimeMs) {
			files.set(file, cached);
			continue;
		}
		files.set(file, null);
		jobs.push({
			file,
			kind: kindOf(root, file),
			size: st.size,
			mtime: st.mtimeMs,
			ino: st.ino,
			cached: cached && { ...cached, w: spelled(cached.w) },
		});
		toRead += cached?.i === st.ino && st.size >= cached.o ? st.size - cached.o : st.size;
	}
}

// A first scan reads every byte: on a machine with more cores, a thread each (at most 8, one core left over) reads
// 32 MB or more of it.
const cores = os.availableParallelism?.() ?? os.cpus().length;
scan.threads = typeof Worker === "function" ? Math.max(1, Math.min(8, cores - 1, jobs.length, Math.floor(toRead / PARALLEL_BYTES))) : 1;
const results = scan.threads > 1 ? await readInWorkers(jobs, scan.threads) : jobs.map(read);
for (const [index, result] of results.entries()) {
	const job = jobs[index];
	if (result.error !== undefined) {
		scan.errors++;
		scan.error ??= result.error;
		files.delete(job.file);
		continue;
	}
	const entry = result.entry;
	entry.w = entry.w.map((row) => row.map((value, i) => (i % 2 === 1 ? indexOf(value) : value)));
	files.set(job.file, entry);
	if (result.appended) scan.appended++;
	else scan.parsed++;
	scan.read += result.read;
}
const scanned = performance.now();

if (scan.parsed + scan.appended > 0 || Object.keys(cache).length !== files.size) {
	// Words of files that are gone or rewritten stay in the table until it is twice the size of what is used.
	const used = new Uint8Array(words.length);
	let usedCount = 0;
	for (const file of files.values()) {
		for (const row of file.w) {
			for (let i = 1; i < row.length; i += 2) {
				if (!used[row[i]]) usedCount++;
				used[row[i]] = 1;
			}
		}
	}
	if (words.length > 2 * usedCount + 1024) {
		const moved = new Int32Array(words.length);
		const kept = [];
		for (const [index, word] of words.entries()) if (used[index]) moved[index] = kept.push(word) - 1;
		for (const file of files.values()) for (const row of file.w) for (let i = 1; i < row.length; i += 2) row[i] = moved[row[i]];
		words = kept;
	}
	// Devices may run this at the same time; each writes its own file and renames it over the cache.
	fs.mkdirSync(cacheDir, { recursive: true });
	const temporary = `${cachePath}.${process.pid}.tmp`;
	fs.writeFileSync(temporary, JSON.stringify({ v: CACHE_VERSION, words, files: Object.fromEntries(files) }));
	fs.renameSync(temporary, cachePath);
	// A cache of another version is never read again.
	for (const name of fs.readdirSync(cacheDir)) {
		if (/^cache-v\d+\.json$/.test(name) && name !== path.basename(cachePath)) fs.rmSync(path.join(cacheDir, name), { force: true });
	}
}
const saved = performance.now();

// ---- Totals: on the device's local days ([input.zone]), for ranges that end on [input.today].

const zone = input.zone;
const localHours = new Map();
// The device's local hour (hours since the epoch in local time) of a UTC hour.
function localHour(hour) {
	let local = localHours.get(hour);
	if (local !== undefined) return local;
	const ms = hour * HOUR;
	let lo = 0;
	let hi = zone.length - 1;
	while (lo < hi) {
		const mid = (lo + hi + 1) >> 1;
		if (zone[mid][0] <= ms) lo = mid;
		else hi = mid - 1;
	}
	local = Math.floor((ms + zone[lo][1] * 60000) / HOUR);
	localHours.set(hour, local);
	return local;
}

// Monday first: the epoch's first day was a Thursday.
const slotOf = (hour) => ((((Math.floor(hour / 24) + 3) % 7) + 7) % 7) * 24 + (((hour % 24) + 24) % 24);

const ranges = input.ranges.map((days) => ({
	days,
	from: days === 0 ? -Infinity : input.today - days + 1,
	// requests, errors, input, output, cacheRead, cacheWrite, cost, durationSum, durationCount, ttftSum, ttftCount,
	// tokensPerSecondSum, tokensPerSecondCount, prompts, sessions, toolCalls, toolErrors
	totals: new Array(REQUEST_FIELDS + 4).fill(0),
	models: new Map(),
	projects: new Map(),
	tools: new Map(),
	hours: new Array(168).fill(0),
	agents: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
	// The prompt row's sums from words on (words, characters, questions, the six tone signals, the lengths).
	prompted: new Array(PROMPT_SUMS - 1).fill(0),
	longest: null,
	promptHours: new Array(168).fill(0),
	words: [],
}));
// day -> [day, requests, errors, tokens, cost, prompts, sessions, toolCalls, words]
const days = new Map();
function dayRow(day) {
	let row = days.get(day);
	if (!row) days.set(day, (row = [day, 0, 0, 0, 0, 0, 0, 0, 0]));
	return row;
}
// project -> [cwd, requests, tokens, cost, sessions, prompts]
function projectRow(range, cwd) {
	let row = range.projects.get(cwd);
	if (!row) range.projects.set(cwd, (row = [cwd, 0, 0, 0, 0, 0]));
	return row;
}
// Cloud words go to the narrowest range that holds their day (a ring), counted by their index in [words]; the ranges
// add the rings up from the narrowest out, so each word count is touched once, not once per range.
const narrowFirst = ranges.map((_, index) => index).sort((a, b) => ranges[b].from - ranges[a].from);
const rings = narrowFirst.map(() => new Float64Array(words.length));

let first = Infinity;
let last = -Infinity;
for (const file of files.values()) {
	const cwd = file.c ?? "";
	for (const row of file.r) {
		const hour = localHour(row[0]);
		const day = Math.floor(hour / 24);
		const slot = slotOf(hour);
		const tokens = row[4] + row[5] + row[6] + row[7];
		first = Math.min(first, row[0] * HOUR);
		last = Math.max(last, (row[0] + 1) * HOUR - 1);
		const d = dayRow(day);
		d[1] += row[2];
		d[2] += row[3];
		d[3] += tokens;
		d[4] += row[8];
		const model = file.M[row[1]];
		for (const range of ranges) {
			if (day < range.from) continue;
			for (let i = 0; i < REQUEST_FIELDS; i++) range.totals[i] += row[2 + i];
			let m = range.models.get(model);
			if (!m) range.models.set(model, (m = [model, ...new Array(REQUEST_FIELDS).fill(0)]));
			for (let i = 0; i < REQUEST_FIELDS; i++) m[1 + i] += row[2 + i];
			const p = projectRow(range, cwd);
			p[1] += row[2];
			p[2] += tokens;
			p[3] += row[8];
			range.hours[slot] += row[2];
			const agent = range.agents[file.k];
			agent[0] += row[2];
			agent[1] += tokens;
			agent[2] += row[8];
		}
	}
	for (const row of file.u) {
		const hour = localHour(row[0]);
		const day = Math.floor(hour / 24);
		const slot = slotOf(hour);
		const d = dayRow(day);
		d[5] += row[1];
		d[8] += row[2];
		const longest = row[PROMPT_SUMS + 1];
		for (const range of ranges) {
			if (day < range.from) continue;
			range.totals[REQUEST_FIELDS] += row[1];
			projectRow(range, cwd)[5] += row[1];
			for (let i = 0; i < range.prompted.length; i++) range.prompted[i] += row[2 + i];
			range.promptHours[slot] += row[1];
			// The latest of equal ones.
			if (longest > 0 && (!range.longest || longest > range.longest[0] || (longest === range.longest[0] && day > range.longest[1]))) {
				range.longest = [longest, day];
			}
		}
	}
	for (const row of file.w) {
		const day = Math.floor(localHour(row[0]) / 24);
		const ring = narrowFirst.findIndex((index) => day >= ranges[index].from);
		if (ring < 0) continue;
		const counts = rings[ring];
		for (let i = 1; i < row.length; i += 2) counts[row[i]] += row[i + 1];
	}
	for (const row of file.x) {
		const day = Math.floor(localHour(row[0]) / 24);
		dayRow(day)[7] += row[2];
		const name = file.T[row[1]];
		for (const range of ranges) {
			if (day < range.from) continue;
			range.totals[REQUEST_FIELDS + 2] += row[2];
			range.totals[REQUEST_FIELDS + 3] += row[3];
			let tool = range.tools.get(name);
			if (!tool) range.tools.set(name, (tool = [name, 0, 0]));
			tool[1] += row[2];
			tool[2] += row[3];
		}
	}
	// A session is a main session file with at least one request, on the day it started.
	if (file.k === 0 && file.t && file.r.length > 0) {
		const day = Math.floor(localHour(Math.floor(file.t / HOUR)) / 24);
		dayRow(day)[6]++;
		for (const range of ranges) {
			if (day < range.from) continue;
			range.totals[REQUEST_FIELDS + 1]++;
			projectRow(range, cwd)[4]++;
		}
	}
}

// The [limit] words most prompts use, most first (ties by word). A histogram of the counts finds the count the last
// of them has; only words with at least that many are sorted.
function topWords(counts, limit) {
	let highest = 0;
	for (const n of counts) if (n > highest) highest = n;
	const histogram = new Uint32Array(highest + 1);
	for (const n of counts) histogram[n]++;
	let floor = highest;
	for (let seen = 0; floor > 1; floor--) {
		seen += histogram[floor];
		if (seen >= limit) break;
	}
	const kept = [];
	for (let index = 0; index < counts.length; index++) {
		if (counts[index] >= floor && counts[index] > 0) kept.push([words[index], counts[index]]);
	}
	return kept.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, limit);
}
const running = new Float64Array(words.length);
for (const [ring, index] of narrowFirst.entries()) {
	const counts = rings[ring];
	for (let i = 0; i < running.length; i++) running[i] += counts[i];
	ranges[index].words = topWords(running, TOP_WORDS);
}

// Dollars to a hundredth of a cent, other sums to whole numbers: the payload carries no float noise.
const round = (row, costAt) =>
	row.map((value, i) => (typeof value !== "number" ? value : i === costAt ? Math.round(value * 10000) / 10000 : Math.round(value)));
const out = {
	v: 2,
	first: Number.isFinite(first) ? first : null,
	last: Number.isFinite(last) ? last : null,
	days: [...days.values()].sort((a, b) => a[0] - b[0]).map((row) => round(row, 4)),
	ranges: ranges.map((range) => ({
		days: range.days,
		totals: round(range.totals, 6),
		models: [...range.models.values()].sort((a, b) => b[1] - a[1]).map((row) => round(row, 7)),
		projects: [...range.projects.values()].sort((a, b) => b[2] - a[2]).slice(0, 50).map((row) => round(row, 3)),
		tools: [...range.tools.values()].sort((a, b) => b[1] - a[1]),
		hours: range.hours,
		agents: range.agents.map((row) => round(row, 2)),
		prompts: {
			sums: range.prompted.slice(0, 9),
			lengths: range.prompted.slice(9),
			bounds: LENGTHS,
			longest: range.longest,
			hours: range.promptHours,
			words: range.words,
		},
	})),
	scan: {
		...scan,
		cacheMs: Math.round(cacheRead - started),
		scanMs: Math.round(scanned - cacheRead),
		saveMs: Math.round(saved - scanned),
		ms: Math.round(performance.now() - started),
	},
};
// ASCII only, so no code page on the way (Windows PowerShell) can change a path.
const json = JSON.stringify(out).replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
process.stdout.write(`\n${input.marker}:begin\n${json}\n${input.marker}:end\n`);
''';
