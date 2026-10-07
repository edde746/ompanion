# activity-stats: the Stats tab's numbers

How the usage pane's Stats tab gets every machine's activity: a script that runs on the machine with omp's own Bun,
reads the omp session files, keeps per-file numbers between calls, and prints one small JSON document of totals.
Code: `packages/omp_core/lib/src/host/activity_stats.dart` (the script, `readActivityStats`, the typed result),
`lib/screens/usage/activity_overview.dart` (machines merged, streaks, chart series),
`lib/screens/usage/activity_view.dart` and `lib/screens/usage/usage_pane.dart` (the tab).

## Why not `omp stats --json`

`omp stats` first syncs every session file into `~/.omp/stats.db` (SQLite, a row per request), then answers from
it. Measured on this Mac with omp 18.6.3 on a synthetic home of 2,438 session files (2.35 GB, 128,767 requests over
312 days): 19.4 s for the first call, 0.16 to 0.57 s for the next ones; omp 18.3.1 took 31.5 s cold. Its JSON has
no days, so a contribution grid or a streak cannot come from it, and its hourly series covers 24 hours. The stats page
on the machine page (`lib/screens/config/stats_page.dart`) still shows `omp stats` for one machine.

## Running

`readActivityStats(link, probe, query)` runs the script with the probed omp binary, which is a Bun executable: with
`BUN_BE_BUN=1` set it is Bun itself (`omp --version` then prints Bun's version, e.g. `1.4.2`), and `bun run -` reads
the script from stdin. omp installed as a package (`omp --version` prints `omp/<version>`) is a script run by `bun`;
the script then runs with the `bun` on `PATH`, and fails with a message when there is none. Both run with
`BUN_RUNTIME_TRANSPILER_CACHE_PATH=0`: the script's marker changes on every call, so Bun's transpiler cache would
keep a new 25 KB file per call in the machine's cache directory and never read one back.

- POSIX: one `runPosixScript` with the login shell's `PATH` in front (`HostProbe.loginPathExport`); the script goes
  in through a quoted heredoc.
- Windows: one `runPowerShell`; the script is written to `%USERPROFILE%\.ompanion\stats\<marker>.js` (Windows
  PowerShell would pipe it to stdin in the console's code page) and removed after the run.

The script prints its JSON between `<marker>:begin` and `<marker>:end` lines; the JSON is ASCII only (every character
from U+007F up is a `\u` escape), so no code page on the way changes a path.

## Input

The Dart side puts `const input = {...};` in front of the script:

|Field|Meaning|
|---|---|
|`zone`|the device's time zone as `[start ms, offset minutes]` pairs, oldest first, from 2020 to two days after now; the first pair also covers everything before it. `ActivityQuery.local` finds each change to the minute|
|`today`|the device's today as a local day number (days since 1970-01-01 of the local date)|
|`ranges`|`[7, 30, 365, 0]`: the last 7, 30 and 365 days ending today, and all time|
|`marker`|the output marker|

Every machine thus puts a request on the day and hour the device's calendar shows, whatever the machine's own zone,
and every machine's ranges end on the same day.

## Files

The session directories of every omp profile, the ones the session listing reads: `<config>/agent/sessions` (config
is `$PI_CONFIG_DIR` under the home, else `~/.omp`), `$PI_CODING_AGENT_DIR/sessions`, `$XDG_DATA_HOME/omp/sessions`,
`<config>/profiles/<name>/agent/sessions` and `$XDG_DATA_HOME/omp/profiles/<name>/sessions`; every `*.jsonl` under
them, recursively, each path once. A file directly in a project directory (`<root>/<project>/<file>.jsonl`) is a main
session, a deeper one a subagent's, `__advisor.jsonl` (and `__advisor.<x>.jsonl`) the advisor's: omp's own stats tell
them apart the same way.

## What counts

The rules are omp's stats parser's (`packages/stats/src/parser.ts`, read in the omp 18.6.3 binary):

- **A request** is an assistant message with string `api`, `provider` and `model` and a `usage` object, or a
  `model_usage` entry with the same fields. It is placed at the message's own `timestamp` (epoch ms), else the
  entry's. Its stop reason is `stopReason`, else `error` when it has an `errorMessage`, else `aborted`; a
  `model_usage` entry without one is `stop`. Only `error` fails a request.
- **Tokens and cost**: `usage.input`, `output`, `cacheRead`, `cacheWrite` and `cost.total`, as omp priced them.
  Speed is `output * 1000 / duration` per request with a duration; time to first token is `ttft`. Both are averaged
  over the requests that have them.
- **A prompt** is a user message a person typed: `attribution` `user`, or, in files from before omp wrote
  `attribution`, one without `synthetic: true`. omp's injected messages (`attribution` `agent`) are not prompts.
- **A tool call** is a `toolCall` part of an assistant message's content; a tool result with `isError: true`
  counts as that tool's error.
- **A session** is a main session file with at least one request, counted on the day its header's `timestamp` falls
  on; its project is the header's `cwd`.

The script decodes only what it needs. A line's type is told by its 10th byte (`m`: `message` or `model_usage`;
`s`: the `session` header). In a message it searches the first 512 bytes for the role and the timestamp. An assistant
message's fields after its content (`,"api":...` to the closing brace) parse on their own, so the content is never
decoded; tool call names are found by searching it. A user message's attribution and a tool result's `isError` sit
in the last 256 and 192 bytes. A line of any other shape is parsed whole with `JSON.parse`.

## The cache

`~/.ompanion/stats/cache-v1.json` keeps, per file: its size, mtime and inode, the offset read up to (the end of its
last complete line), a hash of the 256 bytes before that offset, its kind, `cwd` and start, and its numbers by UTC
hour: requests per hour and model (the 13 request sums), prompts per hour, tool calls and errors per hour and tool. A
file is then:

- **skipped** when its size, mtime and inode match;
- **read from the offset** when it has the same inode, has not shrunk and the hash still matches: omp appended;
- **read whole** otherwise: a new file, a rewrite (compaction, `/clear`, a branch), a shorter file.

A half-written last line is left for the next call. The cache is rewritten only when something was read or a file is
gone: to `<cache>.<pid>.tmp`, then renamed over it, so two devices asking at once never leave a torn cache. A cache
with another version is ignored and rebuilt. Hours are UTC, so one cache serves devices in any zone.

## Output

```json
{"v":1,"first":1755064800000,"last":1791367199999,
 "days":[[20343,128,2,3120544,12.4151,9,3,211], ...],
 "ranges":[{"days":7,"totals":[...17 numbers],"models":[["anthropic/claude-sonnet-4-5", ...13 sums]],
   "projects":[["/home/me/code/app",requests,tokens,cost,sessions,prompts]],"tools":[["read",calls,errors]],
   "hours":[...168],"agents":[[requests,tokens,cost],[...],[...]]}, ...],
 "scan":{"files":2438,"bytes":2348595162,"parsed":0,"appended":1,"read":67344,"errors":0,"error":null,
   "cacheMs":6,"scanMs":12,"saveMs":4,"ms":31}}
```

- `days`: every local day with activity, oldest first: day, requests, failed, tokens, cost, prompts, sessions,
  tool calls.
- `ranges`: one per input range. `totals`: the 13 request sums (requests, failed, input, output, cache read, cache
  write, cost, duration sum and count, ttft sum and count, tokens-per-second sum and count), then prompts, sessions,
  tool calls, tool errors. `models` most requests first; `projects` most tokens first, at most 50; `tools` most calls
  first; `hours` requests per local weekday and hour, Monday 00:00 first; `agents` main sessions, subagents, the
  advisor.
- `first`, `last`: the first and last hour with a request, epoch ms.
- `scan`: how the numbers came about. `errors` counts unreadable files and `error` names the first.

Costs are rounded to a hundredth of a cent and other sums to integers. The payload depends on the days used, not on
the files: about 22 KB for 312 active days.

## Merging machines

The app merges the machines' answers (`mergeActivity`): days by day number, models by `provider/model`, tools by
name, hours by slot, agents by kind. A project is its path with the machine's home as `~`, so the same checkout on
two machines is one project; a path outside the home stays as it is. Streaks count days with a request or a prompt:
the current streak runs back from today, or from yesterday while today has nothing yet.

## Measured

omp 18.6.3, synthetic homes made of omp's own line shapes.

|Where|Files|Cold|Warm|After appended turns|`omp stats --json` cold / warm|
|---|---|---|---|---|---|
|This Mac (arm64, local link)|2,438, 2.35 GB|1,180 ms|64–67 ms end to end, 30 ms in the script|61 ms: 3 files, 150 KB read|19.4 s / 0.16–0.57 s|
|Docker test machine over SSH|774, 754 MB|336 ms|24–29 ms end to end, 10–11 ms in the script|27 ms, 67 KB read|2.5 s / 126–130 ms; 258 ms after the append|

In the app (macOS profile build, both machines asked at once): 1.3 s from opening the tab cold to both answers,
31–99 ms per machine on a refresh. Switching ranges and scrolling the tab drew 1,254 frames with a 2.0–2.2 ms mean
raster and one frame over 16.7 ms.

Both give the same request count and cost as `omp stats` on the same files, except where a file repeats an entry id:
omp's database keeps one row per `(session_file, entry_id)` and drops the rest; the script counts every line.
