import 'dart:convert';
import 'dart:typed_data';

import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'probe.dart';
import 'scripts.dart';

/// ffmpeg on a machine, for making image previews there: [ffmpeg] is its host-native path (null without one), and
/// [webp] is true when that build has the libwebp encoder.
final class ImageTools {
  const ImageTools({this.ffmpeg, this.webp = false});

  final String? ffmpeg;
  final bool webp;
}

/// Where ffmpeg is looked for when it is not on PATH. The non-login shell of an SSH exec on macOS has no Homebrew
/// directory on PATH, which is also why the probe searches them for omp.
const ffmpegLocations = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'];

/// Finds ffmpeg on the machine: on PATH, else in [locations] (POSIX only), and whether it encodes WebP.
Future<ImageTools> probeImageTools(HostLink link, HostProbe probe, {List<String> locations = ffmpegLocations}) async {
  final marker = newMarker();
  final result = probe.isWindows
      ? await runPowerShell(link, probe.commandShell, windowsImageToolsScript(marker))
      : await runPosixScript(link, posixImageToolsScript(marker, locations));
  return parseImageTools(result.payload(marker));
}

String posixImageToolsScript(String marker, List<String> locations) =>
    'm=${shQuote(marker)}\nset --${locations.map((l) => ' ${shQuote(l)}').join()}\n$_posixToolsBody';

const _posixToolsBody = r'''
LC_ALL=C; export LC_ALL
q() { v=$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '"%s"' "$v"; }
f=$(command -v ffmpeg 2>/dev/null); case $f in /*) ;; *) f= ;; esac
if [ -z "$f" ]; then for x in "$@"; do if [ -f "$x" ] && [ -x "$x" ]; then f=$x; break; fi; done; fi
w=; if [ -n "$f" ] && "$f" -nostdin -hide_banner -encoders </dev/null 2>/dev/null | grep -q ' libwebp '; then w=1; fi
printf '\n%s:begin\n{"ffmpeg":' "$m"; q "$f"; printf ',"webp":"%s"}\n%s:end\n' "$w" "$m"
''';

String windowsImageToolsScript(String marker) => '\$m = ${psQuote(marker)}\n$_windowsToolsBody';

const _windowsToolsBody = r'''
$f = $null
$c = Get-Command -Name 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) { $f = $c.Source }
$w = $null
if ($f) {
  try { if (& $f -nostdin -hide_banner -encoders 2>$null | Select-String -SimpleMatch ' libwebp ') { $w = '1' } } catch { $w = $null }
}
$json = ConvertTo-OmpAscii (ConvertTo-Json -InputObject ([ordered]@{ ffmpeg = $f; webp = $w }) -Compress)
[Console]::Out.Write("`n" + $m + ":begin`n" + $json + "`n" + $m + ":end`n")
''';

/// Parses the payload of [posixImageToolsScript] and [windowsImageToolsScript].
ImageTools parseImageTools(String payload) {
  final json = asJsonObject(jsonDecode(payload), 'image tools');
  final ffmpeg = json.optString('ffmpeg');
  return ImageTools(ffmpeg: ffmpeg == null || ffmpeg.isEmpty ? null : ffmpeg, webp: json.optString('webp') == '1');
}

/// The largest file the image operation reads or hands to ffmpeg.
const imageInputCap = 64 << 20;

/// The largest original sent without a preview.
const imageOriginalCap = 8 << 20;

/// Decodable images up to this size are sent as they are, even where ffmpeg could make a preview.
const imageKeepBytes = 256 << 10;

/// The long side of a preview, at most; smaller images keep their size.
const imagePreviewSide = 1600;

/// The wall-clock limit of each ffmpeg run on the machine, in seconds.
const imageFfmpegSeconds = 20;

/// Why a machine image cannot be shown.
enum HostImageIssue {
  missing,
  notFile,
  denied,
  notImage,

  /// An image format this app cannot decode, and no preview could be made.
  unsupported,

  /// Over [imageOriginalCap] without a preview, or over [imageInputCap].
  tooLarge,
}

/// An image read from a machine, or why it could not be.
sealed class HostImage {
  const HostImage();
}

final class HostImageBytes extends HostImage {
  const HostImageBytes({
    required this.bytes,
    required this.mimeType,
    required this.size,
    required this.modified,
    required this.preview,
    this.width,
    this.height,
  });

  final Uint8List bytes;
  final String mimeType;

  /// The file's size on the machine, which [bytes] is shorter than for a [preview].
  final int size;
  final DateTime modified;

  /// A downscaled copy ffmpeg made on the machine, not the file itself.
  final bool preview;

  /// The file's pixel size when ffmpeg reported it.
  final int? width;
  final int? height;
}

final class HostImageProblem extends HostImage {
  const HostImageProblem(this.issue, {this.size, this.modified, this.detail});

  final HostImageIssue issue;

  /// The file's size and modification time, when it is a readable file.
  final int? size;
  final DateTime? modified;

  /// ffmpeg's last words when it failed.
  final String? detail;

  /// A file too large to send on its own that the user may still fetch: [fetchHostImage] with `original: true`.
  bool get canLoadOriginal => issue == HostImageIssue.tooLarge && size != null && size! <= imageInputCap;
}

/// Reads the image file [path] (host-native, absolute) of the machine. Without [original], and when [tools] has
/// ffmpeg, a file larger than [imageKeepBytes] or one this app cannot decode becomes a preview on the machine: the
/// first frame, its long side at most [imagePreviewSide], WebP where ffmpeg encodes it, else PNG for images with
/// transparent pixels and JPEG for the rest (an alpha channel that leaves every pixel opaque, as in most
/// screenshots, does not count). The preview is written to `~/.ompanion/tmp`, read over [files] and deleted. With
/// [original] the file itself is read, up to [imageInputCap].
Future<HostImage> fetchHostImage(
  HostLink link,
  HostFiles files,
  HostProbe probe,
  ImageTools tools,
  String path, {
  bool original = false,
}) async {
  final marker = newMarker();
  final ffmpeg = original ? null : tools.ffmpeg;
  final result = probe.isWindows
      ? await runPowerShell(
          link,
          probe.commandShell,
          windowsImageScript(marker, path, ffmpeg: ffmpeg, webp: tools.webp),
        )
      : await runPosixScript(link, posixImageScript(marker, path, ffmpeg: ffmpeg, webp: tools.webp));
  final report = parseImageReport(result.payload(marker));
  final out = report.out;
  try {
    switch (planImage(report, path, original: original)) {
      case ImageRefused(:final problem):
        return problem;
      case ImageRead(:final path, :final mimeType, :final preview):
        final size = parseVideoSize(report.stream);
        return HostImageBytes(
          bytes: await files.read(toSftpPath(path)),
          mimeType: mimeType,
          size: report.size,
          modified: report.modified!,
          preview: preview,
          width: size?.width,
          height: size?.height,
        );
    }
  } finally {
    if (out != null) await files.remove(toSftpPath(out));
  }
}

/// What ffmpeg did with the file in the image script.
enum FfmpegOutcome { ok, notImage, failed, timeout }

/// The facts the image script printed about one file.
final class HostImageReport {
  const HostImageReport({
    this.problem,
    this.size = 0,
    this.modified,
    this.magic = '',
    this.ffmpeg,
    this.stream,
    this.out,
    this.format,
    this.outSize,
    this.error,
  });

  /// [HostImageIssue.missing], [HostImageIssue.notFile] or [HostImageIssue.denied] found by the script.
  final HostImageIssue? problem;
  final int size;
  final DateTime? modified;

  /// The file's first 32 bytes as lowercase hex.
  final String magic;

  /// Null when ffmpeg did not run.
  final FfmpegOutcome? ffmpeg;

  /// ffmpeg's line for the first video stream, e.g. `Stream #0:0: Video: png, rgba(pc), 3000x2000, …`.
  final String? stream;

  /// The preview (host-native path), its encoding (`webp`, `png`, `jpeg`) and size.
  final String? out;
  final String? format;
  final int? outSize;
  final String? error;
}

/// Parses the payload of [posixImageScript] and [windowsImageScript].
HostImageReport parseImageReport(String payload) {
  final json = asJsonObject(jsonDecode(payload), 'image report');
  final problem = json.optString('problem');
  if (problem != null) return HostImageReport(problem: enumByName(HostImageIssue.values, problem));
  final ffmpeg = json.optString('ffmpeg');
  return HostImageReport(
    size: json.integer('size'),
    modified: DateTime.fromMillisecondsSinceEpoch(json.integer('mtime') * 1000, isUtc: true),
    magic: json.optString('magic') ?? '',
    ffmpeg: ffmpeg == null ? null : enumByName(FfmpegOutcome.values, ffmpeg),
    stream: _nonEmpty(json.optString('stream')),
    out: _nonEmpty(json.optString('out')),
    format: json.optString('format'),
    outSize: json.optInt('outSize'),
    error: _nonEmpty(json.optString('error')?.trim()),
  );
}

String? _nonEmpty(String? value) => value == null || value.isEmpty ? null : value;

/// The width and height in an ffmpeg stream line (`…, 3000x2000 [SAR 1:1 DAR 3:2], …`), or null.
({int width, int height})? parseVideoSize(String? stream) {
  final match = RegExp(r', (\d{1,6})x(\d{1,6})\b').firstMatch(stream ?? '');
  if (match == null) return null;
  return (width: int.parse(match[1]!), height: int.parse(match[2]!));
}

/// The MIME type of an image this app decodes (PNG, JPEG, GIF, WebP, BMP), from its first bytes as hex, or null.
String? decodableImageType(String magic) => switch (magic) {
  _ when magic.startsWith('89504e47') => 'image/png',
  _ when magic.startsWith('ffd8ff') => 'image/jpeg',
  _ when magic.startsWith('47494638') => 'image/gif',
  _ when magic.startsWith('52494646') && magic.length >= 24 && magic.substring(16, 24) == '57454250' => 'image/webp',
  _ when magic.startsWith('424d') => 'image/bmp',
  _ => null,
};

/// Whether [magic] starts an image format this app cannot decode: TIFF, HEIF and AVIF, ICO, PSD, JPEG XL, SVG.
bool isOtherImage(String magic) =>
    magic.startsWith('49492a00') ||
    magic.startsWith('4d4d002a') ||
    (magic.length >= 24 && magic.substring(8, 16) == '66747970' && _isoImageBrands.contains(magic.substring(16, 24))) ||
    magic.startsWith('00000100') ||
    magic.startsWith('38425053') ||
    magic.startsWith('ff0a') ||
    magic.startsWith('0000000c4a584c20') ||
    magic.startsWith('3c737667');

/// `heic`, `heix`, `mif1`, `avif`, `avis` as hex: ISO base media brands of still images.
const _isoImageBrands = {'68656963', '68656978', '6d696631', '61766966', '61766973'};

/// What [fetchHostImage] does with a report.
sealed class ImagePlan {
  const ImagePlan();
}

/// Read the file at [path]: the image itself, or the [preview] ffmpeg made.
final class ImageRead extends ImagePlan {
  const ImageRead(this.path, this.mimeType, {required this.preview});

  final String path;
  final String mimeType;
  final bool preview;
}

final class ImageRefused extends ImagePlan {
  const ImageRefused(this.problem);

  final HostImageProblem problem;
}

/// Decides between the preview, the file [path] itself and a problem for [report]. A preview no smaller than a
/// decodable original that may be sent as it is loses to it.
ImagePlan planImage(HostImageReport report, String path, {required bool original}) {
  if (report.problem case final issue?) return ImageRefused(HostImageProblem(issue));
  final size = report.size, modified = report.modified;
  HostImageProblem problem(HostImageIssue issue, {String? detail}) =>
      HostImageProblem(issue, size: size, modified: modified, detail: detail);
  if (size > imageInputCap) return ImageRefused(problem(HostImageIssue.tooLarge));
  final type = decodableImageType(report.magic);
  final other = isOtherImage(report.magic);
  if (original) {
    if (type != null) return ImageRead(path, type, preview: false);
    return ImageRefused(problem(other ? HostImageIssue.unsupported : HostImageIssue.notImage));
  }
  if (report.ffmpeg == FfmpegOutcome.ok && report.out != null) {
    final keep = type != null && size <= imageOriginalCap && (report.outSize ?? size) >= size;
    if (keep) return ImageRead(path, type, preview: false);
    return ImageRead(report.out!, _previewTypes[report.format] ?? 'image/jpeg', preview: true);
  }
  if (type != null) {
    return size <= imageOriginalCap
        ? ImageRead(path, type, preview: false)
        : ImageRefused(problem(HostImageIssue.tooLarge));
  }
  return ImageRefused(switch (report.ffmpeg) {
    FfmpegOutcome.failed || FfmpegOutcome.timeout => problem(HostImageIssue.unsupported, detail: report.error),
    _ when other => problem(HostImageIssue.unsupported),
    _ => problem(HostImageIssue.notImage),
  });
}

const _previewTypes = {'webp': 'image/webp', 'png': 'image/png', 'jpeg': 'image/jpeg'};

/// The POSIX image script: checks that [path] is a readable regular file, prints its size, mtime and first bytes, and,
/// given [ffmpeg], makes the preview. Each ffmpeg run is killed after [seconds]; a preview left by a run whose link
/// dropped is deleted by a later run after ten minutes.
String posixImageScript(
  String marker,
  String path, {
  required String? ffmpeg,
  required bool webp,
  int seconds = imageFfmpegSeconds,
}) =>
    'm=${shQuote(marker)}; f=${shQuote(path)}; ff=${shQuote(ffmpeg ?? '')}; webp=${webp ? '1' : ''}\n'
    'cap=$imageInputCap; keep=$imageKeepBytes; side=$imagePreviewSide; secs=$seconds\n'
    '$_posixImageBody';

const _posixImageBody = r'''
LC_ALL=C; export LC_ALL
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
''';

/// Windows PowerShell equivalent of [posixImageScript]. ffmpeg runs as a .NET process, which gives its stderr and a
/// timeout without PowerShell's native-command error handling.
String windowsImageScript(
  String marker,
  String path, {
  required String? ffmpeg,
  required bool webp,
  int seconds = imageFfmpegSeconds,
}) =>
    '\$m = ${psQuote(marker)}; \$f = ${psQuote(path)}; \$ff = ${psQuote(ffmpeg ?? '')}; \$webp = \$$webp\n'
    '\$cap = $imageInputCap; \$keep = $imageKeepBytes; \$side = $imagePreviewSide; \$secs = $seconds\n'
    '$_windowsImageBody';

const _windowsImageBody = r'''
function Say([string]$Body) { [Console]::Out.Write("`n" + $m + ":begin`n{" + $Body + "}`n" + $m + ":end`n"); exit 0 }
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
foreach ($l in ($run.Log -split "`r?`n")) {
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
  $tail = (($run.Log -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 3) -join ' '
  Say ($r + ',"ffmpeg":"failed","error":' + (J $tail))
}
Say ($r + ',"ffmpeg":"ok","out":' + (J $target) + ',"format":"' + $x + '","outSize":' + (Get-Item -LiteralPath $target).Length)
''';
