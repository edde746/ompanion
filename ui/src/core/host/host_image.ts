// Port of packages/omp_core/lib/src/host/host_image.dart.
import { asJsonObject, enumByName, integer, optInt, optString } from "../rpc/json_fields";
import type { HostFiles, HostLink } from "../transport/host_link";
import { script } from "../util/script";
import { hostProbeIsWindows, type HostProbe } from "./probe";
import {
  newMarker,
  psQuote,
  runPosixScript,
  runPowerShell,
  scriptResultPayload,
  shQuote,
  toSftpPath,
} from "./scripts";

/**
 * ffmpeg on a machine, for making image previews there: [ffmpeg] is its host-native path (absent without one), and
 * [webp] is true when that build has the libwebp encoder.
 */
export interface ImageTools {
  readonly ffmpeg?: string;
  readonly webp: boolean;
}

/**
 * Where ffmpeg is looked for when it is not on PATH. The non-login shell of an SSH exec on macOS has no Homebrew
 * directory on PATH, which is also why the probe searches them for omp.
 */
export const ffmpegLocations: readonly string[] = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"];

/** Finds ffmpeg on the machine: on PATH, else in [locations] (POSIX only), and whether it encodes WebP. */
export async function probeImageTools(
  link: HostLink,
  probe: HostProbe,
  options: { locations?: readonly string[] } = {},
): Promise<ImageTools> {
  const marker = newMarker();
  const result = hostProbeIsWindows(probe)
    ? await runPowerShell(link, probe.commandShell, windowsImageToolsScript(marker))
    : await runPosixScript(link, posixImageToolsScript(marker, options.locations ?? ffmpegLocations));
  return parseImageTools(scriptResultPayload(result, marker));
}

export function posixImageToolsScript(marker: string, locations: readonly string[]): string {
  return `m=${shQuote(marker)}\nset --${locations.map((l) => ` ${shQuote(l)}`).join("")}\n${posixToolsBody}`;
}

const posixToolsBody = script`LC_ALL=C; export LC_ALL
q() { v=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '"%s"' "$v"; }
f=$(command -v ffmpeg 2>/dev/null); case $f in /*) ;; *) f= ;; esac
if [ -z "$f" ]; then for x in "$@"; do if [ -f "$x" ] && [ -x "$x" ]; then f=$x; break; fi; done; fi
w=; if [ -n "$f" ] && "$f" -nostdin -hide_banner -encoders </dev/null 2>/dev/null | grep -q ' libwebp '; then w=1; fi
printf '\n%s:begin\n{"ffmpeg":' "$m"; q "$f"; printf ',"webp":"%s"}\n%s:end\n' "$w" "$m"
`;

export function windowsImageToolsScript(marker: string): string {
  return `$m = ${psQuote(marker)}\n${windowsToolsBody}`;
}

const windowsToolsBody = script`$f = $null
$c = Get-Command -Name 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) { $f = $c.Source }
$w = $null
if ($f) {
  try { if (& $f -nostdin -hide_banner -encoders 2>$null | Select-String -SimpleMatch ' libwebp ') { $w = '1' } } catch { $w = $null }
}
$json = ConvertTo-OmpAscii (ConvertTo-Json -InputObject ([ordered]@{ ffmpeg = $f; webp = $w }) -Compress)
[Console]::Out.Write("\`n" + $m + ":begin\`n" + $json + "\`n" + $m + ":end\`n")
`;

/** Parses the payload of [posixImageToolsScript] and [windowsImageToolsScript]. */
export function parseImageTools(payload: string): ImageTools {
  const json = asJsonObject(JSON.parse(payload), "image tools");
  const ffmpeg = optString(json, "ffmpeg");
  return { ffmpeg: ffmpeg === "" ? undefined : ffmpeg, webp: optString(json, "webp") === "1" };
}

/** The largest file the image operation reads or hands to ffmpeg. */
export const imageInputCap = 64 << 20;

/** The largest original sent without a preview. */
export const imageOriginalCap = 8 << 20;

/** Decodable images up to this size are sent as they are, even where ffmpeg could make a preview. */
export const imageKeepBytes = 256 << 10;

/** The long side of a preview, at most; smaller images keep their size. */
export const imagePreviewSide = 1600;

/** The wall-clock limit of each ffmpeg run on the machine, in seconds. */
export const imageFfmpegSeconds = 20;

/**
 * Why a machine image cannot be shown. `unsupported`: an image format this app cannot decode, and no preview could be
 * made. `tooLarge`: over [imageOriginalCap] without a preview, or over [imageInputCap].
 */
export const hostImageIssues = ["missing", "notFile", "denied", "notImage", "unsupported", "tooLarge"] as const;
export type HostImageIssue = (typeof hostImageIssues)[number];

/** An image read from a machine, or why it could not be. */
export type HostImage = HostImageBytes | HostImageProblem;

export interface HostImageBytes {
  readonly kind: "HostImageBytes";
  readonly bytes: Uint8Array;
  readonly mimeType: string;
  /** The file's size on the machine, which [bytes] is shorter than for a [preview]. */
  readonly size: number;
  readonly modifiedMs: number;
  /** A downscaled copy ffmpeg made on the machine, not the file itself. */
  readonly preview: boolean;
  /** The file's pixel size when ffmpeg reported it. */
  readonly width?: number;
  readonly height?: number;
}

export interface HostImageProblem {
  readonly kind: "HostImageProblem";
  readonly issue: HostImageIssue;
  /** The file's size and modification time, when it is a readable file. */
  readonly size?: number;
  readonly modifiedMs?: number;
  /** ffmpeg's last words when it failed. */
  readonly detail?: string;
}

/** A file too large to send on its own that the user may still fetch: [fetchHostImage] with `original: true`. */
export function hostImageProblemCanLoadOriginal(problem: HostImageProblem): boolean {
  return problem.issue === "tooLarge" && problem.size !== undefined && problem.size <= imageInputCap;
}

/**
 * Reads the image file [path] (host-native, absolute) of the machine. Without [original], and when [tools] has ffmpeg,
 * a file larger than [imageKeepBytes] or one this app cannot decode becomes a preview on the machine: the first frame,
 * its long side at most [imagePreviewSide], WebP where ffmpeg encodes it, else PNG for images with transparent pixels
 * and JPEG for the rest (an alpha channel that leaves every pixel opaque, as in most screenshots, does not count). The
 * preview is written to `~/.ompanion/tmp`, read over [files] and deleted. With [original] the file itself is read, up
 * to [imageInputCap].
 */
export async function fetchHostImage(
  link: HostLink,
  files: HostFiles,
  probe: HostProbe,
  tools: ImageTools,
  path: string,
  options: { original?: boolean } = {},
): Promise<HostImage> {
  const original = options.original ?? false;
  const marker = newMarker();
  const ffmpeg = original ? undefined : tools.ffmpeg;
  const result = hostProbeIsWindows(probe)
    ? await runPowerShell(link, probe.commandShell, windowsImageScript(marker, path, { ffmpeg, webp: tools.webp }))
    : await runPosixScript(link, posixImageScript(marker, path, { ffmpeg, webp: tools.webp }));
  const report = parseImageReport(scriptResultPayload(result, marker));
  const out = report.out;
  try {
    const plan = planImage(report, path, { original });
    if (plan.kind === "ImageRefused") return plan.problem;
    const size = parseVideoSize(report.stream);
    return {
      kind: "HostImageBytes",
      bytes: await files.read(toSftpPath(plan.path)),
      mimeType: plan.mimeType,
      size: report.size,
      // A report without a problem carries the file's mtime.
      modifiedMs: report.modifiedMs!,
      preview: plan.preview,
      width: size?.width,
      height: size?.height,
    };
  } finally {
    if (out !== undefined) await files.remove(toSftpPath(out));
  }
}

/** What ffmpeg did with the file in the image script. */
export const ffmpegOutcomes = ["ok", "notImage", "failed", "timeout"] as const;
export type FfmpegOutcome = (typeof ffmpegOutcomes)[number];

/** The facts the image script printed about one file. Made by [hostImageReport]. */
export interface HostImageReport {
  /** `missing`, `notFile` or `denied` found by the script. */
  readonly problem?: HostImageIssue;
  readonly size: number;
  readonly modifiedMs?: number;
  /** The file's first 32 bytes as lowercase hex. */
  readonly magic: string;
  /** Absent when ffmpeg did not run. */
  readonly ffmpeg?: FfmpegOutcome;
  /** ffmpeg's line for the first video stream, e.g. `Stream #0:0: Video: png, rgba(pc), 3000x2000, …`. */
  readonly stream?: string;
  /** The preview (host-native path), its encoding (`webp`, `png`, `jpeg`) and size. */
  readonly out?: string;
  readonly format?: string;
  readonly outSize?: number;
  readonly error?: string;
}

/** A report with Dart's defaults: size 0 and no magic. */
export function hostImageReport(fields: Partial<HostImageReport>): HostImageReport {
  return { size: 0, magic: "", ...fields };
}

/** Parses the payload of [posixImageScript] and [windowsImageScript]. */
export function parseImageReport(payload: string): HostImageReport {
  const json = asJsonObject(JSON.parse(payload), "image report");
  const problem = optString(json, "problem");
  if (problem !== undefined) return hostImageReport({ problem: enumByName(hostImageIssues, problem) });
  const ffmpeg = optString(json, "ffmpeg");
  return hostImageReport({
    size: integer(json, "size"),
    modifiedMs: integer(json, "mtime") * 1000,
    magic: optString(json, "magic") ?? "",
    ffmpeg: ffmpeg === undefined ? undefined : enumByName(ffmpegOutcomes, ffmpeg),
    stream: nonEmpty(optString(json, "stream")),
    out: nonEmpty(optString(json, "out")),
    format: optString(json, "format"),
    outSize: optInt(json, "outSize"),
    error: nonEmpty(optString(json, "error")?.trim()),
  });
}

function nonEmpty(value: string | undefined): string | undefined {
  return value === "" ? undefined : value;
}

/** The width and height in an ffmpeg stream line (`…, 3000x2000 [SAR 1:1 DAR 3:2], …`), or undefined. */
export function parseVideoSize(stream: string | undefined): { width: number; height: number } | undefined {
  const match = /, (\d{1,6})x(\d{1,6})\b/.exec(stream ?? "");
  if (match === null) return undefined;
  return { width: Number(match[1]), height: Number(match[2]) };
}

/** The MIME type of an image this app decodes (PNG, JPEG, GIF, WebP, BMP), from its first bytes as hex, or undefined. */
export function decodableImageType(magic: string): string | undefined {
  if (magic.startsWith("89504e47")) return "image/png";
  if (magic.startsWith("ffd8ff")) return "image/jpeg";
  if (magic.startsWith("47494638")) return "image/gif";
  if (magic.startsWith("52494646") && magic.length >= 24 && magic.substring(16, 24) === "57454250") return "image/webp";
  if (magic.startsWith("424d")) return "image/bmp";
  return undefined;
}

/** Whether [magic] starts an image format this app cannot decode: TIFF, HEIF and AVIF, ICO, PSD, JPEG XL, SVG. */
export function isOtherImage(magic: string): boolean {
  return (
    magic.startsWith("49492a00") ||
    magic.startsWith("4d4d002a") ||
    (magic.length >= 24 && magic.substring(8, 16) === "66747970" && isoImageBrands[magic.substring(16, 24)] === true) ||
    magic.startsWith("00000100") ||
    magic.startsWith("38425053") ||
    magic.startsWith("ff0a") ||
    magic.startsWith("0000000c4a584c20") ||
    magic.startsWith("3c737667")
  );
}

/** `heic`, `heix`, `mif1`, `avif`, `avis` as hex: ISO base media brands of still images. */
const isoImageBrands: Record<string, true> = {
  "68656963": true,
  "68656978": true,
  "6d696631": true,
  "61766966": true,
  "61766973": true,
};

/** What [fetchHostImage] does with a report. */
export type ImagePlan = ImageRead | ImageRefused;

/** Read the file at [path]: the image itself, or the [preview] ffmpeg made. */
export interface ImageRead {
  readonly kind: "ImageRead";
  readonly path: string;
  readonly mimeType: string;
  readonly preview: boolean;
}

export interface ImageRefused {
  readonly kind: "ImageRefused";
  readonly problem: HostImageProblem;
}

/**
 * Decides between the preview, the file [path] itself and a problem for [report]. A preview no smaller than a
 * decodable original that may be sent as it is loses to it.
 */
export function planImage(report: HostImageReport, path: string, options: { original: boolean }): ImagePlan {
  if (report.problem !== undefined) {
    return { kind: "ImageRefused", problem: { kind: "HostImageProblem", issue: report.problem } };
  }
  const { size, modifiedMs } = report;
  const refuse = (issue: HostImageIssue, detail?: string): ImageRefused => ({
    kind: "ImageRefused",
    problem: { kind: "HostImageProblem", issue, size, modifiedMs, detail },
  });
  if (size > imageInputCap) return refuse("tooLarge");
  const type = decodableImageType(report.magic);
  const other = isOtherImage(report.magic);
  if (options.original) {
    if (type !== undefined) return { kind: "ImageRead", path, mimeType: type, preview: false };
    return refuse(other ? "unsupported" : "notImage");
  }
  if (report.ffmpeg === "ok" && report.out !== undefined) {
    const keep = type !== undefined && size <= imageOriginalCap && (report.outSize ?? size) >= size;
    if (keep) return { kind: "ImageRead", path, mimeType: type, preview: false };
    const previewType = report.format === undefined ? undefined : previewTypes[report.format];
    return { kind: "ImageRead", path: report.out, mimeType: previewType ?? "image/jpeg", preview: true };
  }
  if (type !== undefined) {
    return size <= imageOriginalCap ? { kind: "ImageRead", path, mimeType: type, preview: false } : refuse("tooLarge");
  }
  if (report.ffmpeg === "failed" || report.ffmpeg === "timeout") return refuse("unsupported", report.error);
  return refuse(other ? "unsupported" : "notImage");
}

const previewTypes: Record<string, string> = { webp: "image/webp", png: "image/png", jpeg: "image/jpeg" };

/**
 * The POSIX image script: checks that [path] is a readable regular file, prints its size, mtime and first bytes, and,
 * given [ffmpeg], makes the preview. Each ffmpeg run is killed after [seconds]; a preview left by a run whose link
 * dropped is deleted by a later run after ten minutes.
 */
export function posixImageScript(
  marker: string,
  path: string,
  options: { ffmpeg: string | undefined; webp: boolean; seconds?: number },
): string {
  const seconds = options.seconds ?? imageFfmpegSeconds;
  return (
    `m=${shQuote(marker)}; f=${shQuote(path)}; ff=${shQuote(options.ffmpeg ?? "")}; webp=${options.webp ? "1" : ""}\n` +
    `cap=${imageInputCap}; keep=${imageKeepBytes}; side=${imagePreviewSide}; secs=${seconds}\n` +
    posixImageBody
  );
}

const posixImageBody = script`LC_ALL=C; export LC_ALL
q() { v=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '"%s"' "$v"; }
say() { printf '\n%s:begin\n{%s}\n%s:end\n' "$m" "$1" "$m"; exit 0; }
[ -e "$f" ] || say '"problem":"missing"'
[ -f "$f" ] || say '"problem":"notFile"'
[ -r "$f" ] || say '"problem":"denied"'
if stat -c %s / >/dev/null 2>&1; then set -- $(stat -L -c '%s %Y' "$f"); else set -- $(stat -L -f '%z %m' "$f"); fi
size=$1; mtime=$2
magic=$(od -An -tx1 -N32 "$f" 2>/dev/null | tr -d ' \n')
r="\"size\":$size,\"mtime\":$mtime,\"magic\":\"$magic\""
[ -n "$ff" ] && [ "$size" -le "$cap" ] || say "$r"
case $magic in 89504e47* | ffd8ff* | 47494638* | 424d* | 52494646????????57454250*) [ "$size" -le "$keep" ] && say "$r" ;; esac
d=$HOME/.ompanion/tmp
(umask 077 && mkdir -p "$d") || say "$r,\"ffmpeg\":\"failed\",\"error\":$(q "cannot create $d")"
find "$d" -type f -name 'img-*' -mmin +10 -exec rm -f {} + 2>/dev/null
o=$d/img-$m
run() {
  "$ff" -nostdin -hide_banner -y "$@" </dev/null >/dev/null 2>"$o.log" &
  p=$!
  (i=0; while [ "$i" -lt "$secs" ]; do sleep 1; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done; kill -9 "$p") </dev/null >/dev/null 2>&1 &
  w=$!
  wait "$p"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
}
run -i "file:$f"
demux=$(sed -n 's/^Input #0, \(.*\), from .*/\1/p' "$o.log" | head -n 1)
stream=$(grep 'Stream #0:[0-9]*.*: Video: ' "$o.log" | head -n 1 | sed 's/^ *//')
r="$r,\"demux\":$(q "$demux"),\"stream\":$(q "$stream")"
[ "$rc" = 137 ] && { rm -f "$o.log"; say "$r,\"ffmpeg\":\"timeout\""; }
case $demux in image2 | *_pipe | gif | apng | webp) ;; *) rm -f "$o.log"; say "$r,\"ffmpeg\":\"notImage\"" ;; esac
pix=$(printf '%s\n' "$stream" | sed 's/.*Video: [^,]*, \([0-9a-z_]*\).*/\1/')
if [ -n "$webp" ]; then
  x=webp; set -- -c:v libwebp -quality 80
else
  x=jpeg
  case $pix in
    *rgba* | *bgra* | argb | abgr | yuva* | ya8 | ya16* | gbrap* | pal8 | ayuv* | vuya)
      run -i "file:$f" -map 0:v:0 -frames:v 1 -vf 'format=rgba,alphaextract,signalstats,metadata=print:key=lavfi.signalstats.YMIN' -f null -
      grep -q 'YMIN=255$' "$o.log" || x=png ;;
  esac
  if [ "$x" = png ]; then set -- -c:v png; else set -- -c:v mjpeg -pix_fmt yuvj420p -q:v 4; fi
fi
run -i "file:$f" -map 0:v:0 -frames:v 1 -vf "scale=w='min($side,iw)':h='min($side,ih)':force_original_aspect_ratio=decrease,setsar=1" -map_metadata -1 "$@" -f image2pipe "file:$o.$x"
e=$(tail -n 3 "$o.log")
rm -f "$o.log"
[ "$rc" = 137 ] && { rm -f "$o.$x"; say "$r,\"ffmpeg\":\"timeout\""; }
if [ "$rc" != 0 ] || [ ! -s "$o.$x" ]; then rm -f "$o.$x"; say "$r,\"ffmpeg\":\"failed\",\"error\":$(q "$e")"; fi
n=$(wc -c <"$o.$x" | tr -d ' ')
say "$r,\"ffmpeg\":\"ok\",\"out\":$(q "$o.$x"),\"format\":\"$x\",\"outSize\":$n"
`;

/**
 * Windows PowerShell equivalent of [posixImageScript]. ffmpeg runs as a .NET process, which gives its stderr and a
 * timeout without PowerShell's native-command error handling.
 */
export function windowsImageScript(
  marker: string,
  path: string,
  options: { ffmpeg: string | undefined; webp: boolean; seconds?: number },
): string {
  const seconds = options.seconds ?? imageFfmpegSeconds;
  return (
    `$m = ${psQuote(marker)}; $f = ${psQuote(path)}; $ff = ${psQuote(options.ffmpeg ?? "")}; $webp = $${options.webp}\n` +
    `$cap = ${imageInputCap}; $keep = ${imageKeepBytes}; $side = ${imagePreviewSide}; $secs = ${seconds}\n` +
    windowsImageBody
  );
}

const windowsImageBody = script`function Say([string]$Body) { [Console]::Out.Write("\`n" + $m + ":begin\`n{" + $Body + "}\`n" + $m + ":end\`n"); exit 0 }
function J([string]$Text) { ConvertTo-OmpAscii (ConvertTo-Json -InputObject $Text -Compress) }
function Q([string]$Value) { '"' + $Value + '"' }
if (-not (Test-Path -LiteralPath $f)) { Say '"problem":"missing"' }
if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Say '"problem":"notFile"' }
$item = Get-Item -LiteralPath $f -Force
$buf = New-Object byte[] 32
$n = 0
try {
  $fs = [System.IO.File]::Open($item.FullName, 'Open', 'Read', 'ReadWrite, Delete')
  try { $n = $fs.Read($buf, 0, 32) } finally { $fs.Dispose() }
} catch {
  for ($e = $_.Exception; $e; $e = $e.InnerException) { if ($e -is [System.UnauthorizedAccessException]) { Say '"problem":"denied"' } }
  throw
}
$magic = -join ($buf | Select-Object -First $n | ForEach-Object { $_.ToString('x2') })
$size = $item.Length
$mtime = [DateTimeOffset]::new($item.LastWriteTimeUtc).ToUnixTimeSeconds()
$r = '"size":' + $size + ',"mtime":' + $mtime + ',"magic":"' + $magic + '"'
if (-not $ff -or $size -gt $cap) { Say $r }
if ($magic -match '^(89504e47|ffd8ff|47494638|424d|52494646.{8}57454250)' -and $size -le $keep) { Say $r }
$d = [System.IO.Path]::Combine($HOME, '.ompanion', 'tmp')
[void](New-Item -ItemType Directory -Force -Path $d)
$old = [DateTime]::UtcNow.AddMinutes(-10)
Get-ChildItem -LiteralPath $d -Filter 'img-*' -File | Where-Object { $_.LastWriteTimeUtc -lt $old } | Remove-Item -Force
$o = Join-Path $d ('img-' + $m)
function Invoke-Ffmpeg([string]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ff
  $psi.Arguments = '-nostdin -hide_banner -y ' + $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $null = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($secs * 1000)) {
    $p.Kill()
    $p.WaitForExit()
    return @{ TimedOut = $true; Code = -1; Log = '' }
  }
  $p.WaitForExit()
  @{ TimedOut = $false; Code = $p.ExitCode; Log = $err.Result }
}
$run = Invoke-Ffmpeg ('-i ' + (Q ('file:' + $item.FullName)))
$demux = ''
$stream = ''
foreach ($l in ($run.Log -split "\`r?\`n")) {
  if (-not $demux -and $l -match '^Input #0, (.*), from ') { $demux = $Matches[1] }
  if (-not $stream -and $l -match 'Stream #0:\d+.*: Video: ') { $stream = $l.Trim() }
}
$r = $r + ',"demux":' + (J $demux) + ',"stream":' + (J $stream)
if ($run.TimedOut) { Say ($r + ',"ffmpeg":"timeout"') }
if ($demux -notmatch '^(image2|.*_pipe|gif|apng|webp)$') { Say ($r + ',"ffmpeg":"notImage"') }
$pix = ''
if ($stream -match 'Video: [^,]*, ([0-9a-z_]+)') { $pix = $Matches[1] }
$x = 'jpeg'
if ($webp) { $x = 'webp' }
elseif ($pix -match '^(.*rgba.*|.*bgra.*|argb|abgr|yuva.*|ya8|ya16.*|gbrap.*|pal8|ayuv.*|vuya)$') {
  $alpha = Invoke-Ffmpeg ('-i ' + (Q ('file:' + $item.FullName)) + ' -map 0:v:0 -frames:v 1 -vf "format=rgba,alphaextract,signalstats,metadata=print:key=lavfi.signalstats.YMIN" -f null -')
  if ($alpha.Log -notmatch 'YMIN=255\b') { $x = 'png' }
}
$codec = @{ webp = '-c:v libwebp -quality 80'; png = '-c:v png'; jpeg = '-c:v mjpeg -pix_fmt yuvj420p -q:v 4' }[$x]
$target = $o + '.' + $x
$vf = "scale=w='min($side,iw)':h='min($side,ih)':force_original_aspect_ratio=decrease,setsar=1"
$run = Invoke-Ffmpeg ('-i ' + (Q ('file:' + $item.FullName)) + ' -map 0:v:0 -frames:v 1 -vf ' + (Q $vf) + ' -map_metadata -1 ' + $codec + ' -f image2pipe ' + (Q ('file:' + $target)))
$made = Test-Path -LiteralPath $target -PathType Leaf
if ($run.TimedOut) {
  if ($made) { Remove-Item -LiteralPath $target -Force }
  Say ($r + ',"ffmpeg":"timeout"')
}
if ($run.Code -ne 0 -or -not $made -or (Get-Item -LiteralPath $target).Length -eq 0) {
  if ($made) { Remove-Item -LiteralPath $target -Force }
  $tail = (($run.Log -split "\`r?\`n") | Where-Object { $_ } | Select-Object -Last 3) -join ' '
  Say ($r + ',"ffmpeg":"failed","error":' + (J $tail))
}
Say ($r + ',"ffmpeg":"ok","out":' + (J $target) + ',"format":"' + $x + '","outSize":' + (Get-Item -LiteralPath $target).Length)
`;
