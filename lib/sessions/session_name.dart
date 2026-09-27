import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';

import '../i18n/strings.g.dart';
import 'message_mentions.dart';

/// [sessionName] of a session open on this device: its live title, else the first message of its file in the
/// machine's listing ([summary]), else the first one in its transcript.
String liveSessionName(Translations t, SessionView view, SessionSummary? summary) =>
    sessionName(t, title: view.config.sessionName, firstMessage: summary?.firstMessage ?? firstUserMessage(view));

/// The name a session goes by in the sidebar and the chat header: omp's title, else its first user message on one
/// line without its file mentions, a tagged model by its name (the first file's name when it has nothing else), else
/// "New session".
String sessionName(Translations t, {String? title, String? firstMessage}) {
  if (title != null && title.trim().isNotEmpty) return title.trim();
  final cut = firstMessage?.replaceFirstMapped(_cutQuotedMention, (match) => match[1]!).replaceFirst(_cutModelTag, '');
  final parts = splitMentions(cut ?? '');
  final text = [
    for (final part in parts)
      switch (part) {
        MessageText(:final source) => source,
        MessageModel(:final name) => name,
        MessageMention() => ' ',
      },
  ].join().replaceAll(_whitespace, ' ').trim();
  if (text.isNotEmpty) return text;
  return parts.whereType<MessageMention>().firstOrNull?.name ?? t.sessions.untitled;
}

final _whitespace = RegExp(r'\s+');

/// A quoted mention the machine's listing cut off at [firstMessageLength]: what is left of its path is no name.
final _cutQuotedMention = RegExp(r'''(^|[\s(\[{<"'`])@(?:"[^"]*|'[^']*)$''');

/// A model tag the listing cut off: no name to show.
final _cutModelTag = RegExp(r'<model [^>]*$');

/// Text of the first message the user typed in [view]'s transcript; before the machine's listing has the session
/// file, this is where a new session's name comes from.
String? firstUserMessage(SessionView view) {
  for (final item in view.transcript) {
    if (item is UserItem && !item.synthetic && item.attribution != 'agent') {
      final text = item.text;
      if (text.trim().isNotEmpty) return text;
    }
  }
  return null;
}
