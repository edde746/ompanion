import 'json_fields.dart';

/// How a prompt sent while the agent streams is queued.
enum StreamingBehavior { steer, followUp }

/// `set_steering_mode` / `set_follow_up_mode`: dequeue everything or one message per turn.
enum QueueMode {
  all('all'),
  oneAtATime('one-at-a-time');

  const QueueMode(this.wire);

  final String wire;

  static QueueMode fromWire(String value) => values.firstWhere(
    (mode) => mode.wire == value,
    orElse: () => throw FormatException('unknown queue mode "$value"'),
  );
}

enum InterruptMode { immediate, wait }

enum SubagentSubscription { off, progress, events }

/// How a prompt's work ended (`prompt_result.status`).
enum PromptStatus { completed, aborted, error }

/// An image attached to `prompt`, `steer`, `follow_up` or `abort_and_prompt`.
final class RpcImage {
  const RpcImage({required this.data, required this.mimeType});

  /// Base64 of the image bytes.
  final String data;
  final String mimeType;

  Map<String, Object?> toJson() => {'type': 'image', 'data': data, 'mimeType': mimeType};
}

/// A model from omp's registry. [raw] keeps everything else (cost, thinking config, compat, …).
final class RpcModel {
  RpcModel.fromJson(this.raw)
    : provider = raw.string('provider'),
      id = raw.string('id'),
      name = raw.string('name'),
      reasoning = raw.boolean('reasoning'),
      input = raw.strings('input'),
      contextWindow = raw.optInt('contextWindow'),
      maxTokens = raw.optInt('maxTokens');

  final Map<String, Object?> raw;
  final String provider;
  final String id;
  final String name;

  /// The model supports thinking levels.
  final bool reasoning;

  /// Accepted input kinds: `text`, `image`.
  final List<String> input;
  final int? contextWindow;
  final int? maxTokens;
}

/// One entry of `get_available_commands` and `available_commands_update`.
final class RpcSlashCommand {
  RpcSlashCommand.fromJson(Map<String, Object?> json)
    : name = json.string('name'),
      aliases = json.optStrings('aliases') ?? const [],
      description = json.optString('description'),
      inputHint = json.optObject('input')?.optString('hint'),
      subcommands = [
        for (final sub in json.optObjects('subcommands') ?? const <Map<String, Object?>>[])
          (name: sub.string('name'), description: sub.optString('description'), usage: sub.optString('usage')),
      ],
      source = json.string('source');

  final String name;
  final List<String> aliases;
  final String? description;
  final String? inputHint;
  final List<({String name, String? description, String? usage})> subcommands;

  /// `builtin`, `extension`, `skill`, `custom`, `mcp_prompt`, `file`, …
  final String source;
}

/// `prompt_result.error`: why the prompt's work failed.
final class RpcPromptError {
  RpcPromptError.fromJson(Map<String, Object?> json)
    : message = json.string('message'),
      provider = json.optString('provider'),
      model = json.optString('model'),
      httpStatus = json.optInt('httpStatus'),
      retryable = json.boolean('retryable');

  final String message;
  final String? provider;
  final String? model;
  final int? httpStatus;

  /// Transient failure; omp's own retries are already exhausted.
  final bool retryable;
}

typedef RpcContextUsage = ({int tokens, int contextWindow, double percent});

/// `get_state`.
final class RpcSessionState {
  RpcSessionState.fromJson(this.raw)
    : model = switch (raw.optObject('model')) {
        final model? => RpcModel.fromJson(model),
        null => null,
      },
      thinkingLevel = raw.optString('thinkingLevel'),
      isStreaming = raw.boolean('isStreaming'),
      isCompacting = raw.boolean('isCompacting'),
      steeringMode = QueueMode.fromWire(raw.string('steeringMode')),
      followUpMode = QueueMode.fromWire(raw.string('followUpMode')),
      interruptMode = enumByName(InterruptMode.values, raw.string('interruptMode')),
      sessionFile = raw.optString('sessionFile'),
      sessionId = raw.string('sessionId'),
      sessionName = raw.optString('sessionName'),
      autoCompactionEnabled = raw.boolean('autoCompactionEnabled'),
      fastModeEnabled = raw.boolean('fastModeEnabled'),
      fastModeActive = raw.boolean('fastModeActive'),
      tokensPerSecond = raw.optNumber('tokensPerSecond')?.toDouble(),
      messageCount = raw.integer('messageCount'),
      queuedMessageCount = raw.integer('queuedMessageCount'),
      hasPendingAsyncWork = raw.boolean('hasPendingAsyncWork'),
      isSettled = raw.boolean('isSettled'),
      todoPhases = raw.objects('todoPhases'),
      systemPrompt = raw.optStrings('systemPrompt'),
      dumpTools = raw.optObjects('dumpTools'),
      contextUsage = switch (raw.optObject('contextUsage')) {
        final usage? => (
          tokens: usage.number('tokens').round(),
          contextWindow: usage.number('contextWindow').round(),
          percent: usage.number('percent').toDouble(),
        ),
        null => null,
      };

  final Map<String, Object?> raw;
  final RpcModel? model;
  final String? thinkingLevel;
  final bool isStreaming;
  final bool isCompacting;
  final QueueMode steeringMode;
  final QueueMode followUpMode;
  final InterruptMode interruptMode;
  final String? sessionFile;
  final String sessionId;
  final String? sessionName;
  final bool autoCompactionEnabled;
  final bool fastModeEnabled;
  final bool fastModeActive;
  final double? tokensPerSecond;
  final int messageCount;
  final int queuedMessageCount;

  /// Background jobs or deliveries can still inject a follow-up and wake the session.
  final bool hasPendingAsyncWork;

  /// Idle with nothing queued or pending; same predicate as `session_settled`.
  final bool isSettled;
  final List<Map<String, Object?>> todoPhases;
  final List<String>? systemPrompt;
  final List<Map<String, Object?>>? dumpTools;
  final RpcContextUsage? contextUsage;
}

/// `get_messages_page`: one stable, chronological page of the session's messages.
final class RpcMessagesPage {
  RpcMessagesPage.fromJson(Map<String, Object?> json)
    : messages = json.objects('messages'),
      nextCursor = json.optString('nextCursor'),
      totalMessages = json.integer('totalMessages') {
    if (totalMessages < 0) throw FormatException('"totalMessages": negative ($totalMessages)');
  }

  final List<Map<String, Object?>> messages;

  /// Present while more messages remain; opaque.
  final String? nextCursor;
  final int totalMessages;
}

typedef RpcPromptAck = ({String id, bool? agentInvoked});
typedef RpcOpenSessionResult = ({bool cancelled, bool resumed, String sessionId, String? sessionFile});
typedef RpcFastMode = ({bool enabled, bool active});
typedef RpcEntries = ({List<Map<String, Object?>> entries, String? leafId});
typedef RpcTree = ({List<Map<String, Object?>> tree, String? leafId});
typedef RpcCycledModel = ({RpcModel model, String? thinkingLevel, bool isScoped});
typedef RpcBranchResult = ({String text, bool cancelled});
typedef RpcBranchMessage = ({String entryId, String text});
typedef RpcLoginProvider = ({String id, String name, bool available, bool authenticated});
typedef RpcSubagentMessages = ({
  String sessionFile,
  int fromByte,
  int nextByte,
  bool reset,
  List<Map<String, Object?>> entries,
  List<Map<String, Object?>> messages,
});
typedef RpcSessionChange = ({bool cancelled});
typedef RpcHandoffResult = ({String? savedPath});
