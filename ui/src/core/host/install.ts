// Port of packages/omp_core/lib/src/host/install.dart.
import { type BridgeLink, type CachedFile, netFetch, removeCached } from "../transport/bridge_link";
import { HostLinkException, type HostLink } from "../transport/host_link";
import { script } from "../util/script";
import { hostProbeIsWindows, hostProbeLoginPathExport, hostProbeReleaseAsset, type HostProbe } from "./probe";
import {
  acquireDirLock,
  ensureAppDir,
  newMarker,
  psQuote,
  runPosixScript,
  runPowerShell,
  scriptResultFailure,
  scriptResultPayload,
  shQuote,
  toSftpPath,
} from "./scripts";

/** One omp release: SHA-256 digests of its assets, copied from the release's `SHA256SUMS.txt`. */
export interface OmpRelease {
  readonly version: string;
  /** Asset name → lowercase hex SHA-256. */
  readonly assets: Readonly<Record<string, string>>;
}

export function ompReleaseAssetUrl(release: OmpRelease, asset: string): string {
  return `https://github.com/can1357/oh-my-pi/releases/download/v${release.version}/${asset}`;
}

/** Every omp release the app supports, oldest first. */
export const ompReleases: readonly OmpRelease[] = [
  {
    version: "18.3.1",
    assets: {
      "omp-darwin-arm64": "67b807a99454a4d8e1cf982dce7b3343b2c2fc148f33e403dbfb3f1049b22570",
      "omp-darwin-x64": "f7ee52cc4d97c0c3af4b271dff940e2be31fe1e22d4fd125eda6e0c1bb97d5b0",
      "omp-linux-arm64": "95b9e3dc3c2096885be2c9c923bd45bb3bf81d172367db7e7090936729261e2c",
      "omp-linux-musl-arm64": "f9fae7ccd077a0c386af6b979931c2875afcf79e53e230d3cbd1e19cfe6b3a8f",
      "omp-linux-musl-x64": "32a053aaabd3f0e24c513c52714594285cccc1c83057ebc7585c7b358a566db4",
      "omp-linux-x64": "0806df602bf2bb9b202d152204b1bef6450eb6bcbfbf31d66e3767d1bbb3b3a7",
      "omp-windows-arm64.exe": "401cab4f1f21ecff0952123103715976c0bdb115d676e74496a68bf012214537",
      "omp-windows-x64.exe": "66d1f0b193749782f119a776a2b02b0b71909c36ee12e8f1d310a3c53e66da26",
    },
  },
  {
    version: "18.4.12",
    assets: {
      "omp-darwin-arm64": "1a81bd323ba6d67374adf5645fe52e194671416e15c69ef17ac18e32b42c55ff",
      "omp-darwin-x64": "d3305b641d3e62c30f8cd5a44343d219cdc45c3ad9a6c13729df61749ff40ac6",
      "omp-linux-arm64": "7e9c91e9f34765abfd775b8f87c00bb82d5c14025d58770fe4213791452f3182",
      "omp-linux-musl-arm64": "27e9ccf165ec356a706b04a870c5066075a60aafd2dee2e3836da4a313b19d3f",
      "omp-linux-musl-x64": "f3a526cc97f49534d0e1ba349ea98bf05be0cf77930cae9dd205fe838b5a64db",
      "omp-linux-x64": "8178466631d09c2165c19c14c92ee7f4e3e68c5f41953e8815adfb1214a64999",
      "omp-windows-arm64.exe": "b61df7f7849ce83c73c2a18916b8cb43ee9a236d62cddc61d884d8ee0a4659ec",
      "omp-windows-x64.exe": "41f749a49d99fbc7daa8dfd571c20b396f4cfd4b2cd16735624bc416137f67ab",
    },
  },
  {
    version: "18.6.3",
    assets: {
      "omp-darwin-arm64": "ab52491643e21b270682691b1319f1161fe2a2658ae4e9a4e3958b1aeb12dcf4",
      "omp-darwin-x64": "e46cb6bd129870eea80d77e4a5963b2208e3ca1997249d06c0a1add11d835cdd",
      "omp-linux-arm64": "56cb0174c38ebacb0590e14c69eb62c91681b90a995b45b083ec9d38b3fd3fc3",
      "omp-linux-musl-arm64": "1d71c23cda6291065874f5ff5b5010e752ef7c0437bc0122cd97f6242c13e29e",
      "omp-linux-musl-x64": "f76e5cbbd25a566e30b4767fefcba96a5a41654d4cfa934a1ee91811d311b275",
      "omp-linux-x64": "5972347a0afa983333151e1f27461bc441929a22ab5ec65dfed248eb2108ddaf",
      "omp-windows-arm64.exe": "edecce8ab10d46af18f3ca057ece173e0c0c4d404dd1a5747732aa18f6e7f9ad",
      "omp-windows-x64.exe": "453e8ecd17f36e0b7faba2abc761206fe72d16b97fbacbe1281831ad9fa86482",
    },
  },
  {
    version: "18.10.3",
    assets: {
      "omp-darwin-arm64": "985c70cbcd264f6c6313de45ee81df6734664ec8ed8e72fa39fc644df625f0ce",
      "omp-darwin-x64": "f19f9a7b4c715456f778ab3ae28fbc38978c6bae6296a832506bc7225f343942",
      "omp-linux-arm64": "7f580e1fe06ebffe16ae46cc6881051aca4980db7f654702feefed5651555862",
      "omp-linux-musl-arm64": "37b545c2e5164a55d17a15c451d3a26f97053000a08e44f7830c105812e855c6",
      "omp-linux-musl-x64": "9dcaa7aebfef367c5022781a79b831bb769946694b3a5de6099fd7af13e008ad",
      "omp-linux-x64": "366ffcda80db57b825921b6ff4b0e5e623bc62cf18478f2828cd8a322fc72ff9",
      "omp-windows-arm64.exe": "78ec4e8bc5a05b466b9a2c8d42d595cefe2d40b584ef1293c3aa95c84ba4df7c",
      "omp-windows-x64.exe": "c7969e65ab75aa9ae6f93f0fa8307c9fe8dc4cd2ad5ccd5bfa282ed8c840a7d5",
    },
  },
  {
    version: "18.12.6",
    assets: {
      "omp-darwin-arm64": "cfbb5e38cd8f8a3be55e710700be587d287deaacdc58c9b0a661c5086bccfe58",
      "omp-darwin-x64": "62d6e6fd88b6fa5de2ca82842906f152bf1aa227559b1d0bb386f25f6d606123",
      "omp-linux-arm64": "eee8e586274cef2e725c218b2b28b48ca9965d46dd58f60998cb347eca4ad0cf",
      "omp-linux-musl-arm64": "c389c46518387f6e81774c0c8880a56a7571a71b4d683b2a8b654e7d3e607d6b",
      "omp-linux-musl-x64": "ffdb46f1d1bfbe73457446bb44dfb01418e2763293a42407e8eab6d32a3f9dd3",
      "omp-linux-x64": "85d9daf3a05fc76e8cd425ae1904eb576af8d21cc85fcf4690742626e07ccfa4",
      "omp-windows-arm64.exe": "f1c2291275c66de8dba0af248df7075a8adcfdecbafee35afc873e8a5ac63b01",
      "omp-windows-x64.exe": "73d73c11dc8821cf939441a964992aefc9c5b0d5a4418e9e8985a46439b60eef",
    },
  },
  {
    version: "18.16.0",
    assets: {
      "omp-darwin-arm64": "d4a10d97488d6054d2b18198bd24f461079952c7e0fb75ba66336ca0df0cb99e",
      "omp-darwin-x64": "abd62d315b66314f0f635d537407037e7b0d06782513d8035669db5ef744242d",
      "omp-linux-arm64": "c2be1ea85ce17c4270854b57efff2a7ea1d5a03c7557fd08721f2b9bb32698de",
      "omp-linux-musl-arm64": "5e47342bf25fe18e88660b8fe3a692173ac8941e1c769ba19e154a2ca67de405",
      "omp-linux-musl-x64": "5e549f632abd7e22da9551a673b3f3ef7915e9ce9fff92d225236a09b60a3c59",
      "omp-linux-x64": "6498ed785bab00d2926e0387e0ec02362d6d45f1c3d0d1b57c1618b7f95c9264",
      "omp-windows-arm64.exe": "3de50c05b84851089c962aaff4d39d1622bfa079334a5a295bf70028cfdcbc6d",
      "omp-windows-x64.exe": "c249a9ed0a57c748fb1247d8ee9e2d0fe1b13229266ce74d8810a76a591e21fc",
    },
  },
];

export function ompRelease(version: string): OmpRelease | undefined {
  return ompReleases.find((release) => release.version === version);
}

/**
 * Where omp's installers put the binary: `$HOME/.local/bin` (install.sh), `%LOCALAPPDATA%\omp` (install.ps1).
 * Host-native.
 */
export function defaultInstallDir(probe: HostProbe): string {
  if (!hostProbeIsWindows(probe)) return `${probe.home}/.local/bin`;
  const local = probe.localAppData;
  if (local === undefined) throw new HostLinkException(`LOCALAPPDATA is not set on ${probe.home}`);
  return `${local}\\omp`;
}

/**
 * How omp gets onto a machine. `download`: the machine downloads the pinned release asset itself
 * ([posixInstallCommand], [windowsInstallCommand]). `upload`: the core downloads the release asset and uploads it over
 * SFTP ([fetchOmpAsset], [uploadOmp]).
 */
export type InstallRoute = "download" | "upload";

/**
 * Windows always has `Invoke-WebRequest`; a POSIX machine needs curl or wget, which stock Debian and Ubuntu images
 * lack.
 */
export function installRoute(probe: HostProbe): InstallRoute {
  return hostProbeIsWindows(probe) || probe.curl || probe.wget ? "download" : "upload";
}

/**
 * The `sh` script that installs [version] on a POSIX host, shown in manual mode and run by automatic installs: curl or
 * wget downloads the pinned release asset next to the target, then it is checked and moved into place as [uploadOmp]
 * does. It runs in a subshell, so a failure in a pasted copy ends the script, not the terminal. [assetBase] replaces
 * the GitHub release URL in tests.
 */
export function posixInstallCommand(
  probe: HostProbe,
  version: string,
  options: { installDir?: string; assetBase?: string } = {},
): string {
  const release = releaseFor(version);
  const [asset, digest] = pinnedAsset(probe, release);
  const url =
    options.assetBase === undefined ? ompReleaseAssetUrl(release, asset) : new URL(asset, options.assetBase).href;
  return `(
d=${shQuote(options.installDir ?? defaultInstallDir(probe))}; f="$d/.omp-download-$$"; t="$d/omp"
url=${shQuote(url)}
want=${shQuote(digest)}; v=${shQuote(version)}
${posixFail}${posixDownloadBody}${posixPlaceBody})
`;
}

/**
 * The PowerShell script that installs [version] on a Windows host, shown in manual mode and run by automatic installs:
 * `Invoke-WebRequest` downloads the pinned release asset next to the target, then it is checked and moved into place
 * as [uploadOmp] does. It runs in a script block, so its preferences do not leak into a terminal it is pasted into.
 * [assetBase] replaces the GitHub release URL in tests.
 */
export function windowsInstallCommand(
  probe: HostProbe,
  version: string,
  options: { installDir?: string; assetBase?: string } = {},
): string {
  const release = releaseFor(version);
  const [asset, digest] = pinnedAsset(probe, release);
  const url =
    options.assetBase === undefined ? ompReleaseAssetUrl(release, asset) : new URL(asset, options.assetBase).href;
  return `& {
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$d = ${psQuote(options.installDir ?? defaultInstallDir(probe))}; $m = "$PID"; $f = Join-Path $d ".omp-download-$m.exe"; $t = Join-Path $d 'omp.exe'
$url = ${psQuote(url)}
$want = ${psQuote(digest)}; $v = ${psQuote(version)}
${windowsDownloadBody}${windowsPlaceBody}}
`;
}

/**
 * Markers of this app's installs whose link dropped before they released `install.lock`. Each such lock still holds a
 * file named by its marker, so a later install from this app takes it over at once instead of waiting until it is
 * stale.
 */
const abandonedInstalls = new Set<string>();

/**
 * Has the core download the release asset of omp [version] that runs on [probe] ([hostProbeReleaseAsset]) into its
 * cache, at most 1 GiB: from GitHub's release, or from [assetBase] (`<assetBase><asset>`, for tests). [uploadOmp]
 * installs it.
 */
export async function fetchOmpAsset(
  probe: HostProbe,
  version: string,
  options: { assetBase?: string } = {},
): Promise<CachedFile> {
  const release = releaseFor(version);
  const [asset] = pinnedAsset(probe, release);
  const url = options.assetBase === undefined ? ompReleaseAssetUrl(release, asset) : `${options.assetBase}${asset}`;
  return netFetch(url, { maxBytes: 1 << 30 });
}

/**
 * Installs omp [version] from the release asset the core downloaded ([asset], from [fetchOmpAsset]) and then removes
 * it from the core's cache. The asset's SHA-256 must be the one [ompReleases] pins. Under a `mkdir` lock at
 * `~/.ompanion/install.lock` the core uploads it next to the target (the bytes never pass through the page), and the
 * host checks its SHA-256 again, marks it executable, runs `--version`, and moves it over the target, so running omp
 * processes keep their old binary. A failed upload removes its partial file, and one left behind by an install that
 * lost its link is removed by the next. Returns the installed binary's host-native path.
 */
export async function uploadOmp(
  link: BridgeLink,
  probe: HostProbe,
  version: string,
  options: { asset: CachedFile; installDir?: string; lockTimeoutMs?: number; staleLockMs?: number },
): Promise<string> {
  try {
    return await placeAsset(link, probe, version, options);
  } finally {
    await removeCached(options.asset);
  }
}

async function placeAsset(
  link: BridgeLink,
  probe: HostProbe,
  version: string,
  options: { asset: CachedFile; installDir?: string; lockTimeoutMs?: number; staleLockMs?: number },
): Promise<string> {
  const release = releaseFor(version);
  const [asset, digest] = pinnedAsset(probe, release);
  if (options.asset.sha256 !== digest) {
    throw new HostLinkException(`${asset}: SHA-256 mismatch: expected ${digest}, got ${options.asset.sha256}`);
  }
  const windows = hostProbeIsWindows(probe);
  const dir = options.installDir ?? defaultInstallDir(probe);
  const target = windows ? `${dir}\\omp.exe` : `${dir}/omp`;
  const files = await link.files();
  try {
    const lock = `${await ensureAppDir(files, "")}/install.lock`;
    for (const abandoned of [...abandonedInstalls]) {
      if ((await files.stat(`${lock}/${abandoned}`)) === null) continue;
      await files.remove(`${lock}/${abandoned}`);
      await files.removeDir(lock);
      abandonedInstalls.delete(abandoned);
    }
    await acquireDirLock(files, lock, {
      timeoutMs: options.lockTimeoutMs ?? 2 * 60_000,
      staleMs: options.staleLockMs ?? 60 * 60_000,
    });
    const marker = newMarker();
    const owner = `${lock}/${marker}`;
    try {
      await files.write(owner, new Uint8Array(0));
      const upload = windows ? `${dir}\\.omp-upload-${marker}.exe` : `${dir}/.omp-upload-${marker}`;
      const prepare = windows
        ? await runPowerShell(
            link,
            probe.commandShell,
            `New-Item -ItemType Directory -Force -Path ${psQuote(dir)} | Out-Null`,
          )
        : await runPosixScript(link, `mkdir -p ${shQuote(dir)}`);
      if (prepare.exit.code !== 0) throw scriptResultFailure(prepare, `cannot create ${dir}`);
      const remoteDir = toSftpPath(dir);
      for (const entry of await files.list(remoteDir)) {
        // Uploads of installs that died; none runs while this one holds the lock.
        if (entry.name.startsWith(".omp-upload-")) await files.remove(`${remoteDir}/${entry.name}`);
      }
      const remote = toSftpPath(upload);
      try {
        await link.upload(options.asset, remote, { mode: 0o700 });
      } catch (error) {
        try {
          if ((await files.stat(remote)) !== null) await files.remove(remote);
        } catch {
          // The link is gone as well; the next install removes the partial upload. The upload's own error is the one
          // thrown below.
        }
        throw error;
      }
      const result = windows
        ? await runPowerShell(link, probe.commandShell, windowsPlaceScript(marker, upload, target, digest, version))
        : await runPosixScript(link, posixPlaceScript(marker, upload, target, digest, version));
      if (result.exit.code !== 0) throw scriptResultFailure(result, `installing omp ${version} failed`);
      return scriptResultPayload(result, marker);
    } finally {
      try {
        if ((await files.stat(owner)) !== null) await files.remove(owner);
        await files.removeDir(lock);
      } catch (error) {
        abandonedInstalls.add(marker);
        throw error;
      }
    }
  } finally {
    await files.close();
  }
}

/**
 * Runs omp's own updater, `omp update`, with the omp the app drives ([HostProbe.ompPath]). The updater installs the
 * newest release the way the `omp` its PATH resolves to was installed (the installers' binary, Homebrew, mise, bun or
 * npm) and checks the download against GitHub's release digest. So that binary's directory goes in front of PATH,
 * ahead of the login shell's ([hostProbeLoginPathExport]), which stays for the tools the updater runs itself (`brew`,
 * `mise`, `bun`, `npm`, and `gh` for a GitHub token). A binary install's old file is renamed aside, so running omp
 * processes keep it. Returns what omp printed; throws [HostLinkException] with omp's reason when it fails.
 */
export async function updateOmp(link: HostLink, probe: HostProbe): Promise<string> {
  const omp = probe.ompPath;
  if (omp === undefined) throw new HostLinkException(`omp is not installed on ${link.label}`);
  const result = hostProbeIsWindows(probe)
    ? await runPowerShell(
        link,
        probe.commandShell,
        `$o = ${psQuote(omp)}\n` +
          "$env:PATH = (Split-Path -Parent $o) + ';' + $env:PATH\n" +
          "& $o update\n" +
          "exit $LASTEXITCODE\n",
      )
    : await runPosixScript(
        link,
        `${hostProbeLoginPathExport(probe)}\n` +
          `o=${shQuote(omp)}; d=\${o%/*}\n` +
          'PATH="${d:-/}:$PATH"; export PATH\n' +
          'exec "$o" update\n',
      );
  if (result.exit.code !== 0) throw scriptResultFailure(result, "omp update failed");
  return result.stdout;
}

function posixPlaceScript(marker: string, upload: string, target: string, digest: string, version: string): string {
  return `m=${shQuote(marker)}; f=${shQuote(upload)}; t=${shQuote(target)}; want=${shQuote(digest)}; v=${shQuote(version)}
${posixFail}${posixPlaceBody}${posixReport}`;
}

/** The installed path between marker lines: the reply [uploadOmp] reads. */
const posixReport = script`printf '%s:begin\n%s\n%s:end\n' "$m" "$t" "$m"
`;

const posixFail = script`fail() { echo "$1" >&2; rm -f "$f"; exit 1; }
`;

const posixDownloadBody = script`mkdir -p "$d" || fail "cannot create $d"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$f" "$url" || fail "downloading $url failed"
elif command -v wget >/dev/null 2>&1; then
  wget -q -T 30 -O "$f" "$url" || fail "downloading $url failed"
else
  fail 'no curl or wget on this machine'
fi
`;

/** Checks the new binary `$f` against `$want`, runs it, and moves it to `$t`. */
const posixPlaceBody = script`if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$f")
elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$f")
elif command -v openssl >/dev/null 2>&1; then got=$(openssl dgst -sha256 -r "$f")
else fail 'no sha256sum, shasum or openssl on this machine'; fi
got=\${got%% *}
[ "$got" = "$want" ] || fail "SHA-256 mismatch: expected $want, got $got"
chmod 755 "$f" || fail "chmod failed"
out=$("$f" --version </dev/null 2>&1) || fail "the new binary does not start: $out"
case $out in *"$v"*) ;; *) fail "the new binary reports $out, expected $v" ;; esac
mv -f "$f" "$t" || fail "cannot move the binary to $t"
`;

function windowsPlaceScript(marker: string, upload: string, target: string, digest: string, version: string): string {
  return `$m = ${psQuote(marker)}; $f = ${psQuote(upload)}; $t = ${psQuote(target)}; $want = ${psQuote(digest)}; $v = ${psQuote(version)}
${windowsPlaceBody}${windowsReport}`;
}

const windowsReport = script`[Console]::Out.Write($m + ":begin\`n" + (ConvertTo-OmpAscii $t) + "\`n" + $m + ":end\`n")
`;

const windowsDownloadBody = script`New-Item -ItemType Directory -Force -Path $d | Out-Null
try {
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -Uri $url -OutFile $f
} catch {
  Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  throw
}
`;

/**
 * Checks the new binary `$f` against `$want`, runs it, and moves it to `$t`. A running omp.exe cannot be overwritten
 * but can be renamed, so an existing target is moved aside first (omp's own `omp update` does the same).
 */
const windowsPlaceBody = script`try {
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
`;

function releaseFor(version: string): OmpRelease {
  const release = ompRelease(version);
  if (release === undefined) throw new RangeError(`no digests for omp ${version}`);
  return release;
}

/** The release asset that runs on [probe] and its digest. */
function pinnedAsset(probe: HostProbe, release: OmpRelease): [string, string] {
  const asset = hostProbeReleaseAsset(probe);
  const digest = asset === undefined ? undefined : release.assets[asset];
  if (asset === undefined || digest === undefined) {
    throw new HostLinkException(`omp ${release.version} has no build for ${probe.kernel} ${probe.arch}`);
  }
  return [asset, digest];
}
