/// The session tree of RPC `get_tree` (`SessionTreeNode[]`, `session/session-entries.ts`), decoded once and
/// flattened into rows the way omp's `/tree` selector shows it (`tui/src/overlays/tree-selector.ts`).
library;

/// What an entry is, for its icon and prefix.
enum TreeEntryKind {
  user,
  assistant,
  toolResult,
  bash,
  python,
  custom,
  advisor,
  compaction,
  branchSummary,
  modelChange,
  thinkingChange,
  label,
  other,
}

/// The `/tree` selector's filter modes.
enum TreeFilter { standard, noTools, userOnly, labeledOnly, all }

/// One session entry, reduced to what a tree row shows.
final class TreeEntry {
  const TreeEntry({
    required this.id,
    required this.type,
    required this.kind,
    required this.text,
    this.label,
    this.timestamp,
    this.tokensBefore,
    this.advisorTags = '',
    this.userRequest = false,
    this.bookkeeping = false,
    this.bareToolCalls = false,
    this.aborted = false,
    this.error = false,
  });

  final String id;

  /// The entry's `type` (`message`, `compaction`, `title_change`, …).
  final String type;
  final TreeEntryKind kind;

  /// One line: the message text, a tool call summary, or the entry's own value (model, summary, title).
  final String text;

  /// The user's bookmark on this entry (`tree.label`).
  final String? label;
  final DateTime? timestamp;

  /// Context size before a compaction.
  final int? tokensBefore;

  /// Advisor names (other than `default`) and severities of an [TreeEntryKind.advisor] entry, comma-separated, as
  /// omp's `advisorTreeDisplay` lists them; [text] holds the notes.
  final String advisorTags;

  /// A prompt the user typed (or a user-invoked skill): what `/branch` and the rewind start from.
  final bool userRequest;

  /// Settings and bookkeeping entries (model, thinking, labels, titles, …), hidden unless the filter is [TreeFilter.all].
  final bool bookkeeping;

  /// An assistant message with tool calls only; the tree hides it unless it is the current leaf.
  final bool bareToolCalls;

  /// An assistant message the user aborted before it said anything.
  final bool aborted;

  /// An assistant message that failed; [text] holds the error.
  final bool error;
}

/// One visible row of the tree.
final class TreeRow {
  const TreeRow({
    required this.entry,
    required this.depth,
    required this.branchHead,
    required this.lastSibling,
    required this.collapsedCount,
    required this.onActivePath,
    required this.isLeaf,
  });

  final TreeEntry entry;

  /// Indentation level. It grows only at branch points; a linear chain keeps its branch head's depth.
  final int depth;

  /// The first entry of one of several branches from the same point; it can be collapsed.
  final bool branchHead;

  /// The last of its sibling branches.
  final bool lastSibling;

  /// Set when this branch head is collapsed: how many visible entries it hides.
  final int? collapsedCount;

  /// On the path from the root to the current leaf.
  final bool onActivePath;

  /// The current position: the session's leaf, or its nearest visible ancestor when the filter hides the leaf.
  final bool isLeaf;
}

/// The decoded tree: entries in pre-order with their parent and child indexes.
final class SessionTree {
  SessionTree._(this.entries, this._parents, this._children, this._roots, this.leafId, this._active);

  /// Decodes a `get_tree` result. Throws [FormatException] when a node is malformed. Deep trees decode without
  /// recursion: a long linear session nests one level per entry.
  factory SessionTree.decode(List<Map<String, Object?>> forest, String? leafId) {
    final nodes = <Map<String, Object?>>[];
    final parents = <int>[];
    final stack = <(Map<String, Object?>, int)>[for (final node in forest.reversed) (node, -1)];
    while (stack.isNotEmpty) {
      final (node, parent) = stack.removeLast();
      final index = nodes.length;
      nodes.add(node);
      parents.add(parent);
      final children = switch (node['children']) {
        null => const <Object?>[],
        final List<Object?> list => list,
        final other => throw FormatException('tree node children: expected an array, got ${other.runtimeType}'),
      };
      for (final child in children.reversed) {
        if (child is! Map<String, Object?>) throw const FormatException('tree node child: expected an object');
        stack.add((child, index));
      }
    }

    final toolCalls = <String, _ToolCall>{};
    for (final node in nodes) {
      if (node['entry'] case {'type': 'message', 'message': {'role': 'assistant', 'content': final List<Object?> content}}) {
        for (final block in content) {
          if (block case {'type': 'toolCall', 'id': final String id, 'name': final String name}) {
            final arguments = block['arguments'];
            toolCalls[id] = _ToolCall(name, arguments is Map<String, Object?> ? arguments : const {});
          }
        }
      }
    }

    final entries = [for (final node in nodes) _decodeNode(node, toolCalls)];
    final children = List<List<int>>.generate(nodes.length, (_) => <int>[]);
    final roots = <int>[];
    for (var i = 0; i < nodes.length; i++) {
      if (parents[i] < 0) {
        roots.add(i);
      } else {
        children[parents[i]].add(i);
      }
    }

    final active = List<bool>.filled(nodes.length, false);
    if (leafId != null) {
      var index = entries.indexWhere((entry) => entry.id == leafId);
      while (index >= 0) {
        active[index] = true;
        index = parents[index];
      }
    }
    return SessionTree._(entries, parents, children, roots, leafId, active);
  }

  /// Every entry, parents before children.
  final List<TreeEntry> entries;
  final List<int> _parents;
  final List<List<int>> _children;
  final List<int> _roots;

  /// The current leaf; null for an empty branch.
  final String? leafId;

  /// Per entry: on the path from the root to [leafId].
  final List<bool> _active;

  bool get isEmpty => entries.isEmpty;

  /// The entry [id]'s parent id, or null for a root or an unknown id.
  String? parentOf(String id) {
    final index = entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _parents[index] < 0) return null;
    return entries[_parents[index]].id;
  }

  /// The visible rows. Entries [filter] or [query] hide lift their visible descendants to the nearest visible
  /// ancestor. A branch head is expanded when it holds the current leaf, flipped by [toggled] (branch head ids); a
  /// non-empty [query] expands every branch. As in omp's selector, a hidden leaf (often a bookkeeping entry such as
  /// `session_exit`) marks its nearest visible ancestor as the current position.
  List<TreeRow> rows({TreeFilter filter = TreeFilter.standard, String query = '', Set<String> toggled = const {}}) {
    final count = entries.length;
    final tokens = query.toLowerCase().split(RegExp(r'\s+')).where((token) => token.isNotEmpty).toList();
    final visible = [for (final entry in entries) _visible(entry, filter, tokens)];
    var current = leafId == null ? -1 : entries.indexWhere((entry) => entry.id == leafId);
    while (current >= 0 && !visible[current]) {
      current = _parents[current];
    }

    // Children before parents: the reverse of pre-order.
    final display = List<List<int>>.filled(count, const []);
    final lifted = List<List<int>>.filled(count, const []);
    final hidden = List<int>.filled(count, 0);
    for (var i = count - 1; i >= 0; i--) {
      final shown = <int>[];
      for (final child in _ordered(_children[i])) {
        shown.addAll(lifted[child]);
      }
      display[i] = shown;
      var size = 0;
      for (final child in shown) {
        size += 1 + hidden[child];
      }
      hidden[i] = size;
      lifted[i] = visible[i] ? [i] : shown;
    }

    // Several first entries (the first message was replaced, or a hidden root holds several) are branches too, one
    // level in, so an abandoned one cannot read as the continuation of the current one.
    final roots = [for (final root in _ordered(_roots)) ...lifted[root]];
    final rows = <TreeRow>[];
    final branched = roots.length > 1;
    final stack = <_Visit>[
      for (var k = roots.length - 1; k >= 0; k--)
        _Visit(roots[k], branched ? 1 : 0, branched, branched && k == roots.length - 1),
    ];
    while (stack.isNotEmpty) {
      final visit = stack.removeLast();
      final entry = entries[visit.index];
      final expanded = !visit.branchHead || tokens.isNotEmpty || (_active[visit.index] != toggled.contains(entry.id));
      final kids = display[visit.index];
      rows.add(
        TreeRow(
          entry: entry,
          depth: visit.depth,
          branchHead: visit.branchHead,
          lastSibling: visit.lastSibling,
          collapsedCount: expanded || kids.isEmpty ? null : hidden[visit.index],
          onActivePath: _active[visit.index],
          isLeaf: visit.index == current,
        ),
      );
      if (!expanded) continue;
      if (kids.length == 1) {
        stack.add(_Visit(kids.single, visit.depth, false, false));
      } else {
        for (var k = kids.length - 1; k >= 0; k--) {
          stack.add(_Visit(kids[k], visit.depth + 1, true, k == kids.length - 1));
        }
      }
    }
    return rows;
  }

  /// The branch holding the current leaf first; otherwise the order omp appended them.
  List<int> _ordered(List<int> indexes) {
    final active = indexes.indexWhere((index) => _active[index]);
    if (active <= 0) return indexes;
    return [indexes[active], ...indexes.take(active), ...indexes.skip(active + 1)];
  }

  bool _visible(TreeEntry entry, TreeFilter filter, List<String> tokens) {
    // The selector keeps the leaf visible even when it only called tools, so the position shows.
    if (entry.bareToolCalls && entry.id != leafId) return false;
    final passes = switch (filter) {
      TreeFilter.standard => !entry.bookkeeping,
      TreeFilter.noTools => !entry.bookkeeping && entry.kind != TreeEntryKind.toolResult,
      TreeFilter.userOnly => entry.userRequest,
      TreeFilter.labeledOnly => entry.label != null,
      TreeFilter.all => true,
    };
    if (!passes || tokens.isEmpty) return passes;
    final haystack = '${entry.label ?? ''} ${entry.advisorTags} ${entry.text}'.toLowerCase();
    return tokens.every(haystack.contains);
  }
}

final class _Visit {
  const _Visit(this.index, this.depth, this.branchHead, this.lastSibling);

  final int index;
  final int depth;
  final bool branchHead;
  final bool lastSibling;
}

final class _ToolCall {
  const _ToolCall(this.name, this.arguments);

  final String name;
  final Map<String, Object?> arguments;
}

/// Longest preview kept per entry; rows show one line anyway.
const _textLimit = 400;

/// Bookkeeping entry types the `/tree` selector hides by default (`isSettingsEntry`).
const _bookkeepingTypes = {
  'label',
  'custom',
  'model_change',
  'model_usage',
  'thinking_level_change',
  'service_tier_change',
  'title_change',
  'credential_pin',
  'session_init',
  'ttsr_injection',
  'mode_change',
  'reset_boundary',
};

TreeEntry _decodeNode(Map<String, Object?> node, Map<String, _ToolCall> toolCalls) {
  final entry = node['entry'];
  if (entry is! Map<String, Object?>) throw const FormatException('tree node: missing "entry" object');
  final id = entry['id'];
  final type = entry['type'];
  if (id is! String || type is! String) throw const FormatException('tree entry: missing "id" or "type"');
  final label = node['label'] is String ? node['label']! as String : null;
  final timestamp = entry['timestamp'] is String ? DateTime.tryParse(entry['timestamp']! as String) : null;
  final bookkeeping = _bookkeepingTypes.contains(type);

  TreeEntry make(TreeEntryKind kind, String text, {bool userRequest = false, int? tokensBefore, String advisorTags = ''}) =>
      TreeEntry(
        id: id,
        type: type,
        kind: kind,
        text: _oneLine(text),
        label: label,
        timestamp: timestamp,
        tokensBefore: tokensBefore,
        advisorTags: advisorTags,
        userRequest: userRequest,
        bookkeeping: bookkeeping,
      );

  switch (type) {
    case 'message':
      final message = entry['message'];
      if (message is! Map<String, Object?>) throw FormatException('tree entry $id: missing "message" object');
      return _decodeMessage(id, message, label, timestamp, toolCalls);
    case 'custom_message':
      final customType = entry['customType'] is String ? entry['customType']! as String : '';
      final text = _joinText(entry['content']);
      if (customType == 'advisor') {
        final (:tags, :notes) = _advisorNotes(entry['details']);
        return make(TreeEntryKind.advisor, notes, advisorTags: tags);
      }
      return make(TreeEntryKind.custom, '[$customType]: ${_stripSystemTags(text)}', userRequest: entry['attribution'] == 'user');
    case 'compaction':
      final summary = entry['shortSummary'] ?? entry['summary'];
      final tokens = entry['tokensBefore'];
      return make(TreeEntryKind.compaction, summary is String ? summary : '', tokensBefore: tokens is num ? tokens.round() : null);
    case 'branch_summary':
      return make(TreeEntryKind.branchSummary, entry['summary'] is String ? entry['summary']! as String : '');
    case 'model_change':
      return make(TreeEntryKind.modelChange, entry['model'] is String ? entry['model']! as String : '');
    case 'thinking_level_change':
      return make(TreeEntryKind.thinkingChange, entry['thinkingLevel'] is String ? entry['thinkingLevel']! as String : 'off');
    case 'label':
      return make(TreeEntryKind.label, entry['label'] is String ? entry['label']! as String : '');
    case 'title_change':
      return make(TreeEntryKind.other, entry['title'] is String ? entry['title']! as String : '');
    case 'mode_change':
      return make(TreeEntryKind.other, entry['mode'] is String ? entry['mode']! as String : '');
    case 'custom':
      return make(TreeEntryKind.other, entry['customType'] is String ? entry['customType']! as String : '');
    case 'credential_pin':
      return make(TreeEntryKind.other, entry['provider'] is String ? entry['provider']! as String : '');
    case 'model_usage':
      final provider = entry['provider'] is String ? entry['provider']! as String : '';
      final model = entry['model'] is String ? entry['model']! as String : '';
      final purpose = entry['purpose'] is String ? entry['purpose']! as String : '';
      return make(TreeEntryKind.other, '$purpose $provider/$model');
    default:
      return make(TreeEntryKind.other, '');
  }
}

TreeEntry _decodeMessage(
  String id,
  Map<String, Object?> message,
  String? label,
  DateTime? timestamp,
  Map<String, _ToolCall> toolCalls,
) {
  final role = message['role'];
  TreeEntry make(
    TreeEntryKind kind,
    String text, {
    bool userRequest = false,
    bool bareToolCalls = false,
    bool aborted = false,
    bool error = false,
  }) => TreeEntry(
    id: id,
    type: 'message',
    kind: kind,
    text: _oneLine(text),
    label: label,
    timestamp: timestamp,
    userRequest: userRequest,
    bareToolCalls: bareToolCalls,
    aborted: aborted,
    error: error,
  );

  switch (role) {
    case 'user':
      return make(TreeEntryKind.user, _joinText(message['content']), userRequest: true);
    case 'assistant':
      final text = _joinText(message['content']);
      if (_hasText(text)) return make(TreeEntryKind.assistant, text);
      final stopReason = message['stopReason'];
      final errorMessage = message['errorMessage'];
      if (errorMessage is String && errorMessage.isNotEmpty) {
        return make(TreeEntryKind.assistant, errorMessage, error: true);
      }
      if (stopReason == 'aborted') return make(TreeEntryKind.assistant, '', aborted: true);
      // `stop` and `toolUse` without text: a turn that only called tools.
      final quiet = stopReason == null || stopReason == 'stop' || stopReason == 'toolUse';
      return make(TreeEntryKind.assistant, '', bareToolCalls: quiet, error: !quiet);
    case 'toolResult':
      final callId = message['toolCallId'];
      final call = callId is String ? toolCalls[callId] : null;
      final toolName = message['toolName'] is String ? message['toolName']! as String : 'tool';
      return make(TreeEntryKind.toolResult, call == null ? toolName : _describeToolCall(call));
    case 'bashExecution':
      return make(TreeEntryKind.bash, message['command'] is String ? message['command']! as String : '');
    case 'pythonExecution':
      return make(TreeEntryKind.python, message['code'] is String ? message['code']! as String : '');
    case 'custom':
      final customType = message['customType'] is String ? message['customType']! as String : '';
      return make(
        TreeEntryKind.custom,
        '[$customType]: ${_stripSystemTags(_joinText(message['content']))}',
        userRequest: message['attribution'] == 'user',
      );
    default:
      return make(TreeEntryKind.other, '[$role] ${_joinText(message['content'])}');
  }
}

/// The advisor's notes and their tags (`advisorTreeDisplay`, which shows `advisor (<tags>): <notes>`).
({String tags, String notes}) _advisorNotes(Object? details) {
  final notes = <String>[];
  final advisors = <String>[];
  final severities = <String>[];
  if (details case {'notes': final List<Object?> list}) {
    for (final note in list) {
      if (note case {'note': final String text}) notes.add(text);
      if (note case {'advisor': final String name} when name.isNotEmpty && name != 'default' && !advisors.contains(name)) {
        advisors.add(name);
      }
      if (note case {'severity': final String severity} when severity.isNotEmpty && !severities.contains(severity)) {
        severities.add(severity);
      }
    }
  }
  return (tags: [...advisors, ...severities].join(', '), notes: notes.join(' '));
}

/// A tool call as the `/tree` selector abbreviates it (`#formatToolCall`), without the brackets.
String _describeToolCall(_ToolCall call) {
  final args = call.arguments;
  String str(String key) => args[key] is String ? args[key]! as String : '';
  switch (call.name) {
    case 'read':
      final path = str('path').isNotEmpty ? str('path') : str('file_path');
      final offset = args['offset'];
      final limit = args['limit'];
      if (offset is! int && limit is! int) return 'read $path';
      final start = offset is int ? offset : 1;
      return limit is int ? 'read $path:$start-${start + limit - 1}' : 'read $path:$start';
    case 'write' || 'edit':
      return '${call.name} ${str('path').isNotEmpty ? str('path') : str('file_path')}';
    case 'bash':
      return 'bash ${str('command')}';
    case 'grep':
      final paths = args['paths'] ?? args['path'];
      final scope = switch (paths) {
        final String path => path,
        final List<Object?> list => list.whereType<String>().join(', '),
        _ => '.',
      };
      return 'grep /${str('pattern')}/ in $scope';
    case 'glob':
      final paths = args['path'] ?? args['paths'];
      final scope = switch (paths) {
        final String path => path,
        final List<Object?> list => list.whereType<String>().join(', '),
        _ => '.',
      };
      return 'glob $scope';
    case 'ls':
      return 'ls ${str('path').isNotEmpty ? str('path') : '.'}';
    default:
      final json = _compactJson(args);
      return '${call.name} $json';
  }
}

String _compactJson(Map<String, Object?> args) {
  final parts = <String>[];
  for (final MapEntry(:key, :value) in args.entries) {
    final shown = switch (value) {
      final String text => text,
      null => 'null',
      _ => value.toString(),
    };
    parts.add('$key: $shown');
    if (parts.join(', ').length > 80) break;
  }
  return parts.join(', ');
}

/// Text blocks joined, or the string itself.
String _joinText(Object? content) {
  if (content is String) return content;
  if (content is! List<Object?>) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block case {'type': 'text', 'text': final String text}) buffer.write(text);
  }
  return buffer.toString();
}

/// Text beyond dots and whitespace (`canonicalizeMessage`): a lone "..." is no answer.
bool _hasText(String text) => text.trim().replaceAll(RegExp(r'[.\u2026\s]'), '').isNotEmpty;

final _systemTag = RegExp(r'</?system[^>]*>');

String _stripSystemTags(String text) => text.replaceAll(_systemTag, '');

String _oneLine(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= _textLimit ? flat : flat.substring(0, _textLimit);
}
