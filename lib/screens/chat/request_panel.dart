import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/sessions_provider.dart';
import '../external_links.dart';
import 'ask.dart';
import 'ask_form.dart';
import 'request_frame.dart';
import 'transcript/code_style.dart';

/// [session]'s open requests, inline above the composer: one in full, with its position, previous and next when
/// several are open. Nothing here is modal; the transcript, the composer and the rest of the app stay usable.
///
/// A request leaves the panel when it leaves the view: answered here, answered by another device, cancelled by omp,
/// settled by the companion, or timed out. `set_editor_text` fills the composer instead.
class RequestPanel extends StatefulWidget {
  const RequestPanel({super.key, required this.session});

  final LiveSession session;

  @override
  State<RequestPanel> createState() => _RequestPanelState();
}

class _RequestPanelState extends State<RequestPanel> {
  StreamSubscription<SessionView>? _subscription;
  List<UiRequest>? _lastRequests;
  List<UiRequest> _requests = const [];

  /// What the user entered into each open request, so one navigated away from comes back as it was left.
  final Map<String, RequestDraft> _drafts = {};

  /// The shown request; when it settles, the one that takes its place is shown.
  String? _shownId;
  int _shownIndex = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(RequestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _lastRequests = null;
      _requests = const [];
      _drafts.clear();
      _shownId = null;
      _shownIndex = 0;
      _subscribe();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _subscribe() {
    _subscription = widget.session.views.listen(_onView);
    // `set_editor_text` fills the composer, which may be building right now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onView(widget.session.view);
    });
  }

  void _onView(SessionView view) {
    // The reducer keeps an unchanged request list identical; most views are streamed tokens.
    if (!mounted || identical(view.requests, _lastRequests)) return;
    _lastRequests = view.requests;
    final shown = [
      for (final request in view.requests)
        if (request is! EditorTextRequest) request,
    ];
    final open = {for (final request in shown) request.id};
    _drafts.removeWhere((id, _) => !open.contains(id));
    final hadRequests = _requests.isNotEmpty;
    setState(() {
      _requests = shown;
      final index = shown.indexWhere((request) => request.id == _shownId);
      if (index >= 0) {
        _shownIndex = index;
      } else if (shown.isNotEmpty) {
        _shownIndex = _shownIndex.clamp(0, shown.length - 1);
        _shownId = shown[_shownIndex].id;
      } else {
        _shownId = null;
        _shownIndex = 0;
      }
    });
    final sessions = context.read<SessionsProvider>();
    for (final request in view.requests.whereType<EditorTextRequest>()) {
      sessions.setDraft(widget.session, request.text);
      widget.session.dismissRequest(request.id);
    }
    // Back to typing once no request is left, as the TUI returns to its editor.
    if (hadRequests && shown.isEmpty) sessions.draftOf(widget.session).requestFocus();
  }

  void _show(int index) => setState(() {
    _shownIndex = index;
    _shownId = _requests[index].id;
  });

  @override
  Widget build(BuildContext context) {
    final requests = _requests;
    if (requests.isEmpty) return const SizedBox.shrink();
    final index = _shownIndex.clamp(0, requests.length - 1);
    final request = requests[index];
    final session = widget.session;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: RequestContent(
        key: ValueKey(request.id),
        session: session,
        request: request,
        draft: _drafts.putIfAbsent(request.id, () => RequestDraft(request)),
        deadline: context.read<SessionsProvider>().deadlinesOf(session).of(request.id),
        navigation: requests.length < 2
            ? null
            : _Navigation(
                index: index,
                count: requests.length,
                onPrevious: index == 0 ? null : () => _show(index - 1),
                onNext: index == requests.length - 1 ? null : () => _show(index + 1),
              ),
      ),
    );
  }
}

class _Navigation extends StatelessWidget {
  const _Navigation({required this.index, required this.count, required this.onPrevious, required this.onNext});

  final int index;
  final int count;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('request-previous'),
          tooltip: t.requests.previous,
          icon: const Icon(Icons.chevron_left),
          onPressed: onPrevious,
        ),
        Text(
          t.requests.position(index: index + 1, count: count),
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        IconButton(
          key: const ValueKey('request-next'),
          tooltip: t.requests.next,
          icon: const Icon(Icons.chevron_right),
          onPressed: onNext,
        ),
      ],
    );
  }
}

/// A one-line title for [request].
String requestTitle(Translations t, UiRequest request) => switch (request) {
  ApprovalRequest(:final toolName) => t.requests.approvalTitle(tool: toolName),
  SelectRequest(:final title) || ConfirmRequest(:final title) || InputRequest(:final title) => title,
  EditorRequest(:final title) => title,
  EditorTextRequest() => t.requests.editorText,
  OpenUrlRequest() => t.requests.openUrlTitle,
  CompanionRequest(method: 'ask') => t.ask.title,
  CompanionRequest(:final method) => method,
};

/// What the user entered into one request so far. [RequestPanel] keeps it while another request is shown.
final class RequestDraft {
  RequestDraft(UiRequest request)
    : text = switch (request) {
        EditorRequest(:final prefill?) => prefill,
        _ => '',
      };

  /// The input's or the editor's text.
  String text;

  /// The `ask` form's answers, one per question; filled when the form first shows.
  final List<AskDraft> ask = [];
}

/// One request, inline. Answers go out through [session]; the request then leaves the view and the panel.
class RequestContent extends StatefulWidget {
  const RequestContent({
    super.key,
    required this.session,
    required this.request,
    required this.draft,
    this.deadline,
    this.navigation,
  });

  final LiveSession session;
  final UiRequest request;

  /// What the user entered so far; edits land here.
  final RequestDraft draft;

  /// When omp stops waiting for the answer.
  final DateTime? deadline;
  final Widget? navigation;

  @override
  State<RequestContent> createState() => _RequestContentState();
}

class _RequestContentState extends State<RequestContent> {
  late final TextEditingController _text = TextEditingController(text: widget.draft.text);
  bool _busy = false;
  String? _error;
  String? _forwardNote;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => widget.draft.text = _text.text);
    if (widget.request case OpenUrlRequest(:final url)) {
      // _forward reads translations, which initState may not.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_forward(url));
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _forward(String url) async {
    final sessions = context.read<SessionsProvider>();
    final machine = sessions.machineOf(widget.session);
    if (machine == null) return;
    final t = context.t;
    try {
      final forward = await sessions.forwardOAuthCallback(machine, url);
      if (forward != null && mounted) setState(() => _forwardNote = t.requests.forwarding(port: forward.localPort));
    } on Object catch (error) {
      if (mounted) setState(() => _error = t.requests.forwardFailed(error: '$error'));
    }
  }

  /// Sends an answer, then closes the request in this device's view.
  Future<void> _answer(Future<void> Function() send) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await send();
      widget.session.dismissRequest(widget.request.id);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.t.requests.answerFailed(error: '$error');
        });
      }
    }
  }

  Future<void> _respond({String? value, bool? confirmed, bool cancelled = false}) => _answer(
    () => widget.session.rpc.respondToUi(widget.request.id, value: value, confirmed: confirmed, cancelled: cancelled),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final request = widget.request;
    if (request case CompanionRequest(method: 'ask', :final params)) {
      return AskForm(
        params: params,
        drafts: widget.draft.ask,
        busy: _busy,
        error: _error,
        navigation: widget.navigation,
        onSubmit: (answer) => _answer(() => widget.session.companion.respond(request.id, answer)),
        onCancel: () => _answer(() => widget.session.companion.cancel(request.id)),
      );
    }
    final cancel = TextButton(onPressed: _busy ? null : () => _respond(cancelled: true), child: Text(t.common.cancel));
    final submit = FilledButton(
      onPressed: _busy ? null : () => _respond(value: _text.text),
      child: Text(t.requests.submit),
    );
    final (Widget body, List<Widget> actions) = switch (request) {
      ApprovalRequest() => (
        _ApprovalBody(request: request, view: widget.session.view),
        [
          for (final option in request.options)
            _isApprove(option)
                ? FilledButton(
                    onPressed: _busy ? null : () => _respond(value: option),
                    child: Text(option),
                  )
                : FilledButton.tonal(
                    onPressed: _busy ? null : () => _respond(value: option),
                    child: Text(option),
                  ),
        ],
      ),
      SelectRequest() => (
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, option) in request.options.indexed)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppSizes.radius))),
                title: Text(option),
                subtitle: switch (request.descriptions.elementAtOrNull(index)) {
                  final description? => Text(description),
                  null => null,
                },
                enabled: !_busy,
                onTap: () => _respond(value: option),
              ),
          ],
        ),
        [cancel],
      ),
      ConfirmRequest() => (
        Text(request.message),
        [
          FilledButton.tonal(onPressed: _busy ? null : () => _respond(confirmed: false), child: Text(t.requests.no)),
          FilledButton(onPressed: _busy ? null : () => _respond(confirmed: true), child: Text(t.requests.yes)),
        ],
      ),
      InputRequest() => (
        TextField(
          controller: _text,
          decoration: InputDecoration(hintText: request.placeholder),
          onSubmitted: _busy ? null : (value) => _respond(value: value),
        ),
        [cancel, submit],
      ),
      EditorRequest() => (
        TextField(
          controller: _text,
          minLines: 6,
          maxLines: 16,
          keyboardType: TextInputType.multiline,
          style: codeTextStyle(theme),
        ),
        [cancel, submit],
      ),
      OpenUrlRequest() => (
        _OpenUrlBody(request: request, forwardNote: _forwardNote),
        [
          TextButton(onPressed: () => widget.session.dismissRequest(request.id), child: Text(t.common.close)),
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(t.requests.openInBrowser),
            onPressed: switch (Uri.tryParse(request.url)) {
              final uri? when isWebLink(uri) => () => unawaited(openWebLink(uri)),
              _ => null,
            },
          ),
        ],
      ),
      CompanionRequest(:final method, :final params) => (
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.requests.unsupportedBody(method: method)),
            const SizedBox(height: AppSizes.gap),
            SelectableText(const JsonEncoder.withIndent('  ').convert(params), style: codeTextStyle(theme)),
          ],
        ),
        [
          TextButton(
            onPressed: _busy ? null : () => _answer(() => widget.session.companion.cancel(request.id)),
            child: Text(t.common.cancel),
          ),
        ],
      ),
      EditorTextRequest() => throw StateError('set_editor_text fills the composer; it is never shown'),
    };
    return RequestFrame(
      title: switch (request) {
        CompanionRequest(method: != 'ask') => t.requests.unsupportedTitle,
        _ => requestTitle(t, request),
      },
      navigation: widget.navigation,
      deadline: widget.deadline,
      error: _error,
      body: body,
      actions: actions,
    );
  }

  static bool _isApprove(String option) =>
      option.toLowerCase().startsWith('approve') || option.toLowerCase() == 'allow';
}

class _ApprovalBody extends StatelessWidget {
  const _ApprovalBody({required this.request, required this.view});

  final ApprovalRequest request;
  final SessionView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = switch (request.toolCallId) {
      final id? => view.toolResults[id],
      null => null,
    };
    final args = call?.args;
    final command = args is Map<String, Object?> && args['command'] is String ? args['command']! as String : null;
    // `i` is the intent every built-in tool takes; it shows as the heading instead.
    final shownArgs = args is Map<String, Object?> ? (Map.of(args)..remove('i')) : args;
    final shown = command ?? (shownArgs == null ? null : const JsonEncoder.withIndent('  ').convert(shownArgs));
    final intent = call?.intent;
    // omp's detail lines repeat the arguments ("Command: ls -la"); the block above shows those already.
    final argValues = {
      if (args is Map<String, Object?>)
        for (final value in args.values)
          if (value is String) value.trim(),
    };
    final details = [
      for (final line in request.details)
        if (line.trim().isNotEmpty && !_repeatsArgument(line, argValues)) line,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (intent != null) ...[
          Text(intent, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: AppSizes.gap),
        ],
        if (shown != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
            ),
            child: SelectableText(shown, style: codeTextStyle(theme)),
          ),
        for (final line in details)
          Padding(
            padding: const EdgeInsets.only(top: AppSizes.gap),
            child: Text(line),
          ),
      ],
    );
  }

  /// True when [line] is `Label: value` (or just `value`) for one of the call's string arguments.
  static bool _repeatsArgument(String line, Set<String> values) {
    final trimmed = line.trim();
    if (values.contains(trimmed)) return true;
    final colon = trimmed.indexOf(': ');
    return colon > 0 && values.contains(trimmed.substring(colon + 2).trim());
  }
}

class _OpenUrlBody extends StatelessWidget {
  const _OpenUrlBody({required this.request, required this.forwardNote});

  final OpenUrlRequest request;
  final String? forwardNote;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final instructions = request.instructions;
    final note = forwardNote;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (instructions != null) ...[Text(instructions), const SizedBox(height: 12)],
        Row(
          children: [
            Expanded(child: SelectableText(request.url, maxLines: 3, style: codeTextStyle(theme))),
            IconButton(
              tooltip: t.common.copy,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: request.url))),
            ),
          ],
        ),
        if (Uri.tryParse(request.url) case final uri when uri == null || !isWebLink(uri)) ...[
          const SizedBox(height: 12),
          Text(t.requests.notWebLink, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error)),
        ],
        if (note != null) ...[
          const SizedBox(height: 12),
          Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}
