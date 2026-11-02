// The widget of lib/screens/chat/transcript/summary_files.dart; its logic is summary_files.ts.
import { For, Show, useContext } from "solid-js";
import { t } from "../../../i18n/i18n";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import "./code_style.css";
import type { SummaryFile, SummaryFileOperation } from "./summary_files";
import "./summary_files_view.css";
import { TranscriptScope } from "./transcript_actions";

function operationLabel(operation: SummaryFileOperation): string {
  switch (operation) {
    case "read":
      return t.transcript.fileRead;
    case "write":
      return t.transcript.fileWritten;
    case "readWrite":
      return t.transcript.fileReadWritten;
    case "unknown":
      return "";
  }
}

/** The files of a compaction summary, one dense row each; a row opens its file. */
export function SummaryFiles(props: { files: readonly SummaryFile[]; elided: number }) {
  const actions = useContext(TranscriptScope);
  return (
    <div class="summary-files">
      <div class="summary-files-label">{t.transcript.summaryFiles}</div>
      <For each={props.files}>
        {(file) => (
          <button type="button" data-ripple class="summary-files-row" onClick={() => actions().onOpenFile(file.path)}>
            <Icon icon={file.operation === "read" ? Symbols.description : Symbols.edit_note} size={16} />
            <span class="code-style summary-files-path">{file.path}</span>
            <span class="summary-files-label">{operationLabel(file.operation)}</span>
          </button>
        )}
      </For>
      <Show when={props.elided > 0}>
        <div class="summary-files-label summary-files-elided">{t.transcript.filesElided({ n: props.elided })}</div>
      </Show>
    </div>
  );
}
