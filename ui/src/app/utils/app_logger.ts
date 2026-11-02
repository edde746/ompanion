import { call } from "../../bridge";
import { ignore } from "../../core/util/async";

/**
 * The app's log (lib/utils/app_logger.dart): the page's console, and for warnings also the core's log (its stderr and
 * `$OMPCORE_LOG`), where a shell's own log shows them. Debug lines only in development builds.
 */
export const appLogger = {
  d(message: string): void {
    if (import.meta.env.DEV) console.debug(message);
  },
  w(message: string, options: { error?: unknown } = {}): void {
    const line = options.error === undefined ? message : `${message}: ${String(options.error)}`;
    console.warn(line);
    ignore(call("core.log", { line: `WARN ${line}` }));
  },
};
