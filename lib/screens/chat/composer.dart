import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
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
import '../../widgets/activity_mark.dart';
import '../dock/machine_access.dart';
import '../machines/connect_dialogs.dart';
import 'attachment_chips.dart';
import 'attachment_input.dart';
import 'composer_intent.dart';
import 'composer_toolbar.dart';
import 'mention_spans.dart';
import 'model_mention_palette.dart';
import 'mode_controls.dart';
import 'model_picker.dart';
import 'queue_list.dart';
import 'slash_palette.dart';
import 'transcript/markdown.dart' show markdownLineHeight;

/// The toolbar's icon buttons: one control tall, as its pickers and text buttons are (docs/design.md rule 4).
const _toolbarIcon = BoxConstraints.tightFor(width: AppSizes.control, height: AppSizes.control);

/// Image types an Android keyboard may insert (a GIF, a sticker, a copied image in its clipboard).
const _keyboardImageTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

/// The user message omp will echo for a prompt of [text] and [images], shown in the transcript until it does; null
/// while there is nothing to show yet (only a file, whose mention the upload adds). [key] keeps the row of an earlier
/// version of it.
UserItem? _pendingMessage(String text, List<RpcImage> images, {required int timestamp, String? key}) {
  final content = [
    if (text.isNotEmpty) TextBlock(text),
    for (final image in images) ImageBlock(data: image.data, mimeType: image.mimeType),
  ];
  return content.isEmpty ? null : UserItem(key: key, timestamp: timestamp, content: content, attribution: 'user');
}

/// The prompt box: one flat block with the queued messages on top, the attachments and the text in the middle and a
/// toolbar with the model, thinking level and context meter, the goal and the loop while there are any, attach and
/// send at the bottom. Enter sends (Shift+Enter is a new line); while a run streams Enter steers and Alt/Option+Enter
/// queues a follow-up. `/` opens the palette of the session's commands, `!`/`!!` run shell commands and `$`/`$$`
/// Python through the companion. A paste of copied files, an image or a large text becomes an attachment chip, as in
/// the TUI.
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

  /// The `^` token the user dismissed with Esc; its list reopens once the token changes.
  ({int start, String query})? _dismissedMention;

  /// The machine's models for the `^` list, loaded when a `^` is typed first; [_modelsError] when that failed.
  List<RpcModel>? _models;
  Object? _modelsError;
  bool _modelsLoading = false;
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
    _draft.text.chipSpan = (chip, style) => modelChipSpan(chip.name, style: style);
    _draft.addListener(_onDraft);
    _draft.text.addListener(_onText);
    _models = null;
    _modelsError = null;
    _modelsLoading = false;
    _dismissedMention = null;
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
    final mention = mentionQuery(_draft.text.value);
    if (mention != null) _loadModels();
    setState(() {
      _paletteIndex = 0;
      if (_dismissedQuery != paletteQuery(_draft.text.text)) _dismissedQuery = null;
      if (_dismissedMention != mention) _dismissedMention = null;
      // A list that failed loads again for the next `^`.
      if (mention == null) _modelsError = null;
    });
  }

  List<SlashCommand> _paletteItems(SessionView view) {
    final query = paletteQuery(_draft.text.text);
    if (query == null || query == _dismissedQuery) return const [];
    return filterCommands(view.commands, query);
  }

  /// The `^` list at the cursor: null while closed, else the models matching the token ([models] null while they load,
  /// [error] when they could not). Closed when nothing matches, so Enter sends the token as typed.
  ({List<RpcModel>? models, Object? error})? _mention() {
    final live = mentionQuery(_draft.text.value);
    if (live == null || live == _dismissedMention) return null;
    if (_modelsError case final error?) return (models: null, error: error);
    final models = _models;
    if (models == null) return _modelsLoading ? (models: null, error: null) : null;
    final matching = filterModels(models, live.query);
    return matching.isEmpty ? null : (models: matching, error: null);
  }

  /// Loads the machine's model list for the `^` list, once per composer session.
  void _loadModels() {
    if (_models != null || _modelsLoading) return;
    final sessions = context.read<SessionsProvider>();
    final session = widget.session;
    final machine = sessions.machineOf(session);
    if (machine == null) return;
    _modelsLoading = true;
    unawaited(
      sessions
          .models(machine, session.rpc)
          .then(
            (models) {
              if (!mounted || !identical(session, widget.session)) return;
              setState(() {
                _models = models;
                _modelsLoading = false;
              });
            },
            onError: (Object error) {
              if (!mounted || !identical(session, widget.session)) return;
              setState(() {
                _modelsError = error;
                _modelsLoading = false;
              });
            },
          ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // IME composition owns Enter and the arrows until it commits.
    if (_draft.text.value.composing.isValid) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final view = widget.session.view;
    final palette = _paletteItems(view);
    final mention = palette.isEmpty ? _mention() : null;
    final picks = mention?.models ?? const <RpcModel>[];
    final key = event.logicalKey;
    final rows = palette.isNotEmpty ? palette.length : picks.length;
    if (rows > 0) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() => _paletteIndex = (_paletteIndex + 1) % rows);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() => _paletteIndex = (_paletteIndex - 1 + rows) % rows);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        if (palette.isNotEmpty) {
          _pick(palette[_paletteIndex.clamp(0, rows - 1)]);
        } else {
          _pickModel(picks[_paletteIndex.clamp(0, rows - 1)]);
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      if (palette.isNotEmpty) {
        setState(() => _dismissedQuery = paletteQuery(_draft.text.text));
        return KeyEventResult.handled;
      }
      if (mention != null) {
        setState(() => _dismissedMention = mentionQuery(_draft.text.value));
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
      if (picks.isNotEmpty) {
        _pickModel(picks[_paletteIndex.clamp(0, picks.length - 1)]);
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

  /// Puts [model] over the `^` token at the cursor: a chip with its name that sends `^provider/id `, as omp's
  /// completion inserts.
  void _pickModel(RpcModel model) {
    final live = mentionQuery(_draft.text.value);
    if (live == null) return;
    _draft.text.insertChip(live.start, _draft.text.selection.baseOffset, (
      name: modelDisplayName(model),
      source: '^${modelSelector(model)}',
    ));
    _focus.requestFocus();
  }

  /// Copies the field's selection with every model chip in it as the text omp would receive; [cut] deletes it too.
  /// False when the selection holds no chip, for the field's own copy.
  bool _copyChips({required bool cut}) {
    final text = _draft.text;
    final value = text.value;
    final selection = value.selection;
    if (!selection.isValid || selection.isCollapsed) return false;
    final selected = selection.textInside(value.text);
    final expanded = text.expand(selected);
    if (expanded == selected) return false;
    unawaited(Clipboard.setData(ClipboardData(text: expanded)));
    if (cut) {
      text.value = TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, ''),
        selection: TextSelection.collapsed(offset: selection.start),
      );
    }
    return true;
  }

  Future<void> _send({required bool followUp}) async {
    if (_sending) return;
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final sessions = context.read<SessionsProvider>();
    var session = widget.session;
    // An idle exit ended omp with nothing to lose: the send opens the session in a new run, then goes there.
    if (session.linkState is LinkClosed && session.view.idleExit != null) {
      setState(() => _sending = true);
      try {
        session = await sessions.reopen(session);
      } on Object catch (error) {
        messenger.showSnackBar(SnackBar(content: Text(t.chat.reopenFailed(error: describeConnectError(t, error)))));
        return;
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      // Another omp process holds the file now: the reopened session is its read-only reader, which takes no prompt.
      if (!mounted || session is ExternalSession) return;
    }
    final view = session.view;
    final typed = _draft.text.text;
    final chips = _draft.text.chips;
    final attachments = _draft.attachments;
    // A tagged model goes out as omp's `^provider/id`, which omp turns into its `<model agent="m1" …/>` tag.
    final intent = composerIntent(
      _draft.text.expand(typed),
      hasAttachments: attachments.isNotEmpty,
      running: view.run.running,
      followUp: followUp,
      commands: view.commands,
    );
    switch (intent) {
      case NothingToSend():
        return;
      case UnknownCommand(:final name):
        messenger.showSnackBar(SnackBar(content: Text(t.composer.unknownCommand(name: name))));
      case RunBash() || RunPython() when session.companionHello == null:
        // Without the companion a `/ompx` call would reach the model as a prompt.
        messenger.showSnackBar(SnackBar(content: Text(t.chat.noCompanion)));
      case RunBash(:final command, :final excludeFromContext):
        sessions
            .execRunsOf(session)
            .start(session, ExecutionKind.bash, command, excludeFromContext: excludeFromContext);
        _draft.clear();
      case RunPython(:final code, :final excludeFromContext):
        sessions.execRunsOf(session).start(session, ExecutionKind.python, code, excludeFromContext: excludeFromContext);
        _draft.clear();
      case SendPrompt(text: final message, :final behavior, :final command):
        // The draft this text came from; the composer may show another session by the time omp answers.
        final draft = _draft;
        setState(() => _sending = true);
        draft.clear();
        // The transcript shows the prompt and its awaiting-reply row from here: the upload and the round trip before
        // omp puts the prompt in the transcript are silent otherwise (SessionView.pendingPrompt). A slash command
        // shows no message, since omp does not keep it as typed, nor does a steer or follow-up, which waits in omp's
        // queue.
        final shows = command == null && behavior == null;
        final sentAt = DateTime.now().millisecondsSinceEpoch;
        final images = [
          for (final attachment in attachments)
            if (attachment case ImageAttachment(:final image)) image,
        ];
        final shown = shows ? _pendingMessage(message, images, timestamp: sentAt) : null;
        session.setPendingPrompt(PendingPrompt(message: shown));
        // A send that reached nothing, or that omp refused: the prompt goes and the draft comes back.
        void giveBack() {
          session.setPendingPrompt(null);
          draft.giveBack(typed, attachments: attachments, chips: chips);
        }

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
          // Attached files and pastes add to the text: the message shows what omp will echo.
          if (shows && prompt.message != message) {
            session.setPendingPrompt(
              PendingPrompt(
                message: _pendingMessage(prompt.message, prompt.images, timestamp: sentAt, key: shown?.key),
              ),
            );
          }
          await _prompt(session, prompt.message, images: prompt.images, behavior: behavior, onRefused: giveBack);
        } on AttachmentException catch (error) {
          // Nothing went to omp: the whole draft comes back, with what kept it from going.
          giveBack();
          messenger.showSnackBar(SnackBar(content: Text(error.describe(t))));
        } on Object catch (error) {
          // Nothing was queued: give the draft back.
          giveBack();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.t.composer.pasteFailed(error: content.uri))));
      return;
    }
    _draft.addAttachments([ImageAttachment(RpcImage(data: base64Encode(bytes), mimeType: content.mimeType))]);
  }

  /// The field's context menu with its Paste taking [_paste]'s way. The field offers Paste only while the clipboard
  /// holds text; a copied file or image pastes too, so Paste is always there. iOS keeps its own menu, whose Paste
  /// inserts text without asking for the clipboard; for anything else the menu gets a Paste of ours. Copy and Cut of a
  /// selection holding a model chip take [_copyChips]'s way.
  Widget _contextMenu(BuildContext context, EditableTextState field) {
    void paste() {
      field.hideToolbar();
      unawaited(_paste());
    }

    VoidCallback? chipAware(VoidCallback? own, {required bool cut}) => own == null
        ? null
        : () {
            if (!_copyChips(cut: cut)) return own();
            field.hideToolbar();
          };
    final items = [
      for (final item in field.contextMenuButtonItems)
        switch (item.type) {
          ContextMenuButtonType.paste => item.copyWith(onPressed: paste),
          ContextMenuButtonType.copy => item.copyWith(onPressed: chipAware(item.onPressed, cut: false)),
          ContextMenuButtonType.cut => item.copyWith(onPressed: chipAware(item.onPressed, cut: true)),
          _ => item,
        },
    ];
    final canPaste = !field.widget.readOnly && field.textEditingValue.selection.isValid;
    final offersPaste = items.any((item) => item.type == ContextMenuButtonType.paste);
    if (SystemContextMenu.isSupportedByField(field)) {
      final localizations = MaterialLocalizations.of(context);
      final value = field.textEditingValue;
      final selected = value.selection.isValid ? value.selection.textInside(value.text) : '';
      final holdsChip = _draft.text.expand(selected) != selected;
      void copy({required bool cut}) {
        field.hideToolbar();
        _copyChips(cut: cut);
      }

      return SystemContextMenu.editableText(
        editableTextState: field,
        items: [
          for (final item in SystemContextMenu.getDefaultItems(field))
            switch (item) {
              IOSSystemContextMenuItemCopy() when holdsChip => IOSSystemContextMenuItemCustom(
                title: localizations.copyButtonLabel,
                onPressed: () => copy(cut: false),
              ),
              IOSSystemContextMenuItemCut() when holdsChip => IOSSystemContextMenuItemCustom(
                title: localizations.cutButtonLabel,
                onPressed: () => copy(cut: true),
              ),
              _ => item,
            },
          if (canPaste && !offersPaste)
            IOSSystemContextMenuItemCustom(title: localizations.pasteButtonLabel, onPressed: paste),
        ],
      );
    }
    if (canPaste && !offersPaste) {
      final at = items.indexWhere(
        (item) => item.type != ContextMenuButtonType.cut && item.type != ContextMenuButtonType.copy,
      );
      items.insert(
        at < 0 ? items.length : at,
        ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: paste),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: field.contextMenuAnchors, buttonItems: items);
  }

  /// Sends [message] as a prompt; throws when omp rejects it. omp acknowledges a prompt before it starts it, so one it
  /// then cannot start (no model or API key, another prompt still starting) fails only in its `prompt_result`, and
  /// [onRefused] runs. A run that started and then failed is in the transcript already. The pending prompt
  /// ([SessionView.pendingPrompt]) and its awaiting-reply row go when a run starts (the reducer), or here: when omp is
  /// done with the prompt without a run (a command that finished in omp, a refusal), or when the connection ends first.
  static Future<void> _prompt(
    LiveSession session,
    String message, {
    required List<RpcImage> images,
    required StreamingBehavior? behavior,
    required VoidCallback onRefused,
  }) async {
    final rpc = session.rpc;
    String? id;
    // The result can arrive before the acknowledgement is read, so listening starts before the prompt goes out.
    final early = <PromptResultFrame>[];
    late final StreamSubscription<RpcFrame> results;
    void settle(PromptResultFrame result) {
      unawaited(results.cancel());
      session.setPendingPrompt(null);
      if (result.status == PromptStatus.error && !result.agentInvoked) onRefused();
    }

    results = rpc.frames.listen(
      (frame) {
        if (frame is! PromptResultFrame) return;
        if (id == null) {
          early.add(frame);
        } else if (frame.id == id) {
          settle(frame);
        }
      },
      // Frames of the next connection come from another client; a run this prompt started shows there by itself.
      onDone: () => session.setPendingPrompt(null),
    );
    final RpcPromptAck ack;
    try {
      ack = await rpc.prompt(message, images: images, streamingBehavior: behavior);
    } on Object {
      unawaited(results.cancel());
      rethrow;
    }
    // A command that finished locally gets no result, and starts no run.
    if (ack.agentInvoked == false) {
      unawaited(results.cancel());
      session.setPendingPrompt(null);
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
          // A session another omp process writes has nothing here to send to; its composer is the explanation and
          // the take-over, not a field that would start a second omp on the same file.
          if (session is ExternalSession) {
            return _ExternalComposer(session: session, writer: data.external, machine: machine);
          }
          // A closed session has no omp to talk to; its model, thinking level and context are gone with it. After an
          // idle exit a send opens it again.
          final closed = link is LinkClosed;
          final reopens = closed && data.idleExit != null;
          final palette = _paletteItems(session.view);
          final mention = palette.isEmpty ? _mention() : null;
          final attachments = _draft.attachments;
          final canSend = !_sending && (!closed || reopens);
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
                  )
                else if (mention case (:final models, :final error))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ModelMentionPalette(
                      models: models,
                      error: error,
                      selected: models == null ? 0 : _paletteIndex.clamp(0, models.length - 1),
                      onPick: _pickModel,
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
                        // Cmd/Ctrl+V; the context menu's Paste goes through [_contextMenu]. Cmd/Ctrl+C and X copy a
                        // model chip as the text omp would receive.
                        actions: {
                          PasteTextIntent: CallbackAction<PasteTextIntent>(
                            onInvoke: (_) {
                              unawaited(_paste());
                              return null;
                            },
                          ),
                          CopySelectionTextIntent: _CopyChips(_copyChips),
                        },
                        child: TextField(
                          key: const ValueKey('composer'),
                          controller: _draft.text,
                          focusNode: _focus,
                          // The app's body size (14 px) everywhere: on tablets and desktop windows the transcript's
                          // 15 px read too large in the input.
                          style: theme.textTheme.bodyMedium?.copyWith(height: markdownLineHeight),
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
                            final goal = closed || !showsGoal(session, data.goal) ? null : data.goal;
                            final loop = closed || !showsLoop(session, data.loop) ? null : data.loop;
                            final goalControl = goal == null
                                ? null
                                : GoalControl(session: session, goal: goal, above: _block);
                            final loopControl = loop == null
                                ? null
                                : LoopControl(session: session, loop: loop, above: _block);
                            // Phones and narrow panes: the goal and the loop get a row of their own above the toolbar,
                            // so the model and thinking buttons keep their labels.
                            final modesRow = constraints.maxWidth < 640 && (goalControl != null || loopControl != null);
                            final toolbar = Row(
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
                                                child: ThinkingPicker(
                                                  session: session,
                                                  level: data.thinking,
                                                  above: _block,
                                                ),
                                              ),
                                              LayoutId(
                                                id: _Picker.meter,
                                                child: ContextMeter(usage: data.context, cost: data.cost),
                                              ),
                                              if (!modesRow && goalControl != null)
                                                LayoutId(id: _Picker.goal, child: goalControl),
                                              if (!modesRow && loopControl != null)
                                                LayoutId(id: _Picker.loop, child: loopControl),
                                            ],
                                          ),
                                        ),
                                ),
                                IconButton(
                                  tooltip: t.composer.attach,
                                  icon: const Icon(Symbols.attach_file, size: 20),
                                  constraints: _toolbarIcon,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  onPressed: closed && !reopens ? null : () => unawaited(_attachFiles()),
                                ),
                                const SizedBox(width: 4),
                                if (_upload case (:final sent, :final total))
                                  Tooltip(
                                    message: t.composer.uploading(sent: formatBytes(sent), total: formatBytes(total)),
                                    child: SizedBox.fromSize(
                                      size: const Size.square(AppSizes.control),
                                      // A known fraction is a ring that moves only when the count does.
                                      child: Center(
                                        child: total == 0
                                            ? const ActivityMark(size: 20)
                                            : SizedBox.square(
                                                dimension: 20,
                                                child: CircularProgressIndicator(strokeWidth: 2.5, value: sent / total),
                                              ),
                                      ),
                                    ),
                                  )
                                else if (data.running && !closed && narrow) ...[
                                  IconButton(
                                    key: const ValueKey('follow-up'),
                                    tooltip: t.composer.followUp,
                                    icon: const Icon(Symbols.schedule, size: 20),
                                    constraints: _toolbarIcon,
                                    onPressed: canSend ? followUp : null,
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton.filled(
                                    key: const ValueKey('steer'),
                                    tooltip: t.composer.steer,
                                    icon: const Icon(Symbols.subdirectory_arrow_right, size: 20),
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
                                    icon: const Icon(Symbols.arrow_upward, size: 20),
                                    constraints: _toolbarIcon,
                                    onPressed: canSend ? steer : null,
                                  ),
                              ],
                            );
                            if (!modesRow) return toolbar;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  height: AppSizes.control,
                                  child: Row(
                                    children: [
                                      if (goalControl != null) Flexible(child: goalControl),
                                      if (loopControl != null) Flexible(child: loopControl),
                                    ],
                                  ),
                                ),
                                toolbar,
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

/// The field's copy and cut ([CopySelectionTextIntent.collapseSelection]): [copy] takes a selection holding a model
/// chip; any other falls through to the field's own action.
final class _CopyChips extends ContextAction<CopySelectionTextIntent> {
  _CopyChips(this.copy);

  final bool Function({required bool cut}) copy;

  @override
  Object? invoke(CopySelectionTextIntent intent, [BuildContext? context]) {
    if (copy(cut: intent.collapseSelection)) return null;
    return callingAction?.invoke(intent);
  }
}

enum _Picker { model, thinking, meter, goal, loop }

/// The toolbar's pickers side by side: the model, thinking and meter, then the goal and the loop. The goal and the
/// loop get the width their labels need first, since their state changes while a run goes and the model's name does
/// not (its tooltip keeps it); the model and thinking buttons keep their icon and chevron plus [_modelLabelFloor] of
/// the model's name. The model button gets the width its name needs next, up to what leaves the thinking button its
/// icon and chevron; the thinking label shrinks last. The rest of the row stays free, so send sits at the end.
final class _PickersLayout extends MultiChildLayoutDelegate {
  static const _modelLabelFloor = 40.0;

  @override
  void performLayout(Size size) {
    final modes = [
      for (final id in [_Picker.goal, _Picker.loop])
        if (hasChild(id)) id,
    ];
    final meter = layoutChild(_Picker.meter, BoxConstraints.loose(size));
    var room = size.width - meter.width - 2 * ToolbarButton.minWidth - _modelLabelFloor;
    final modeSizes = <(_Picker, Size)>[];
    for (final (index, id) in modes.indexed) {
      final after = (modes.length - 1 - index) * ToolbarButton.minWidth;
      final width = math.max(ToolbarButton.minWidth, room - after);
      final child = layoutChild(id, BoxConstraints.loose(Size(width, size.height)));
      modeSizes.add((id, child));
      room -= child.width;
    }
    final modesWidth = modeSizes.fold(0.0, (sum, mode) => sum + mode.$2.width);
    final model = layoutChild(
      _Picker.model,
      BoxConstraints.loose(
        Size(math.max(0, size.width - meter.width - modesWidth - ToolbarButton.minWidth), size.height),
      ),
    );
    final thinking = layoutChild(
      _Picker.thinking,
      BoxConstraints.loose(Size(math.max(0, size.width - meter.width - modesWidth - model.width), size.height)),
    );
    var x = 0.0;
    for (final (id, child) in [
      (_Picker.model, model),
      (_Picker.thinking, thinking),
      (_Picker.meter, meter),
      ...modeSizes,
    ]) {
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
  ExternalWriter? external,
  List<SlashCommand> commands,
  ModelRef? model,
  String? thinking,
  ContextUsage? context,
  double cost,
  Goal? goal,
  LoopState? loop,
  Duration? idleExit,
});

_ComposerData _select(SessionView view) => (
  running: view.run.running,
  external: view.external,
  commands: view.commands,
  model: view.config.model,
  thinking: view.config.thinkingLevel,
  context: view.contextUsage,
  cost: view.usageTotals.cost,
  goal: view.goal,
  loop: view.loop,
  idleExit: view.idleExit,
);

/// The composer of a session another omp process is writing: there is no run here to send to, so the field and
/// its toolbar are replaced by what is true about the session and the one action that is safe, the take-over.
class _ExternalComposer extends StatelessWidget {
  const _ExternalComposer({required this.session, required this.writer, required this.machine});

  final LiveSession session;

  /// The writer the last poll found; null once the other process is gone, which is when the session can be taken
  /// over safely.
  final ExternalWriter? writer;

  final Machine? machine;

  Future<void> _takeOver(BuildContext context) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final taken = await context.read<SessionsProvider>().reopen(session);
      if (identical(taken, session)) {
        messenger.showSnackBar(SnackBar(content: Text(t.composer.externalWait)));
      }
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.sessions.openFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final name = machine?.name;
    final writer = this.writer;
    final terminal = writer?.terminal;
    final busy = writer?.busy ?? false;
    final String state = switch ((writer == null, busy)) {
      (true, _) => t.composer.externalGone,
      (false, true) => name == null ? t.composer.externalRunningNoMachine : t.composer.externalRunning(machine: name),
      (false, false) => name == null ? t.composer.externalIdleNoMachine : t.composer.externalIdle(machine: name),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Symbols.terminal, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state,
                      key: const ValueKey('external-state'),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (terminal != null) t.composer.externalTerminal(terminal: terminal),
                        writer == null ? t.composer.externalBodyGone : t.composer.externalBody,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: writer == null ? t.composer.takeOver : t.composer.externalWait,
                child: TextButton(
                  key: const ValueKey('take-over'),
                  // Only once the other process is gone: taking the file over while an omp still holds it in memory
                  // would leave two writers on one session.
                  onPressed: writer == null ? () => unawaited(_takeOver(context)) : null,
                  child: Text(t.composer.takeOver),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
