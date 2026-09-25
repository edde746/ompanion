import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/sessions_provider.dart';
import '../shell/layout.dart';
import 'ask_dialog.dart';
import 'request_frame.dart';

/// Shows [session]'s open requests one at a time: dialogs on wide layouts, bottom sheets on phones.
///
/// A dialog closes when its request leaves the view: answered here, answered by another device, cancelled by
/// omp, settled by the companion, or timed out. Closing one without answering hides it; hidden requests stay
/// listed in a bar at the bottom of [child] until answered. `set_editor_text` fills the composer instead.
class RequestHost extends StatefulWidget {
  const RequestHost({super.key, required this.session, required this.child});

  final LiveSession session;
  final Widget child;

  @override
  State<RequestHost> createState() => _RequestHostState();
}

class _RequestHostState extends State<RequestHost> {
  StreamSubscription<SessionView>? _subscription;
  final Set<String> _hidden = {};
  final Map<String, Timer> _timeouts = {};
  final Map<String, DateTime> _deadlines = {};
  Route<void>? _route;
  String? _showing;
  List<UiRequest>? _lastRequests;
  late NavigatorState _navigator;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context, rootNavigator: true);
  }

  @override
  void didUpdateWidget(RequestHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _reset();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _subscribe() {
    _subscription = widget.session.views.listen(_onView);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onView(widget.session.view);
    });
  }

  /// Forgets this session's dialogs; an open one goes away with it.
  void _reset() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    for (final timer in _timeouts.values) {
      timer.cancel();
    }
    _timeouts.clear();
    _deadlines.clear();
    _hidden.clear();
    _lastRequests = null;
    final route = _route;
    _route = null;
    _showing = null;
    if (route == null) return;
    // Called while the tree builds or unmounts; the navigator may only change afterwards.
    final navigator = _navigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) navigator.removeRoute(route);
    });
  }

  void _onView(SessionView view) {
    // The reducer keeps an unchanged request list identical; most views are streamed tokens.
    if (!mounted || identical(view.requests, _lastRequests)) return;
    _lastRequests = view.requests;
    final open = {for (final request in view.requests) request.id};
    _hidden.removeWhere((id) => !open.contains(id));
    for (final id in _timeouts.keys.where((id) => !open.contains(id)).toList()) {
      _timeouts.remove(id)!.cancel();
      _deadlines.remove(id);
    }
    final editorTexts = <EditorTextRequest>[];
    for (final request in view.requests) {
      switch (request) {
        case EditorTextRequest():
          editorTexts.add(request);
        case SelectRequest(:final id, timeout: final ms?) ||
            ConfirmRequest(:final id, timeout: final ms?) ||
            InputRequest(:final id, timeout: final ms?):
          // omp resolves a timed-out dialog by itself and sends no frame.
          _timeouts.putIfAbsent(id, () {
            _deadlines[id] = DateTime.now().add(Duration(milliseconds: ms));
            return Timer(Duration(milliseconds: ms), () => widget.session.dismissRequest(id));
          });
        case _:
      }
    }
    setState(() {});
    for (final request in editorTexts) {
      context.read<SessionsProvider>().setDraft(widget.session, request.text);
      widget.session.dismissRequest(request.id);
    }
    _pump();
  }

  void _pump() {
    if (_showing != null || !mounted) return;
    final request = _nextRequest(widget.session.view);
    if (request == null) return;
    unawaited(_show(request));
  }

  UiRequest? _nextRequest(SessionView view) {
    for (final request in view.requests) {
      if (request is EditorTextRequest || _hidden.contains(request.id)) continue;
      return request;
    }
    return null;
  }

  Future<void> _show(UiRequest request) async {
    final session = widget.session;
    _showing = request.id;
    final deadline = _deadlines[request.id];
    Widget content(BuildContext context, bool sheet) => _ClosesWhenSettled(
      session: session,
      requestId: request.id,
      child: RequestContent(session: session, request: request, deadline: deadline, sheet: sheet),
    );
    final Route<void> route = isCompact(context)
        ? ModalBottomSheetRoute<void>(
            builder: (context) => content(context, true),
            isScrollControlled: true,
            showDragHandle: true,
            useSafeArea: true,
          )
        : DialogRoute<void>(context: context, builder: (context) => content(context, false));
    _route = route;
    await _navigator.push(route);
    if (!identical(_route, route)) return; // the session changed meanwhile
    _route = null;
    _showing = null;
    if (!mounted) return;
    if (session.view.requests.any((open) => open.id == request.id)) {
      setState(() => _hidden.add(request.id));
    }
    _pump();
    // Back to typing once no dialog is left, as the TUI returns to its editor.
    if (_showing == null) context.read<SessionsProvider>().draftOf(session).requestFocus();
  }

  void _unhide(String id) {
    setState(() => _hidden.remove(id));
    _pump();
  }

  @override
  Widget build(BuildContext context) {
    final hidden = [
      for (final request in widget.session.view.requests)
        if (_hidden.contains(request.id)) request,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: widget.child),
        for (final request in hidden) _HiddenRequestBar(request: request, onShow: () => _unhide(request.id)),
      ],
    );
  }
}

class _HiddenRequestBar extends StatelessWidget {
  const _HiddenRequestBar({required this.request, required this.onShow});

  final UiRequest request;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.help_outline, color: scheme.onTertiaryContainer),
        title: Text(
          t.requests.waiting(title: requestTitle(t, request)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        trailing: FilledButton.tonal(onPressed: onShow, child: Text(t.requests.answer)),
        onTap: onShow,
      ),
    );
  }
}

/// A one-line title for [request], for the hidden-request bar and the sidebar.
String requestTitle(Translations t, UiRequest request) => switch (request) {
  ApprovalRequest(:final toolName) => t.requests.approvalTitle(tool: toolName),
  SelectRequest(:final title) || ConfirmRequest(:final title) || InputRequest(:final title) => title,
  EditorRequest(:final title) => title,
  EditorTextRequest() => t.requests.editorText,
  OpenUrlRequest() => t.requests.openUrlTitle,
  CompanionRequest(method: 'ask') => t.ask.title,
  CompanionRequest(:final method) => method,
};

/// Closes the surrounding route once request [requestId] is no longer open in [session]'s view.
class _ClosesWhenSettled extends StatefulWidget {
  const _ClosesWhenSettled({required this.session, required this.requestId, required this.child});

  final LiveSession session;
  final String requestId;
  final Widget child;

  @override
  State<_ClosesWhenSettled> createState() => _ClosesWhenSettledState();
}

class _ClosesWhenSettledState extends State<_ClosesWhenSettled> {
  late final StreamSubscription<SessionView> _subscription;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.session.views.listen(_check);
    // The request may have settled between the host picking it and this route building.
    _check(widget.session.view);
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  void _check(SessionView view) {
    if (_closing || view.requests.any((request) => request.id == widget.requestId)) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The body of one request's dialog or sheet. Answers go out through [session]; the dialog then closes
/// because the request leaves the view.
class RequestContent extends StatefulWidget {
  const RequestContent({
    super.key,
    required this.session,
    required this.request,
    required this.sheet,
    this.deadline,
  });

  final LiveSession session;
  final UiRequest request;

  /// Render as a bottom sheet (phones) rather than a dialog.
  final bool sheet;

  /// When omp stops waiting for the answer.
  final DateTime? deadline;

  @override
  State<RequestContent> createState() => _RequestContentState();
}

class _RequestContentState extends State<RequestContent> {
  late final TextEditingController _text = TextEditingController(
    text: switch (widget.request) {
      EditorRequest(:final prefill?) => prefill,
      _ => '',
    },
  );
  bool _busy = false;
  String? _error;
  String? _forwardNote;

  @override
  void initState() {
    super.initState();
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

  void _hide() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final request = widget.request;
    if (request case CompanionRequest(method: 'ask', :final params)) {
      return AskContent(
        params: params,
        sheet: widget.sheet,
        busy: _busy,
        error: _error,
        onSubmit: (answer) => _answer(() => widget.session.companion.respond(request.id, answer)),
        onCancel: () => _answer(() => widget.session.companion.cancel(request.id)),
        onHide: _hide,
      );
    }
    final hide = TextButton(onPressed: _busy ? null : _hide, child: Text(t.requests.hide));
    final (String title, Widget body, List<Widget> actions) = switch (request) {
      ApprovalRequest() => (
        t.requests.approvalTitle(tool: request.toolName),
        _ApprovalBody(request: request, view: widget.session.view),
        [
          hide,
          for (final option in request.options)
            _isApprove(option)
                ? FilledButton(onPressed: _busy ? null : () => _respond(value: option), child: Text(option))
                : OutlinedButton(onPressed: _busy ? null : () => _respond(value: option), child: Text(option)),
        ],
      ),
      SelectRequest() => (
        request.title,
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, option) in request.options.indexed)
              ListTile(
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
        [hide, TextButton(onPressed: _busy ? null : () => _respond(cancelled: true), child: Text(t.common.cancel))],
      ),
      ConfirmRequest() => (
        request.title,
        Text(request.message),
        [
          hide,
          OutlinedButton(onPressed: _busy ? null : () => _respond(confirmed: false), child: Text(t.requests.no)),
          FilledButton(onPressed: _busy ? null : () => _respond(confirmed: true), child: Text(t.requests.yes)),
        ],
      ),
      InputRequest() => (
        request.title,
        TextField(
          controller: _text,
          autofocus: true,
          decoration: InputDecoration(hintText: request.placeholder),
          onSubmitted: _busy ? null : (value) => _respond(value: value),
        ),
        [
          hide,
          TextButton(onPressed: _busy ? null : () => _respond(cancelled: true), child: Text(t.common.cancel)),
          FilledButton(onPressed: _busy ? null : () => _respond(value: _text.text), child: Text(t.requests.submit)),
        ],
      ),
      EditorRequest() => (
        request.title,
        TextField(
          controller: _text,
          autofocus: true,
          minLines: 6,
          maxLines: 16,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        [
          hide,
          TextButton(onPressed: _busy ? null : () => _respond(cancelled: true), child: Text(t.common.cancel)),
          FilledButton(onPressed: _busy ? null : () => _respond(value: _text.text), child: Text(t.requests.submit)),
        ],
      ),
      OpenUrlRequest() => (
        t.requests.openUrlTitle,
        _OpenUrlBody(request: request, forwardNote: _forwardNote),
        [
          TextButton(
            onPressed: () => widget.session.dismissRequest(request.id),
            child: Text(t.common.close),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: Text(t.requests.openInBrowser),
            onPressed: () => unawaited(launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication)),
          ),
        ],
      ),
      CompanionRequest(:final method, :final params) => (
        t.requests.unsupportedTitle,
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.requests.unsupportedBody(method: method)),
            const SizedBox(height: 8),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(params),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        [
          hide,
          TextButton(
            onPressed: _busy ? null : () => _answer(() => widget.session.companion.cancel(request.id)),
            child: Text(t.common.cancel),
          ),
        ],
      ),
      EditorTextRequest() => throw StateError('set_editor_text fills the composer; it has no dialog'),
    };
    return RequestFrame(
      sheet: widget.sheet,
      title: title,
      deadline: widget.deadline,
      error: _error,
      body: body,
      actions: actions,
    );
  }

  static bool _isApprove(String option) => option.toLowerCase().startsWith('approve') || option.toLowerCase() == 'allow';
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
    final intent = call?.intent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (intent != null) ...[Text(intent, style: theme.textTheme.titleSmall), const SizedBox(height: 8)],
        if (command != null || shownArgs != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: SelectableText(
              command ?? const JsonEncoder.withIndent('  ').convert(shownArgs),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        for (final line in request.details)
          if (line.trim().isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(line)),
      ],
    );
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
            Expanded(
              child: SelectableText(
                request.url,
                maxLines: 3,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              tooltip: t.common.copy,
              icon: const Icon(Icons.copy),
              onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: request.url))),
            ),
          ],
        ),
        if (note != null) ...[const SizedBox(height: 12), Text(note, style: theme.textTheme.bodySmall)],
      ],
    );
  }
}
