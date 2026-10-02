/**
 * Bun helpers for running a real omp against the fake provider: the tested omp binary, the same home
 * `omp-home.sh` writes, and an environment that keeps the user's own omp configuration, profiles and API keys out.
 */
import * as fs from "node:fs";
import * as path from "node:path";

const SCRIPT = path.join(import.meta.dir, "omp-home.sh");

/** The omp version the tests run: `$OMP_VERSION`, else `harness/omp-version`. */
export const OMP_VERSION = process.env.OMP_VERSION || fs.readFileSync(path.join(import.meta.dir, "omp-version"), "utf8").trim();

/** This computer's release binary of [OMP_VERSION], where `scripts/fetch_omp.sh` puts it. */
export const OMP_BINARY = path.join(import.meta.dir, "..", ".tools", "omp", OMP_VERSION, `omp-${process.platform}-${process.arch}`);

/** Runs `harness/omp-home.sh`; `extraConfigYaml` becomes its third argument. */
export async function createOmpHome(home: string, port: number, extraConfigYaml?: string): Promise<void> {
	const args = [SCRIPT, home, String(port)];
	if (extraConfigYaml !== undefined) {
		const extraPath = path.join(home, "extra-config.yml");
		await Bun.write(extraPath, extraConfigYaml);
		args.push(extraPath);
	}
	const proc = Bun.spawn(["sh", ...args], { stdout: "pipe", stderr: "pipe" });
	const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
	if (exitCode !== 0) throw new Error(`omp-home.sh exited ${exitCode}: ${stderr.trim()}`);
}

/**
 * Environment for an omp child: HOME is the isolated home, and only PATH, TMPDIR, USER, SHELL and LANG
 * pass through. Dropping everything else keeps PI_* / XDG_* directory overrides and provider API keys
 * from reaching omp, so it can never call a real provider.
 */
export function ompEnv(home: string): Record<string, string> {
	const env: Record<string, string> = { HOME: home };
	for (const key of ["PATH", "TMPDIR", "USER", "SHELL", "LANG"]) {
		const value = process.env[key];
		if (value !== undefined) env[key] = value;
	}
	return env;
}
