import { TranscriptMarkdown } from "./app/screens/chat/transcript/markdown";
import { type TranscriptActions, TranscriptScope } from "./app/screens/chat/transcript/transcript_actions";

/** The smoke check's markdown shows no session: copy reaches the clipboard, and there is no file or subagent to open. */
const actions: TranscriptActions = {
  canReset: false,
  onCopy: (text) => void navigator.clipboard.writeText(text),
  onOpenFile: (path) => {
    throw new Error(`The spike's pages have no machine to open ${path} on`);
  },
  onOpenSubagent: (id) => {
    throw new Error(`The spike's pages have no subagent ${id}`);
  },
};

/** Markdown that may still be growing, on the transcript's pipeline: a new delta renders only the last block again. */
export function Markdown(props: { text: string }) {
  return (
    <TranscriptScope value={() => actions}>
      <TranscriptMarkdown text={props.text} />
    </TranscriptScope>
  );
}
