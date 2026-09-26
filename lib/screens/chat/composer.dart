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
import '../../sessions/composer_attachments.dart';
import '../../sessions/composer_draft.dart';
import '../../sessions/prompt_attachments.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../../utils/byte_size.dart';
import '../dock/machine_access.dart';
import 'attachment_chips.dart';
import 'attachment_input.dart';
import 'composer_intent.dart';
import 'composer_toolbar.dart';
import 'model_picker.dart';
import 'queue_list.dart';
import 'slash_palette.dart';

/// The toolbar's icon buttons: one control tall, as its pickers and text buttons are (docs/design.md rule 4).
const _toolbarIcon = BoxConstraints.tightFor(width: AppSizes.control, height: AppSizes.control);

/// Image types an Android keyboard may insert (a GIF, a sticker, a copied image in its clipboard).
const _keyboardImageTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

/// The prompt box: one flat block with the queued messages on top, the attachments and the text in the middle and a
/// toolbar with the model, thinking level and context meter, attach and send at the bottom. Enter sends (Shift+Enter
/// is a new line); while a run streams Enter steers and Alt/Option+Enter queues a follow-up. `/` opens the palette of
/// the session's commands, `!`/`!!` run shell commands and `$`/`$$` Python through the companion. A paste of copied
/// files, an image or a large text becomes an attachment chip, as in the TUI.
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

  /// The block the toolbar's menus open above.
  final _block = GlobalKey();

  /// The palette query the user dismissed with Esc; it reopens once the text changes.
  String? _dismissedQuery;
  bool _sending = false;

  /// Bytes of this prompt's files uploaded so far, while a send uploads.
  ({int sent, int total})? _upload;

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
    final attachments = _draft.attachments;
    final intent = composerIntent(
      text,
      hasAttachments: attachments.isNotEmpty,
      running: view.run.running,
      followUp: followUp,
      commands: view.commands,
    );
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final sessions = context.read<SessionsProvider>();
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
          final prompt = await preparePrompt(
            text: message,
            attachments: attachments,
            session: session,
            link: () async {
              final machine = sessions.machineOf(session) ?? (throw StateError('The session has no machine.'));
              return (await machineAccess(sessions.runtimeFor(machine))).$1;
            },
            onUploadProgress: (sent, total) {
              if (mounted) setState(() => _upload = (sent: sent, total: total));
            },
          );
          if (mounted) setState(() => _upload = null);
          await _prompt(
            session.rpc,
            prompt.message,
            images: prompt.images,
            behavior: behavior,
            onRefused: () => draft.giveBack(text, attachments: attachments),
          );
        } on AttachmentException catch (error) {
          // Nothing went to omp: the whole draft comes back, with what kept it from going.
          draft.giveBack(text, attachments: attachments);
          messenger.showSnackBar(SnackBar(content: Text(error.describe(t))));
        } on Object catch (error) {
          // Nothing was queued: give the draft back.
          draft.giveBack(text, attachments: attachments);
          messenger.showSnackBar(SnackBar(content: Text(t.composer.sendFailed(error: '$error'))));
        } finally {
          if (mounted) {
            setState(() {
              _sending = false;
              _upload = null;
            });
          }
        }
    }
  }

  /// The attach button: any files; images omp takes as image content become images, as a paste of them does.
  Future<void> _attachFiles() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final draft = _draft;
    try {
      final files = await FilePicker.pickFiles();
      final attachments = [
        for (final file in files)
          ...switch (file.path) {
            final path? => await attachmentsFromPaths([path]),
            null => [attachmentFromBytes(file.name, await file.readAsBytes())],
          },
      ];
      draft.addAttachments(attachments);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.composer.attachFailed(error: '$error'))));
    }
    if (mounted) _focus.requestFocus();
  }

  /// A paste into the text field (Cmd/Ctrl+V, the context menu's Paste): copied files, an image and a large text
  /// become chips, other text goes in at the cursor.
  Future<void> _paste() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final draft = _draft;
    try {
      switch (await readPaste(context.read<AttachmentSource>())) {
        case null:
          return;
        case PasteText(:final text):
          draft.insert(text);
        case PasteAttachments(:final attachments):
          draft.addAttachments(attachments);
      }
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.composer.pasteFailed(error: '$error'))));
    }
  }

  /// An image an Android keyboard inserts: a GIF, a sticker, an image from its clipboard.
  void _insertContent(KeyboardInsertedContent content) {
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t.composer.pasteFailed(error: content.uri))),
      );
      return;
    }
    _draft.addAttachments([ImageAttachment(RpcImage(data: base64Encode(bytes), mimeType: content.mimeType))]);
  }

  /// The field's context menu with its Paste taking [_paste]'s way. The field offers Paste only while the clipboard
  /// holds text; a copied file or image pastes too, so Paste is always there. iOS keeps its own menu, whose Paste
  /// inserts text without asking for the clipboard; for anything else the menu gets a Paste of ours.
  Widget _contextMenu(BuildContext context, EditableTextState field) {
    void paste() {
      field.hideToolbar();
      unawaited(_paste());
    }

    final items = [
      for (final item in field.contextMenuButtonItems)
        item.type == ContextMenuButtonType.paste ? item.copyWith(onPressed: paste) : item,
    ];
    final canPaste = !field.widget.readOnly && field.textEditingValue.selection.isValid;
    final offersPaste = items.any((item) => item.type == ContextMenuButtonType.paste);
    if (SystemContextMenu.isSupportedByField(field)) {
      return SystemContextMenu.editableText(
        editableTextState: field,
        items: [
          ...SystemContextMenu.getDefaultItems(field),
          if (canPaste && !offersPaste)
            IOSSystemContextMenuItemCustom(title: MaterialLocalizations.of(context).pasteButtonLabel, onPressed: paste),
        ],
      );
    }
    if (canPaste && !offersPaste) {
      final at = items.indexWhere(
        (item) => item.type != ContextMenuButtonType.cut && item.type != ContextMenuButtonType.copy,
      );
      items.insert(at < 0 ? items.length : at, ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: paste));
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: field.contextMenuAnchors, buttonItems: items);
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
          final attachments = _draft.attachments;
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
                  key: _block,
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QueueList(session: session),
                      if (attachments.isNotEmpty)
                        AttachmentChips(
                          attachments: attachments,
                          onRemove: _draft.removeAttachment,
                          onInline: _draft.inline,
                        ),
                      Actions(
                        // Cmd/Ctrl+V; the context menu's Paste goes through [_contextMenu].
                        actions: {
                          PasteTextIntent: CallbackAction<PasteTextIntent>(
                            onInvoke: (_) {
                              unawaited(_paste());
                              return null;
                            },
                          ),
                        },
                        child: TextField(
                          key: const ValueKey('composer'),
                          controller: _draft.text,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 10,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          contextMenuBuilder: _contextMenu,
                          contentInsertionConfiguration: ContentInsertionConfiguration(
                            allowedMimeTypes: _keyboardImageTypes,
                            onContentInserted: _insertContent,
                          ),
                          decoration: InputDecoration(
                            hintText: data.running && !closed ? t.composer.hintRunning : t.composer.hint,
                            filled: false,
                            // No outline: the theme's field border adds its gap to the start and centres the text
                            // vertically, which moves the text off these insets.
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            // 11 + the glyphs' side bearing puts the text's ink on the 12 px edge of the model icon
                            // below; 12 above the line box leaves as much space over the text as under the toolbar's
                            // labels.
                            contentPadding: const EdgeInsets.fromLTRB(11, 12, 12, 0),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
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
                                                child: ModelPicker(
                                                  session: session,
                                                  machine: machine,
                                                  model: data.model,
                                                  above: _block,
                                                ),
                                              ),
                                              LayoutId(
                                                id: _Picker.thinking,
                                                child: ThinkingPicker(session: session, level: data.thinking, above: _block),
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
                                  tooltip: t.composer.attach,
                                  icon: const Icon(Icons.attach_file, size: 20),
                                  constraints: _toolbarIcon,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  onPressed: closed ? null : () => unawaited(_attachFiles()),
                                ),
                                const SizedBox(width: 4),
                                if (_upload case (:final sent, :final total))
                                  Tooltip(
                                    message: t.composer.uploading(sent: formatBytes(sent), total: formatBytes(total)),
                                    child: SizedBox.fromSize(
                                      size: const Size.square(AppSizes.control),
                                      child: Center(
                                        child: SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                            key: const ValueKey('upload-progress'),
                                            strokeWidth: 2.5,
                                            value: total == 0 ? null : sent / total,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else if (data.running && !closed && narrow) ...[
                                  IconButton(
                                    key: const ValueKey('follow-up'),
                                    tooltip: t.composer.followUp,
                                    icon: const Icon(Icons.schedule, size: 20),
                                    constraints: _toolbarIcon,
                                    onPressed: canSend ? followUp : null,
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton.filled(
                                    key: const ValueKey('steer'),
                                    tooltip: t.composer.steer,
                                    icon: const Icon(Icons.subdirectory_arrow_right, size: 20),
                                    constraints: _toolbarIcon,
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
                                    constraints: _toolbarIcon,
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
