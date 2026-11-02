// The import of the Flutter app's data at boot (docs/app.md, "Flutter data import"), and the full-window screen that
// says why it failed: Retry, or go on without the data, which boot then never asks about again. Loaded only when the
// shell found Flutter data.
import { render } from "@solidjs/web";
import { createSignal } from "solid-js";
import { deferred } from "../../../deferred";
import type { AppState } from "../../app_state";
import { type FlutterData, flutterData, hasFlutterData } from "../../database/flutter_data";
import { importFlutterData } from "../../database/flutter_import";
import { t } from "../../i18n/i18n";
import { Prefs } from "../../providers/settings_provider";
import { appLogger } from "../../utils/app_logger";
import { FilledButton, TextButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import "./flutter_import_screen.css";

/**
 * Imports `data` before anything reads the settings, unless the user once went on without it. Resolves once the data
 * is imported, or the user chose to go on without it after a failure.
 */
export async function runFlutterImport(state: AppState, data: FlutterData): Promise<void> {
  const skipped = Prefs.flutterImportSkipped;
  const settings = await state.db.settings.read();
  if (settings.some((row) => row.key === skipped.key && skipped.decode(row.value))) return;
  try {
    await importFlutterData(state.db, data);
  } catch (error) {
    await showFailure(state, error);
  }
}

/** Shows `error` over the whole window until an import retried from it succeeds or the user goes on without one. */
async function showFailure(state: AppState, error: unknown): Promise<void> {
  appLogger.w("flutter import failed", { error });
  const done = deferred<void>();
  const [failure, setFailure] = createSignal(describe(error));
  const [busy, setBusy] = createSignal(false);
  const retry = async () => {
    setBusy(true);
    try {
      // The shell looks again: whatever stood in the way may be gone, and so may the data.
      const data = await flutterData();
      if (hasFlutterData(data)) await importFlutterData(state.db, data);
      done.resolve();
    } catch (next) {
      appLogger.w("flutter import failed again", { error: next });
      setFailure(describe(next));
      setBusy(false);
    }
  };
  const skip = async () => {
    setBusy(true);
    // Before the settings load: the provider keeps it and writes it with the stored ones.
    await state.settings.set(Prefs.flutterImportSkipped, true);
    done.resolve();
  };
  const host = document.body.appendChild(document.createElement("div"));
  const dispose = render(
    () => (
      <FlutterImportScreen message={failure()} busy={busy()} onRetry={() => void retry()} onSkip={() => void skip()} />
    ),
    host,
  );
  await done.promise;
  dispose();
  host.remove();
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function FlutterImportScreen(props: {
  readonly message: string;
  readonly busy: boolean;
  readonly onRetry: () => void;
  readonly onSkip: () => void;
}) {
  return (
    <div class="flutter-import-screen" role="alertdialog" aria-labelledby="flutter-import-screen-title">
      <div class="flutter-import-screen-body">
        <Icon icon={Symbols.sync_problem} size={40} class="flutter-import-screen-icon" />
        <h1 id="flutter-import-screen-title" class="flutter-import-screen-title">
          {t.flutterImport.title}
        </h1>
        <p class="flutter-import-screen-detail">{t.flutterImport.detail}</p>
        <pre class="flutter-import-screen-error">{props.message}</pre>
        <div class="flutter-import-screen-actions">
          <FilledButton disabled={props.busy} onClick={props.onRetry}>
            {t.common.retry}
          </FilledButton>
          <TextButton disabled={props.busy} onClick={props.onSkip}>
            {t.flutterImport.skip}
          </TextButton>
        </div>
        <p class="flutter-import-screen-hint">{t.flutterImport.skipDetail}</p>
      </div>
    </div>
  );
}
