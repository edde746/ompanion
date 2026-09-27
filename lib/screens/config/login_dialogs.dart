import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../app/theme.dart';
import '../../config/config_target.dart';
import '../../config/login.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../../widgets/activity_mark.dart';
import '../chat/transcript/code_style.dart';
import '../external_links.dart';
import 'config_widgets.dart';

/// Forwards the loopback callback ports of an OAuth link from this device to a remote machine, so the
/// browser's redirect reaches omp's callback server there. Nothing to do for this computer.
final class _CallbackForwards {
  _CallbackForwards(this.target);

  final ConfigTarget target;
  final Map<int, LocalForward> _forwards = {};
  final Map<int, Object> failures = {};

  Future<void> forward(Set<int> ports) async {
    if (target.isThisComputer) return;
    for (final port in ports) {
      if (_forwards.containsKey(port) || failures.containsKey(port)) continue;
      try {
        _forwards[port] = await target.runtime.forwardLocal(port, localPort: port);
      } on Object catch (error) {
        // The port is busy here: the browser cannot reach omp; the pasted redirect URL still works.
        failures[port] = error;
        appLogger.w('forwarding OAuth callback port $port failed', error: error);
      }
    }
  }

  List<int> get active => _forwards.keys.toList()..sort();

  Future<void> close() async {
    for (final forward in _forwards.values) {
      await forward.close();
    }
    _forwards.clear();
  }
}

/// Opens omp's authorization link in the browser when it is a web link; [_LinkBlock] says why when it is not.
Future<void> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !await openWebLink(uri)) appLogger.w('not opening a login link that is not a web link: $url');
}

/// RPC `login` in the control process: omp sends `open_url` with the authorization link, then `input` for a
/// pasted code or redirect URL when the provider needs one; the call completes once the credential is
/// stored.
class RpcLoginDialog extends StatefulWidget {
  const RpcLoginDialog({
    super.key,
    required this.target,
    required this.control,
    required this.providerId,
    required this.providerName,
  });

  final ConfigTarget target;
  final LiveSession control;
  final String providerId;
  final String providerName;

  @override
  State<RpcLoginDialog> createState() => _RpcLoginDialogState();
}

class _RpcLoginDialogState extends State<RpcLoginDialog> {
  late final _forwards = _CallbackForwards(widget.target);
  late final int _firstNotice = widget.control.view.nextSeq;
  StreamSubscription<SessionView>? _views;
  OpenUrlRequest? _link;
  final _handled = <String>{};
  final _input = TextEditingController();
  bool _done = false;
  bool _closing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _views = widget.control.views.listen((_) => _onView());
    // A link omp sent before the dialog opened; handled after the first frame, since handling it rebuilds.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onView());
    unawaited(
      widget.control.rpc
          .login(widget.providerId)
          .then(
            (_) {
              if (mounted) setState(() => _done = true);
            },
            onError: (Object error) {
              if (mounted) setState(() => _error = error);
            },
          ),
    );
  }

  @override
  void dispose() {
    unawaited(_views?.cancel());
    unawaited(_forwards.close());
    _input.dispose();
    super.dispose();
  }

  void _onView() {
    for (final request in widget.control.view.requests) {
      if (request is! OpenUrlRequest || !_handled.add(request.id)) continue;
      // One-shot: the dialog keeps the link, the view drops the request.
      widget.control.dismissRequest(request.id);
      unawaited(_openLink(request));
    }
    if (mounted) setState(() {});
  }

  Future<void> _openLink(OpenUrlRequest request) async {
    await _forwards.forward(loopbackPorts(request.url, request.launchUrl));
    if (!mounted) return;
    setState(() => _link = request);
    await _openInBrowser(request.url);
  }

  UiRequest? get _question => widget.control.view.requests
      .where((request) => request is InputRequest || request is SelectRequest || request is ConfirmRequest)
      .firstOrNull;

  Future<void> _answer(UiRequest request, {String? value, bool? confirmed}) async {
    await runReporting(context, () async {
      await widget.control.rpc.respondToUi(request.id, value: value, confirmed: confirmed);
      widget.control.dismissRequest(request.id);
      _input.clear();
    }, secret: true);
  }

  /// Also runs for system back and Esc, which would otherwise close the dialog and leave omp's `login` blocking
  /// the control process's command queue.
  Future<void> _cancel() async {
    if (_closing) return;
    _closing = true;
    final question = _question;
    if (!_done && _error == null) {
      await runReporting(context, () async {
        if (question != null) {
          await widget.control.rpc.respondToUi(question.id, cancelled: true);
          widget.control.dismissRequest(question.id);
        }
        // Measured with openai-codex: after its paste prompt is cancelled omp still waits for the browser's
        // callback, RPC has no command to stop a login, and the control process stops answering prompts. End it;
        // the next page load starts a new one.
        await widget.control.detach();
      });
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final question = _question;
    final notices = [
      for (final notice in widget.control.view.notices)
        if (notice.seq >= _firstNotice) ?_noticeText(notice),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: AlertDialog(
        title: Text(t.config.accounts.loginTitle(provider: widget.providerName)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_link == null && !_done && _error == null)
                  Row(
                    children: [
                      const ActivityMark(size: 18),
                      const SizedBox(width: 12),
                      Expanded(child: Text(t.config.accounts.waitingForLink)),
                    ],
                  ),
                if (_link case final link?) _LinkBlock(link: link, forwards: _forwards),
                for (final notice in notices)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(notice, style: theme.textTheme.bodySmall),
                  ),
                if (question != null && !_done && _error == null) ...[
                  const SizedBox(height: 16),
                  _Question(request: question, controller: _input, onAnswer: _answer),
                ],
                if (_done)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(t.config.accounts.loggedIn, style: TextStyle(color: AppColors.of(context).success)),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SelectableText('$_error', style: TextStyle(color: AppColors.of(context).error)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (_done || _error != null)
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close))
          else
            TextButton(onPressed: _cancel, child: Text(t.common.cancel)),
        ],
      ),
    );
  }
}

String? _noticeText(Notice notice) => switch (notice) {
  MessageNotice(:final message) => message,
  _ => null,
};

/// The authorization link, the forwarded callback ports, and buttons to open or copy it.
class _LinkBlock extends StatelessWidget {
  const _LinkBlock({required this.link, required this.forwards});

  final OpenUrlRequest link;
  final _CallbackForwards forwards;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final copyTarget = link.launchUrl ?? link.url;
    final uri = Uri.tryParse(link.url);
    final web = uri != null && isWebLink(uri);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.config.accounts.openLink),
        const SizedBox(height: 8),
        // One line: the link is long and opaque; Copy link takes all of it.
        Text(
          link.url,
          key: const ValueKey('login-link'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: codeTextStyle(theme)
              .copyWith(fontSize: theme.textTheme.bodySmall?.fontSize, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: web ? () => _openInBrowser(link.url) : null,
              icon: const Icon(Symbols.open_in_browser),
              label: Text(t.config.accounts.openBrowser),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Clipboard.setData(ClipboardData(text: copyTarget)),
              icon: const Icon(Symbols.content_copy),
              label: Text(t.config.accounts.copyLink),
            ),
          ],
        ),
        if (!web)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.requests.notWebLink,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error),
            ),
          ),
        if (link.instructions case final text?) Padding(padding: const EdgeInsets.only(top: 8), child: Text(text)),
        if (forwards.active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.config.accounts.forwarding(ports: forwards.active.join(', ')),
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final MapEntry(key: port, value: error) in forwards.failures.entries)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.config.accounts.forwardFailed(port: '$port', error: '$error'),
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error),
            ),
          ),
      ],
    );
  }
}

/// A question omp asks during login: a code or URL to paste, a choice, or a yes/no.
class _Question extends StatelessWidget {
  const _Question({required this.request, required this.controller, required this.onAnswer});

  final UiRequest request;
  final TextEditingController controller;
  final Future<void> Function(UiRequest request, {String? value, bool? confirmed}) onAnswer;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    switch (request) {
      case InputRequest(:final title, :final placeholder):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(hintText: placeholder),
                    onSubmitted: (text) => onAnswer(request, value: text),
                  ),
                ),
                const SizedBox(width: AppSizes.gap),
                FilledButton(
                  onPressed: () => onAnswer(request, value: controller.text),
                  child: Text(t.config.accounts.submit),
                ),
              ],
            ),
          ],
        );
      case SelectRequest(:final title, :final options):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  FilledButton.tonal(
                    onPressed: () => onAnswer(request, value: option),
                    child: Text(option),
                  ),
              ],
            ),
          ],
        );
      case ConfirmRequest(:final title, :final message):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(message),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: () => onAnswer(request, confirmed: true), child: Text(t.config.accounts.yes)),
                FilledButton.tonal(
                  onPressed: () => onAnswer(request, confirmed: false),
                  child: Text(t.config.accounts.no),
                ),
              ],
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
