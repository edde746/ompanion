import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { isSessionFilePath, takeSecretFile } from "../src/paths.ts";
import { VerbError } from "../src/protocol.ts";

async function refusal(file: string, home: string): Promise<VerbError> {
	try {
		await takeSecretFile(file, home);
	} catch (error) {
		if (error instanceof VerbError) return error;
		throw error;
	}
	throw new Error(`takeSecretFile accepted ${file}`);
}

describe("takeSecretFile", () => {
	let home: string;
	let tmp: string;

	beforeEach(async () => {
		home = await mkdtemp(path.join(tmpdir(), "ompx-paths-"));
		tmp = path.join(home, ".omp-app", "tmp");
		await mkdir(tmp, { recursive: true, mode: 0o700 });
	});

	afterEach(async () => {
		await rm(home, { recursive: true, force: true });
	});

	async function secret(file: string, content: string, mode = 0o600): Promise<string> {
		await writeFile(file, content);
		await chmod(file, mode);
		return file;
	}

	test("reads and deletes a 0600 OMPAPP_<16 hex>.secret directly in ~/.omp-app/tmp", async () => {
		const file = await secret(path.join(tmp, "OMPAPP_0123456789abcdef.secret"), "sk-1\n");
		expect(await takeSecretFile(file, home)).toBe("sk-1\n");
		expect(await Bun.file(file).exists()).toBe(false);
	});

	test("matches the directory by real path, as SFTP reports the home directory", async () => {
		const alias = `${home}-alias`;
		await symlink(home, alias);
		try {
			const viaAlias = await secret(path.join(alias, ".omp-app", "tmp", "OMPAPP_0123456789abcdef.secret"), "a");
			expect(await takeSecretFile(viaAlias, home)).toBe("a");
			const direct = await secret(path.join(tmp, "OMPAPP_fedcba9876543210.secret"), "b");
			expect(await takeSecretFile(direct, alias)).toBe("b");
		} finally {
			await rm(alias);
		}
	});

	test("refuses anything else without reading or deleting it", async () => {
		const outside = await secret(path.join(home, "OMPAPP_0123456789abcdef.secret"), "thesis");
		await mkdir(path.join(tmp, "sub"));
		const refused = [
			outside,
			`${tmp}/../../OMPAPP_0123456789abcdef.secret`,
			await secret(path.join(tmp, "sub", "OMPAPP_0123456789abcdef.secret"), "nested"),
			await secret(path.join(tmp, "OMPAPP_0123456789abcdef.key"), "wrong suffix"),
			await secret(path.join(tmp, "OMPAPP_0123456789ABCDEF.secret"), "upper case"),
			await secret(path.join(tmp, "OMPAPP_0123456789abcde.secret"), "15 digits"),
			await secret(path.join(tmp, "OMPAPP_1111111111111111.secret"), "group readable", 0o640),
			await secret(path.join(tmp, "OMPAPP_2222222222222222.secret"), "read only", 0o400),
		];
		const link = path.join(tmp, "OMPAPP_3333333333333333.secret");
		await symlink(outside, link);
		const dir = path.join(tmp, "OMPAPP_4444444444444444.secret");
		await mkdir(dir);
		for (const file of [...refused, link, dir, "OMPAPP_5555555555555555.secret"]) {
			const error = await refusal(file, home);
			expect([file, error.code]).toEqual([file, "bad_request"]);
		}
		for (const file of refused) expect(await Bun.file(file).exists()).toBe(true);
		expect(await readFile(outside, "utf8")).toBe("thesis");
		expect((await lstat(link)).isSymbolicLink()).toBe(true);
		expect((await lstat(dir)).isDirectory()).toBe(true);
	});

	test("refuses a file named like a secret when ~/.omp-app/tmp does not exist", async () => {
		await rm(tmp, { recursive: true });
		const file = await secret(path.join(home, "OMPAPP_0123456789abcdef.secret"), "x");
		expect((await refusal(file, home)).code).toBe("bad_request");
		expect(await Bun.file(file).exists()).toBe(true);
	});

	test("a missing file is not_found", async () => {
		expect((await refusal(path.join(tmp, "OMPAPP_0123456789abcdef.secret"), home)).code).toBe("not_found");
	});
});

describe("isSessionFilePath", () => {
	const root = "/home/u/.omp/agent/sessions";

	test("accepts <sessions root>/<project>/<name>.jsonl", () => {
		expect(isSessionFilePath(`${root}/--home-u-proj--/a.jsonl`, root, "")).toBe(true);
	});

	test("accepts the open session's own directory", () => {
		expect(isSessionFilePath("/data/s/a.jsonl", root, "/data/s")).toBe(true);
	});

	test("a session without a directory adds none, not the cwd", () => {
		expect(isSessionFilePath(path.join(process.cwd(), "a.jsonl"), root, "")).toBe(false);
	});

	test("refuses other places and other file types", () => {
		expect(isSessionFilePath(`${root}/a.jsonl`, root, "")).toBe(false);
		expect(isSessionFilePath(`${root}/p/q/a.jsonl`, root, "")).toBe(false);
		expect(isSessionFilePath(`${root}/p/a.json`, root, "")).toBe(false);
		expect(isSessionFilePath("/data/s/sub/a.jsonl", root, "/data/s")).toBe(false);
		expect(isSessionFilePath("/home/u/a.jsonl", root, "/data/s")).toBe(false);
	});
});
