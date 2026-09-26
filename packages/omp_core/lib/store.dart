/// The session view: everything the chat UI renders for one omp session, and the pure reducer that builds it from
/// RPC frames, `get_state`, message pages, session entries and companion events.
library;

export 'src/store/content.dart'
    show ContentBlock, ImageBlock, OtherBlock, RedactedThinkingBlock, TextBlock, ThinkingBlock, ToolCallBlock, textOf;
export 'src/store/external_writer.dart';
export 'src/store/reducer.dart';
export 'src/store/session_view.dart';
export 'src/store/transcript.dart'
    hide
        asyncState,
        decodeAssistant,
        decodeEntry,
        decodeMessage,
        decodeRetryRecovery,
        decodeUsage,
        entryTime,
        isBackgroundRun;
