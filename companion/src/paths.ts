import type { Stats } from "node:fs";
import { lstat, readFile, realpath, rm } from "node:fs/promises";
import { homedir } from "node:os";
import * as path from "node:path";
import { isEnoent } from "@oh-my-pi/pi-utils";
import { VerbError } from "./protocol.ts";

/**
 * Files named in calls. Any `/ompx` line typed or pasted into a composer reaches the companion, so a path in a
 * call must pass these rules before anything is read or deleted.
 */

/** The name `ConfigTarget.uploadSecret` gives a secret file: `newMarker()` plus `.secret`. */
const SECRET_FILE_NAME = /^OMPANION_[0-9a-f]{16}\.secret$/;

/**
 * Reads a secret file the app uploaded over SFTP, then deletes it (docs/contracts/ompx.md, "Secret files").
 * Anything else is `bad_request` before it is read or deleted.
 */
export async function takeSecretFile(file: string, home: string = homedir()): Promise<string> {
	if (!path.isAbsolute(file)) throw new VerbError("bad_request", `${file} is not an absolute path`);
	if (!SECRET_FILE_NAME.test(path.basename(file))) {
		throw new VerbError("bad_request", `${file} is not named OMPANION_<16 hex digits>.secret`);
	}
	let stats: Stats;
	try {
		stats = await lstat(file);
	} catch (error) {
		if (isEnoent(error)) throw new VerbError("not_found", `no secret file ${file}`);
		throw error;
	}
	if (!stats.isFile()) throw new VerbError("bad_request", `${file} is not a regular file`);
	const real = await realpath(file);
	// Real paths on both sides: SFTP reports the home directory with symlinks resolved, $HOME may keep them.
	const tmp = path.join(home, ".ompanion", "tmp");
	let realTmp: string;
	try {
		realTmp = await realpath(tmp);
	} catch (error) {
		if (isEnoent(error)) throw new VerbError("bad_request", `${file} is not in ${tmp}, which does not exist`);
		throw error;
	}
	if (path.dirname(real) !== realTmp) throw new VerbError("bad_request", `${file} is not directly in ${tmp}`);
	// Windows reports no permission bits (only the read-only attribute); the profile's ACL guards the directory.
	const mode = stats.mode & 0o777;
	if (process.platform !== "win32" && mode !== 0o600) {
		throw new VerbError("bad_request", `${file} has mode ${mode.toString(8)}, not 600`);
	}
	try {
		return await readFile(real, "utf8");
	} finally {
		await rm(real, { force: true });
	}
}

/**
 * Whether `file` (absolute, normalized) lies where omp keeps sessions: `<sessions root>/<project>/<name>.jsonl`,
 * or directly in `sessionDir`, the open session's directory (`--session-dir` may move it). `sessionDir` is ""
 * when the open session has none; `path.resolve("")` would be the process's cwd.
 */
export function isSessionFilePath(file: string, sessionsRoot: string, sessionDir: string): boolean {
	if (!file.endsWith(".jsonl")) return false;
	const dir = path.dirname(file);
	if (path.dirname(dir) === path.resolve(sessionsRoot)) return true;
	return sessionDir !== "" && dir === path.resolve(sessionDir);
}
