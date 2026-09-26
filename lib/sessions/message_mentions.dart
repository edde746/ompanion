/// A piece of a user message: typed text, or a reference to a file. The parts' [source]s joined are the message.
sealed class MessagePart {
  const MessagePart(this.source);

  /// The characters of the message this part covers.
  final String source;
}

final class MessageText extends MessagePart {
  const MessageText(super.source);
}

/// An `@` mention omp auto-reads, or a `local://` reference such as the `local://paste-1.md` a large paste becomes.
final class MessageMention extends MessagePart {
  const MessageMention(super.source, this.path);

  /// The path as omp resolves it: host-native, `~/…`, relative to the session's directory, or a `local://` URL.
  final String path;

  /// The last segment of [path]: a file's or folder's name.
  String get name {
    final trimmed = path.replaceFirst(_trailingSeparators, '');
    if (trimmed.isEmpty) return path;
    return trimmed.substring(trimmed.lastIndexOf(_separator) + 1);
  }

  /// A `local://` or other internal URL, which is not a path on the machine.
  bool get url => _scheme.hasMatch(path);

  /// Mentions a folder: the path ends in a separator.
  bool get folder => _trailingSeparators.hasMatch(path);
}

final _separator = RegExp(r'[/\\]');
final _trailingSeparators = RegExp(r'[/\\]+$');
final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');

// omp's rules (packages/coding-agent/src/utils/file-mentions.ts, `extractFileMentions`): FILE_MENTION_REGEX, a match
// counts only at the start or after MENTION_BOUNDARY_REGEX, and an unquoted path loses leading and trailing
// punctuation. The `local://` alternative is ours; it takes no `@`, so it never swallows a mention omp would find.
final _mention = RegExp(r'''@(?:"([^"]+)"|'([^']+)'|([^\s@]+))|local://[^\s@]+''');
final _boundary = RegExp(r'''[\s(\[{<"'`]''');
final _leadingPunctuation = RegExp(r'''^[`"'(\[{<]+''');
final _trailingPunctuation = RegExp(r'''[)\]}>.,;:!?"'`]+$''');

/// [message] split into text and the mentions omp reads in it, in order.
List<MessagePart> splitMentions(String message) {
  final parts = <MessagePart>[];
  var done = 0;
  for (final match in _mention.allMatches(message)) {
    if (match.start > 0 && !_boundary.hasMatch(message[match.start - 1])) continue;
    final quoted = match[1] ?? match[2];
    final String path;
    var end = match.end;
    if (quoted != null) {
      path = quoted.trim();
    } else {
      final raw = match[3] ?? match[0]!;
      final unled = raw.replaceFirst(_leadingPunctuation, '');
      final cleaned = unled.replaceFirst(_trailingPunctuation, '');
      end -= unled.length - cleaned.length;
      path = cleaned;
    }
    if (path.isEmpty || path == 'local://') continue;
    if (match.start > done) parts.add(MessageText(message.substring(done, match.start)));
    parts.add(MessageMention(message.substring(match.start, end), path));
    done = end;
  }
  if (done < message.length) parts.add(MessageText(message.substring(done)));
  return parts;
}
