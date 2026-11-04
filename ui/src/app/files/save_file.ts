// Saving a file the page made through the platform's save panel: the machine export, a page from the chat.
import { call } from "../../bridge";
import { asJsonObject, boolean, string } from "../../core/rpc/json_fields";
import { BridgeLink } from "../../core/transport/bridge_link";
import { newId } from "../utils/ids";
import { joinPath } from "./file_paths";

/**
 * Offers `text` in the platform's save panel as `name` (`shell.saveFile` serves it from the core's cache directory,
 * under a name of its own, so the URL needs no escaping whatever `name` holds); resolves to whether the user saved it.
 */
export async function saveFile(name: string, text: string): Promise<boolean> {
  const cache = string(asJsonObject(await call<unknown>("core.paths"), "core.paths"), "cache");
  const cached = `save-${newId()}`;
  const path = joinPath(cache, cached);
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    await files.write(path, new TextEncoder().encode(text));
    try {
      const answer = await call<unknown>("shell.saveFile", { name, url: `cache/${cached}` });
      return boolean(asJsonObject(answer, "shell.saveFile"), "saved");
    } finally {
      await files.remove(path);
    }
  } finally {
    await local.close();
  }
}
