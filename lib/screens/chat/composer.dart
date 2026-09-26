import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/composer_draft.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import 'composer_intent.dart';
import 'composer_toolbar.dart';
import 'model_picker.dart';
import 'queue_list.dart';
import 'slash_palette.dart';

/// Image types omp accepts, by file extension.
const _imageTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

/// The prompt box: one flat block with the queued messages on top, the text in the middle and a toolbar with the
/// model, thinking level and context meter, attach and send at the bottom. Enter sends (Shift+Enter is a new
/// line); while a run streams Enter steers and Alt/Option+Enter queues a follow-up. `/` opens the palette of the
/// session's commands, `!`/`!!` run shell commands and `$`/`$$` Python through the companion.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.session});

  final LiveSession session;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  late ComposerDraft _draft;
  int _paletteIndex = 0;

  /// The palette query the user dismissed with Esc; it reopens once the text changes.
  String? _dismissedQuery;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _detach();
      _attach();
    }
  }

  @override
  void dispose() {
    _detach();
    _focus.dispose();
    super.dispose();
  }

  void _attach() {
    _draft = context.read<SessionsProvider>().draftOf(widget.session);
    _draft.addListener(_onDraft);
    _draft.text.addListener(_onText);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onDraft());
  }

  void _detach() {
    _draft.removeListener(_onDraft);
    _draft.text.removeListener(_onText);
  }

  void _onDraft() {
    if (!mounted) return;
    if (_draft.takeFocusRequest()) _focus.requestFocus();
    setState(() {});
  }

  void _onText() {
    if (!mounted) return;
    setState(() {
      _paletteIndex = 0;
      if (_dismissedQuery != paletteQuery(_draft.text.text)) _dismissedQuery = null;
    });
  }

  List<SlashCommand> _paletteItems(SessionView view) {
    final query = paletteQuery(_draft.text.text);
    if (query == null || query == _dismissedQuery) return const [];
    return filterCommands(view.commands, query);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // IME composition owns Enter and the arrows until it commits.
    if (_draft.text.value.composing.isValid) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final view = widget.session.view;
    final palette = _paletteItems(view);
    final key = event.logicalKey;
    if (palette.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() => _paletteIndex = (_paletteIndex + 1) % palette.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() => _paletteIndex = (_paletteIndex - 1 + palette.length) % palette.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        _pick(palette[_paletteIndex.clamp(0, palette.length - 1)]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _dismissedQuery = paletteQuery(_draft.text.text));
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed) return KeyEventResult.ignored;
      final typed = paletteQuery(_draft.text.text);
      // Enter completes the highlighted command unless the typed name already is one.
      if (palette.isNotEmpty && (typed == null || findCommand(view.commands, typed) == null)) {
        _pick(palette[_paletteIndex.clamp(0, palette.length - 1)]);
        return KeyEventResult.handled;
      }
      unawaited(_send(followUp: keyboard.isAltPressed));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _pick(SlashCommand command) {
    final text = '/${command.name} ';
    _draft.text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  Future<void> _send({required bool followUp}) async {
    if (_sending) return;
    final session = widget.session;
    final view = session.view;
    final text = _draft.text.text;
    final images = _draft.images;
    final intent = composerIntent(
      text,
      hasImages: images.isNotEmpty,
      running: view.run.running,
      followUp: followUp,
      commands: view.commands,
    );
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    switch (intent) {
      case NothingToSend():
        return;
      case UnknownCommand(:final name):
        messenger.showSnackBar(SnackBar(content: Text(t.composer.unknownCommand(name: name))));
      case RunBash() || RunPython() when session.companionHello == null:
        // Without the companion a `/ompx` call would reach the model as a prompt.
        messenger.showSnackBar(SnackBar(content: Text(t.chat.noCompanion)));
      case RunBash(:final command, :final excludeFromContext):
        context
            .read<SessionsProvider>()
            .execRunsOf(session)
            .start(session, ExecutionKind.bash, command, excludeFromContext: excludeFromContext);
        _draft.clear();
      case RunPython(:final code, :final excludeFromContext):
        context
            .read<SessionsProvider>()
            .execRunsOf(session)
            .start(session, ExecutionKind.python, code, excludeFromContext: excludeFromContext);
        _draft.clear();
      case SendPrompt(text: final message, :final behavior):
        // The draft this text came from; the composer may show another session by the time omp answers.
        final draft = _draft;
        setState(() => _sending = true);
        draft.clear();
        try {
          await _prompt(
            session.rpc,
            message,
            images: images,
            behavior: behavior,
            onRefused: () => draft.giveBack(text, images: images),
          );
        } on Object catch (error) {
          // Nothing was queued: give the text back.
          draft.giveBack(text, images: images);
          messenger.showSnackBar(SnackBar(content: Text(t.composer.sendFailed(error: '$error'))));
        } finally {
          if (mounted) setState(() => _sending = false);
        }
    }
  }

  Future<void> _attachImages() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final draft = _draft;
    final files = await FilePicker.pickFiles(type: FileType.image);
    final images = <RpcImage>[];
    for (final file in files) {
      final mimeType = _imageTypes[file.extension?.toLowerCase()];
      if (mimeType == null) {
        messenger.showSnackBar(SnackBar(content: Text(t.composer.unsupportedImage(name: file.name))));
        continue;
      }
      images.add(RpcImage(data: base64Encode(await file.readAsBytes()), mimeType: mimeType));
    }
    if (images.isNotEmpty) draft.addImages(images);
    if (mounted) _focus.requestFocus();
  }

  /// Sends [message] as a prompt; throws when omp rejects it. omp acknowledges a prompt before it starts it, so one it
  /// then cannot start (no model or API key, another prompt still starting) fails only in its `prompt_result`, and
  /// [onRefused] runs. A run that started and then failed is in the transcript already.
  static Future<void> _prompt(
    RpcClient rpc,
    String message, {
    required List<RpcImage> images,
    required StreamingBehavior? behavior,
    required VoidCallback onRefused,
  }) async {
    String? id;
    // The result can arrive before the acknowledgement is read, so listening starts before the prompt goes out.
    final early = <PromptResultFrame>[];
    late final StreamSubscription<RpcFrame> results;
    void settle(PromptResultFrame result) {
      unawaited(results.cancel());
      if (result.status == PromptStatus.error && !result.agentInvoked) onRefused();
    }

    results = rpc.frames.listen((frame) {
      if (frame is! PromptResultFrame) return;
      if (id == null) {
        early.add(frame);
      } else if (frame.id == id) {
        settle(frame);
      }
    });
    final RpcPromptAck ack;
    try {
      ack = await rpc.prompt(message, images: images, streamingBehavior: behavior);
    } on Object {
      unawaited(results.cancel());
      rethrow;
    }
    // A command that finished locally gets no result.
    if (ack.agentInvoked == false) {
      unawaited(results.cancel());
      return;
    }
    id = ack.id;
    if (early.where((frame) => frame.id == ack.id).firstOrNull case final result?) settle(result);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final session = widget.session;
    final machine = context.select<SessionsProvider, Machine?>((sessions) => sessions.machineOf(session));
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<_ComposerData>(
        session: session,
        select: _select,
        builder: (context, data) {
          // A closed session has no omp to talk to; its model, thinking level and context are gone with it.
          final closed = link is LinkClosed;
          final palette = _paletteItems(session.view);
          final images = _draft.images;
          final canSend = !_sending && !closed;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (palette.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SlashPalette(
                      commands: palette,
                      selected: _paletteIndex.clamp(0, palette.length - 1),
                      onPick: _pick,
                    ),
                  ),
                Material(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QueueList(session: session),
                      if (images.isNotEmpty)
                        SizedBox(
                          height: 72,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final (index, image) in images.indexed)
                                _Thumbnail(
                                  key: ObjectKey(image),
                                  image: image,
                                  onRemove: () => _draft.removeImageAt(index),
                                ),
                            ],
                          ),
                        ),
                      TextField(
                        key: const ValueKey('composer'),
                        controller: _draft.text,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 10,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: data.running && !closed ? t.composer.hintRunning : t.composer.hint,
                          filled: false,
                          contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 6, 6),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Phones: Follow-up and Steer as icons, so the pickers keep their room.
                            final narrow = constraints.maxWidth < 480;
                            void followUp() => unawaited(_send(followUp: true));
                            void steer() => unawaited(_send(followUp: false));
                            return Row(
                              children: [
                                Expanded(
                                  child: closed
                                      ? const SizedBox.shrink()
                                      : SizedBox(
                                          height: AppSizes.control,
                                          child: CustomMultiChildLayout(
                                            delegate: _PickersLayout(),
                                            children: [
                                              LayoutId(
                                                id: _Picker.model,
                                                child: ModelPicker(session: session, machine: machine, model: data.model),
                                              ),
                                              LayoutId(
                                                id: _Picker.thinking,
                                                child: ThinkingPicker(session: session, level: data.thinking),
                                              ),
                                              LayoutId(
                                                id: _Picker.meter,
                                                child: ContextMeter(usage: data.context, cost: data.cost),
                                              ),
                                            ],
                                          ),
                                        ),
                                ),
                                IconButton(
                                  tooltip: t.composer.attachImage,
                                  icon: const Icon(Icons.image_outlined, size: 20),
                                  color: theme.colorScheme.onSurfaceVariant,
                                  onPressed: closed ? null : () => unawaited(_attachImages()),
                                ),
                                const SizedBox(width: 4),
                                if (data.running && !closed && narrow) ...[
                                  IconButton(
                                    key: const ValueKey('follow-up'),
                                    tooltip: t.composer.followUp,
                                    icon: const Icon(Icons.schedule, size: 20),
                                    onPressed: canSend ? followUp : null,
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton.filled(
                                    key: const ValueKey('steer'),
                                    tooltip: t.composer.steer,
                                    icon: const Icon(Icons.subdirectory_arrow_right, size: 20),
                                    onPressed: canSend ? steer : null,
                                  ),
                                ] else if (data.running && !closed) ...[
                                  TextButton(
                                    key: const ValueKey('follow-up'),
                                    onPressed: canSend ? followUp : null,
                                    child: Text(t.composer.followUp),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    key: const ValueKey('steer'),
                                    onPressed: canSend ? steer : null,
                                    child: Text(t.composer.steer),
                                  ),
                                ] else
                                  IconButton.filled(
                                    key: const ValueKey('send'),
                                    tooltip: t.composer.send,
                                    icon: const Icon(Icons.arrow_upward, size: 20),
                                    onPressed: canSend ? steer : null,
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _Picker { model, thinking, meter }

/// The toolbar's pickers side by side. The model button gets the width its name needs first, up to what leaves the
/// thinking button its icon and chevron; the thinking label shrinks next. The rest of the row stays free, so send sits
/// at the end.
final class _PickersLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final meter = layoutChild(_Picker.meter, BoxConstraints.loose(size));
    final model = layoutChild(
      _Picker.model,
      BoxConstraints.loose(Size(math.max(0, size.width - meter.width - ToolbarButton.minWidth), size.height)),
    );
    final thinking = layoutChild(
      _Picker.thinking,
      BoxConstraints.loose(Size(math.max(0, size.width - meter.width - model.width), size.height)),
    );
    var x = 0.0;
    for (final (id, child) in [(_Picker.model, model), (_Picker.thinking, thinking), (_Picker.meter, meter)]) {
      positionChild(id, Offset(x, (size.height - child.height) / 2));
      x += child.width;
    }
  }

  @override
  bool shouldRelayout(_PickersLayout oldDelegate) => false;
}

/// What the composer shows besides the draft; compared field by field so streamed tokens do not rebuild it.
typedef _ComposerData = ({
  bool running,
  List<SlashCommand> commands,
  ModelRef? model,
  String? thinking,
  ContextUsage? context,
  double cost,
});

_ComposerData _select(SessionView view) => (
  running: view.run.running,
  commands: view.commands,
  model: view.config.model,
  thinking: view.config.thinkingLevel,
  context: view.contextUsage,
  cost: view.usageTotals.cost,
);

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({super.key, required this.image, required this.onRemove});

  final RpcImage image;
  final VoidCallback onRemove;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late final Uint8List _bytes = base64Decode(widget.image.data);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSizes.gap),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Image.memory(_bytes, width: 64, height: 64, fit: BoxFit.cover),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                minimumSize: const Size.square(24),
                fixedSize: const Size.square(24),
                padding: EdgeInsets.zero,
              ),
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              tooltip: context.t.composer.removeImage,
              icon: const Icon(Icons.close),
              onPressed: widget.onRemove,
            ),
          ),
        ],
      ),
    );
  }
}
