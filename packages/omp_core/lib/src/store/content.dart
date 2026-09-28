import '../rpc/json_fields.dart';

/// One block of message content. Mirrors the content unions in omp `packages/ai/src/types.ts` (`TextContent`,
/// `ThinkingContent`, `RedactedThinkingContent`, `ImageContent`, `ToolCall`).
sealed class ContentBlock {
  const ContentBlock();
}

final class TextBlock extends ContentBlock {
  const TextBlock(this.text);

  final String text;
}

final class ThinkingBlock extends ContentBlock {
  const ThinkingBlock(this.thinking, {this.signature});

  final String thinking;

  /// Provider replay signature (`thinkingSignature`); present when the provider signs reasoning.
  final String? signature;
}

/// Reasoning the provider returned encrypted; only its presence is displayable.
final class RedactedThinkingBlock extends ContentBlock {
  const RedactedThinkingBlock(this.data);

  final String data;
}

/// An image in message content: its bytes inline, or in omp's blob store.
sealed class ImageBlock extends ContentBlock {
  const ImageBlock({required this.mimeType});

  final String mimeType;
}

final class InlineImageBlock extends ImageBlock {
  const InlineImageBlock({required this.data, required super.mimeType, this.url});

  /// Base64 image bytes.
  final String data;

  /// Optional https mirror of [data].
  final String? url;
}

/// An image in omp's blob store (`session/blob-store.ts`): omp writes an image of 1024 base64 characters or more to
/// the session file as `blob:sha256:<hash>` and puts the bytes back only when it loads the file itself, keeping the
/// reference when the blob is gone. The app reads session files itself, so its history holds the reference.
final class BlobImageBlock extends ImageBlock {
  const BlobImageBlock({required this.hash, required super.mimeType});

  /// SHA-256 of the image bytes in lowercase hex: the blob's file name.
  final String hash;
}

final _blobRef = RegExp(r'^blob:sha256:([0-9a-f]{64})$');

/// An omp image (`ImageContent`: `data`, `mimeType`, optional `url`) whose `data` is base64 or a blob reference.
ImageBlock decodeImage(Map<String, Object?> image) {
  final data = image.string('data');
  final mimeType = image.string('mimeType');
  if (_blobRef.firstMatch(data) case final ref?) return BlobImageBlock(hash: ref[1]!, mimeType: mimeType);
  return InlineImageBlock(data: data, mimeType: mimeType, url: image.optString('url'));
}

final class ToolCallBlock extends ContentBlock {
  const ToolCallBlock({required this.id, required this.name, required this.arguments, this.intent});

  final String id;
  final String name;

  /// Tool arguments; partial while the assistant message streams.
  final Map<String, Object?> arguments;

  /// Harness-level intent (the `i` argument) when omp extracted one.
  final String? intent;
}

/// A block the app does not render: `fallback`, `anthropicServerTool`, a type added by a newer omp, or an image
/// without inline bytes.
final class OtherBlock extends ContentBlock {
  const OtherBlock(this.type, this.raw);

  final String type;
  final Map<String, Object?> raw;
}

/// Decodes message `content`: a plain string or an array of blocks.
List<ContentBlock> decodeContent(Object? content) => switch (content) {
  null || '' => const [],
  final String text => [TextBlock(text)],
  final List<Object?> blocks => [for (final block in blocks) decodeBlock(asJsonObject(block, 'content block'))],
  _ => throw FormatException('content: expected a string or an array, got ${describeJson(content)}'),
};

ContentBlock decodeBlock(Map<String, Object?> block) => switch (block.string('type')) {
  'text' => TextBlock(block.string('text')),
  'thinking' => ThinkingBlock(block.string('thinking'), signature: block.optString('thinkingSignature')),
  'redactedThinking' => RedactedThinkingBlock(block.string('data')),
  // omp's own renderers check `data` before use: an image may travel as a provider file reference only.
  'image' when block['data'] is String => decodeImage(block),
  'toolCall' => ToolCallBlock(
    id: block.string('id'),
    name: block.string('name'),
    arguments: block.optObject('arguments') ?? const {},
    intent: block.optString('intent'),
  ),
  final type => OtherBlock(type, block),
};

/// [next] with every block equal to the block at the same index of [previous] replaced by that previous instance,
/// so a UI can skip rebuilding finished blocks while a message streams. Returns [previous] itself when nothing
/// changed.
List<ContentBlock> reuseBlocks(List<ContentBlock> previous, List<ContentBlock> next) {
  if (previous.isEmpty) return next;
  var unchanged = previous.length == next.length;
  final merged = List<ContentBlock>.of(next);
  for (var i = 0; i < merged.length && i < previous.length; i++) {
    if (_sameBlock(previous[i], merged[i])) {
      merged[i] = previous[i];
    } else {
      unchanged = false;
    }
  }
  return unchanged ? previous : List.unmodifiable(merged);
}

bool _sameBlock(ContentBlock a, ContentBlock b) => switch ((a, b)) {
  (final TextBlock a, final TextBlock b) => a.text == b.text,
  (final ThinkingBlock a, final ThinkingBlock b) => a.thinking == b.thinking && a.signature == b.signature,
  (final RedactedThinkingBlock a, final RedactedThinkingBlock b) => a.data == b.data,
  (final InlineImageBlock a, final InlineImageBlock b) =>
    a.data == b.data && a.mimeType == b.mimeType && a.url == b.url,
  (final BlobImageBlock a, final BlobImageBlock b) => a.hash == b.hash && a.mimeType == b.mimeType,
  (final ToolCallBlock a, final ToolCallBlock b) =>
    a.id == b.id && a.name == b.name && a.intent == b.intent && _jsonEquals(a.arguments, b.arguments),
  (final OtherBlock a, final OtherBlock b) => _jsonEquals(a.raw, b.raw),
  _ => false,
};

bool _jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || !_jsonEquals(value, b[key])) return false;
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Concatenated text of the [TextBlock]s in [blocks].
String textOf(List<ContentBlock> blocks) => blocks.whereType<TextBlock>().map((block) => block.text).join();
