// lib/main.dart's startup for the page, after the first frame: the shell's answers replace the last run's, the Flutter
// app's data comes over once, the stored settings replace their snapshot, this install gets its device id once, the
// documents load, "this computer" is added once per install, and the notifications start.
import type { CoreInfo } from "../bridge";
import type { AppState } from "./app_state";
import { flutterData, hasFlutterData } from "./database/flutter_data";
import { loadDevOverrides } from "./dev_overrides";
import { applyLanguage } from "./language";
import { localMachine } from "./models/machine";
import { loadPlatform } from "./platform";
import { Prefs } from "./providers/settings_provider";
import { thisComputerAvailable } from "./services/machine_connector";
import { newId } from "./utils/ids";

export async function bootApp(state: AppState, info: CoreInfo): Promise<void> {
  const stores = [state.knownHosts, state.keys, state.sessionReads, state.sessionPins, state.machines];
  try {
    await beforeDocuments(state, info);
  } catch (error) {
    // What waits for a document (a host key check, a key's name) fails instead of waiting for good.
    for (const store of stores) store.failLoad(error);
    throw error;
  }
  await Promise.all(stores.map((store) => store.load()));
  // Once per install, so deleting this computer sticks.
  if (thisComputerAvailable() && !state.settings.get(Prefs.localMachineSeeded)) {
    const now = Date.now();
    const name = "hostname" in info && typeof info.hostname === "string" && info.hostname !== "" ? info.hostname : "localhost";
    await state.machines.save(localMachine({ id: newId(), name, createdAt: now, updatedAt: now }));
    await state.settings.set(Prefs.localMachineSeeded, true);
  }
  await state.startNotifications();
}

async function beforeDocuments(state: AppState, info: CoreInfo): Promise<void> {
  await loadPlatform(info);
  // Before anything reads the settings, mints a device id or adds this computer: the Flutter app's are kept. Its code
  // stays out of the entry chunk and loads only when there is Flutter data.
  const flutter = await flutterData();
  if (hasFlutterData(flutter)) {
    const { runFlutterImport } = await import("./screens/shell/flutter_import_screen");
    await runFlutterImport(state, flutter);
  }
  await state.settings.load();
  applyLanguage(state.settings.get(Prefs.language));
  if (state.settings.get(Prefs.deviceId) === "") await state.settings.set(Prefs.deviceId, newId());
  await loadDevOverrides();
}
