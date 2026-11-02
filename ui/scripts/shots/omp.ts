// OMP=1 runs: omp is installed where the app's probe looks first, `~/.local/bin` of the core's HOME, and answers.
import type { Screen } from "../shot_types";

export const screens: Screen[] = [
  {
    name: "version",
    omp: true,
    reach: async ({ exec }) => {
      const result = await exec('"$HOME/.local/bin/omp" --version');
      const version = process.env.OMP_VERSION;
      if (result.code !== 0 || (version !== undefined && !result.stdout.includes(version))) {
        throw new Error(`omp --version: exit ${result.code}, stdout ${JSON.stringify(result.stdout)}, stderr ${JSON.stringify(result.stderr)}`);
      }
      console.log(`omp --version: ${result.stdout.trim()}`);
    },
  },
];
