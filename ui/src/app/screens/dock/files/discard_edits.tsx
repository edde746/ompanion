// The discard dialog the editor's Close and the open-file tabs share, so a dirty tab is never dropped silently.
import { FileDocument } from "../../../files/file_document";
import { baseName } from "../../../files/file_paths";
import { t } from "../../../i18n/i18n";
import { FilledButton, TextButton } from "../../../widgets/button";
import { Dialog, showDialog } from "../../../widgets/dialog";

/** True when `document` may close: it is clean, or the user chose to discard. */
export async function confirmDiscardIfDirty(document: FileDocument): Promise<boolean> {
  if (!document.dirty()) return true;
  const strings = t.dock.fileBrowser;
  const discard = await showDialog<boolean>((close) => (
    <Dialog
      title={strings.discardTitle({ name: baseName(document.path()) })}
      actions={
        <>
          <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
          <FilledButton onClick={() => close(true)}>{strings.discard}</FilledButton>
        </>
      }
    >
      {strings.discardBody}
    </Dialog>
  ));
  return discard === true;
}
