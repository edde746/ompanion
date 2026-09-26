import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import 'chat/transcript/code_style.dart';

/// Whether [uri] is a web page, the only kind of link an OAuth `open_url` from a machine opens.
bool isWebLink(Uri uri) => uri.isScheme('http') || uri.isScheme('https');

/// Whether [uri] opens without asking: a web page or a mail draft. Any other scheme starts whatever handler this
/// device registered for it (`ms-msdt:`, `smb:`, an app's own scheme), and link text in model output can hide it.
bool opensWithoutAsking(Uri uri) => isWebLink(uri) || uri.isScheme('mailto');

/// Opens [uri] from the transcript or a terminal with the system. A link [opensWithoutAsking] refuses shows its full
/// URL first and opens only when the user confirms.
Future<void> openExternalLink(BuildContext context, Uri uri) async {
  if (!opensWithoutAsking(uri)) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmLinkDialog(uri: uri),
    );
    if (confirmed != true) return;
  }
  await _launch(uri);
}

/// Opens an OAuth link from a machine in the browser; anything but [isWebLink] stays closed. Returns whether it
/// was a web link.
Future<bool> openWebLink(Uri uri) async {
  if (!isWebLink(uri)) return false;
  await _launch(uri);
  return true;
}

Future<void> _launch(Uri uri) async {
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) appLogger.w('No application opens $uri');
}

class _ConfirmLinkDialog extends StatelessWidget {
  const _ConfirmLinkDialog({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_outlined),
      iconColor: theme.colorScheme.error,
      title: Text(t.links.confirmTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.links.confirmBody(scheme: uri.scheme)),
          const SizedBox(height: 12),
          SelectableText('$uri', style: codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.links.open)),
      ],
    );
  }
}
