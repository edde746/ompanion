// Port of packages/omp_core/lib/src/channel/detached_channel.dart.
import { newMarker, posixLockFunctions, posixTailPoll, shQuote, startPosixScript, toSftpPath } from "../host/scripts";
import { HostLinkException, type HostLink } from "../transport/host_link";
import { ignore } from "../util/async";
import { script } from "../util/script";
import type { EventStream } from "../util/stream";
import { parseIntStrict } from "../util/text";
import { Follower, LogFollower, type AttachTools } from "./follow";
import { attachWindow } from "./log_script";
import { RunAppender, RunInbox, type InboxLine, type RunChannel } from "./run_log";

/**
 * Lines up to this size are appended through the appender's stdin. `sh`'s `read` takes one byte per system call from
 * a pipe (64 KiB: 15 ms under dash, 33 ms under macOS bash), so longer lines are uploaded over SFTP first and appended
 * with `cat`.
 */
export const inlineAppendLimit = 64 * 1024;

const encoder = new TextEncoder();

/** [line] and its newline as bytes. */
export function framedLine(line: string): Uint8Array {
  const bytes = encoder.encode(line);
  const framed = new Uint8Array(bytes.length + 1);
  framed.set(bytes);
  framed[bytes.length] = 0x0a;
  return framed;
}

/**
 * A [RunChannel] to a run on a POSIX machine, over exec channels: [followScript] for [lines] (with `tail -F`),
 * `tail -F in.jsonl` for [inbox] (started on listen), and a long-running appender that adds each sent line to
 * `in.jsonl` under the `in.lock` `mkdir` lock (started with the attach). Each script ends when its stdin closes, so
 * nothing outlives the channel on the machine, even when the connection drops.
 */
export class DetachedChannel implements RunChannel {
  private closed = false;
  private log!: LogFollower;
  private inboxFollow: Follower | undefined;
  private readonly inboxReader = new RunInbox({ onListen: () => void this.startInbox() });
  private appender: Promise<RunAppender> | undefined;
  private writes: Promise<void> = Promise.resolve();

  /** [dir]: host path of the run directory. */
  private constructor(
    private readonly link: HostLink,
    readonly dir: string,
    private readonly inboxFrom: number | undefined,
  ) {}

  /**
   * Attaches to the run in [dir] (host path). See `attachRun` for [generation], [offset], [inboxOffset] and [tools];
   * [window] is [attachWindow].
   */
  static async attach(
    link: HostLink,
    dir: string,
    options: { tools: AttachTools; generation?: number; offset?: number; inboxOffset?: number; window?: number },
  ): Promise<DetachedChannel> {
    const channel = new DetachedChannel(link, dir, options.inboxOffset);
    // Started alongside the log follower: the client's first send (`negotiate_protocol`, right after `ready` or the
    // attach) waited up to 190 ms for this exec channel and its script over SSH to an M3 MacBook Air. A failed start
    // reaches the sends waiting for it; the next send starts another.
    const appender = channel.startAppender();
    ignore(appender);
    channel.appender = appender;
    try {
      channel.log = await LogFollower.start(link, "posix", "tail", dir, options.tools, {
        generation: options.generation,
        offset: options.offset ?? 0,
        window: options.window ?? attachWindow,
      });
    } catch (error) {
      await channel.endAppender();
      throw error;
    }
    return channel;
  }

  get offset(): number {
    return this.log.output.offset;
  }

  get generation(): number {
    return this.log.output.generation;
  }

  get exitCode(): number | undefined {
    return this.log.output.exitCode;
  }

  get lines(): EventStream<string> {
    return this.log.output.lines;
  }

  get inbox(): EventStream<InboxLine> {
    return this.inboxReader.stream;
  }

  get inboxOffset(): number {
    return this.inboxReader.offset;
  }

  private async startInbox(): Promise<void> {
    const follow = new Follower({
      onHeader: (header) => this.inboxReader.start(parseIntStrict(header)),
      onData: (chunk) => this.inboxReader.add(chunk),
      onEnd: (error) => {
        if (!this.closed) {
          this.inboxReader.fail(new HostLinkException(`following ${this.dir}/in.jsonl ended: ${follow.stderr}`, error));
        }
      },
    });
    this.inboxFollow = follow;
    try {
      await follow.start(startPosixScript(this.link, inboxScript(this.dir, this.inboxFrom)));
    } catch (error) {
      if (!this.closed) this.inboxReader.fail(error);
    }
  }

  async send(line: string): Promise<void> {
    if (line.includes("\n")) throw new RangeError("Invalid argument (line): contains a newline");
    if (this.closed) throw new Error(`channel to ${this.dir} is closed`);
    this.inboxReader.sending();
    const handed = this.writes.then(() => this.write(line));
    // The chain only keeps the writes in order; each send gets its own error below.
    this.writes = handed.then(
      () => undefined,
      () => undefined,
    );
    try {
      this.inboxReader.sent(await (await handed).ack);
    } catch (error) {
      this.inboxReader.sent(undefined);
      throw error;
    }
  }

  /**
   * Hands [line] to the appender; [ack] is its acknowledgement. Writes are chained, so lines reach `in.jsonl` in
   * [send] order even when one of them is uploaded first.
   */
  private async write(line: string): Promise<{ ack: Promise<number> }> {
    const appender = await this.liveAppender();
    const framed = framedLine(line);
    // The appender reads a leading `@` as the name of an uploaded file.
    if (framed.length - 1 <= inlineAppendLimit && !line.startsWith("@")) return { ack: appender.append(framed) };
    const name = `up-${newMarker()}.part`;
    const files = await this.link.files();
    try {
      await files.write(toSftpPath(`${this.dir}/${name}`), framed, { mode: 0o600 });
    } finally {
      await files.close();
    }
    // The appender may have ended during the upload.
    return { ack: (await this.liveAppender()).append(encoder.encode(`@${name}\n`)) };
  }

  /** The appender, started with the attach and again after one ended or failed to start. */
  private async liveAppender(): Promise<RunAppender> {
    const appender = await (this.appender ??= this.startAppender());
    // It ended since it was cached, which emptied the slot.
    return appender.ended ? await (this.appender ??= this.startAppender()) : appender;
  }

  private async startAppender(): Promise<RunAppender> {
    try {
      const process = await startPosixScript(this.link, appenderScript(this.dir));
      return new RunAppender(process, this.dir, () => {
        this.appender = undefined;
      });
    } catch (error) {
      // Not kept: the next send starts another.
      this.appender = undefined;
      throw error;
    }
  }

  /**
   * Ends the appender, once it started. A start that failed has no script to end; the sends that waited for it failed
   * with its error.
   */
  private async endAppender(): Promise<void> {
    const starting = this.appender;
    if (starting === undefined) return;
    let appender: RunAppender;
    try {
      appender = await starting;
    } catch {
      return;
    }
    await appender.finish();
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.writes;
    await this.endAppender();
    await Promise.all([this.log.stop(), this.inboxFollow?.stop()]);
    this.inboxReader.close();
  }
}

/** Header: the start offset: [from] when it is within the file, otherwise the file's current end. */
function inboxScript(dir: string, from: number | undefined): string {
  return `d=${shQuote(dir)}; o0=${from ?? -1}\n${posixTailPoll}${inboxBody}`;
}

const inboxBody = script`s=$(wc -c < "$d/in.jsonl" | tr -d ' ')
if [ -z "$s" ]; then echo "no run in $d" >&2; exit 3; fi
o=$s
if [ "$o0" -ge 0 ] && [ "$o0" -le "$s" ]; then o=$o0; fi
printf '%s\n' "$o"
tail $tailpoll -c +$((o + 1)) -F "$d/in.jsonl" &
t=$!
cat > /dev/null
kill "$t" 2>/dev/null
`;

/**
 * Acknowledges each line with `<status> <in.jsonl size>`, the size measured under the lock, so it is exactly the end
 * offset of that line.
 */
function appenderScript(dir: string): string {
  return `d=${shQuote(dir)}\n${posixLockFunctions}${appenderBody}`;
}

const appenderBody = script`while IFS= read -r l; do
  lock "$d/in.lock" 30 || exit 1
  case $l in
    @*) f="$d/\${l#@}"; cat "$f" >> "$d/in.jsonl"; r=$?; rm -f "$f" ;;
    *) printf '%s\n' "$l" >> "$d/in.jsonl"; r=$? ;;
  esac
  s=$(wc -c < "$d/in.jsonl" | tr -d ' ')
  unlock "$d/in.lock"
  printf '%s %s\n' "$r" "$s"
done
`;
