import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/composer_draft.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import 'composer_intent.dart';
import 'slash_palette.dart';

/// Image types omp accepts, by file extension.
const _imageTypes = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif', 'webp': 'image/webp'};

/// The prompt box: Enter sends (Shift+Enter is a new line); while a run streams Enter steers and Alt/Option+Enter
/// queues a follow-up. `/` opens the palette of the session's commands, `!`/`!!` run shell commands and
/// `$`/`$$` Python through the companion.
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
    _draft.text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
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
        context.read<SessionsProvider>().execRunsOf(session).start(
          session,
          ExecutionKind.bash,
          command,
          excludeFromContext: excludeFromContext,
        );
        _draft.clear();
      case RunPython(:final code, :final excludeFromContext):
        context.read<SessionsProvider>().execRunsOf(session).start(
          session,
          ExecutionKind.python,
          code,
          excludeFromContext: excludeFromContext,
        );
        _draft.clear();
      case SendPrompt(text: final message, :final behavior):
        setState(() => _sending = true);
        _draft.clear();
        try {
          await session.rpc.prompt(message, images: images, streamingBehavior: behavior);
        } on Object catch (error) {
          // Nothing was queued: give the text back.
          if (_draft.text.text.isEmpty) _draft.replace(text, images: images);
          messenger.showSnackBar(SnackBar(content: Text(t.composer.sendFailed(error: '$error'))));
        } finally {
          if (mounted) setState(() => _sending = false);
        }
    }
  }

  Future<void> _attachImages() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
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
    if (images.isNotEmpty) _draft.addImages(images);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final apple = theme.platform == TargetPlatform.macOS || theme.platform == TargetPlatform.iOS;
    return SessionViewSelector<(bool, List<SlashCommand>)>(
      session: widget.session,
      select: (view) => (view.run.running, view.commands),
      builder: (context, selected) {
        final (running, _) = selected;
        final palette = _paletteItems(widget.session.view);
        final images = _draft.images;
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
              if (images.isNotEmpty)
                SizedBox(
                  height: 72,
                  child: ListView(
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
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: t.composer.attachImage,
                      icon: const Icon(Icons.image_outlined),
                      onPressed: () => unawaited(_attachImages()),
                    ),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('composer'),
                        controller: _draft.text,
                        focusNode: _focus,
                        minLines: 1,
                        maxLines: 10,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: running ? t.composer.hintRunning : t.composer.hint,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    if (running) ...[
                      TextButton(
                        onPressed: _sending ? null : () => unawaited(_send(followUp: true)),
                        child: Text(t.composer.followUp),
                      ),
                      IconButton.filled(
                        key: const ValueKey('steer'),
                        tooltip: t.composer.steer,
                        icon: const Icon(Icons.subdirectory_arrow_right),
                        onPressed: _sending ? null : () => unawaited(_send(followUp: false)),
                      ),
                    ] else
                      IconButton.filled(
                        key: const ValueKey('send'),
                        tooltip: t.composer.send,
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _sending ? null : () => unawaited(_send(followUp: false)),
                      ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 8),
                child: Text(
                  running
                      ? t.composer.keysRunning(alt: apple ? '⌥' : 'Alt')
                      : t.composer.keys,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

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
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Image.memory(_bytes, width: 64, height: 64, fit: BoxFit.cover),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton.filledTonal(
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
