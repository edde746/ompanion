import 'package:flutter/material.dart';

import '../../config/settings_schema.dart';
import '../../config/settings_view.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_select.dart';
import '../chat/transcript/code_style.dart';

/// Called with the new value of a setting.
typedef SettingChanged = void Function(Object? value);

/// The compact editor at the end of a row (switch, select, credential), or null when [editor] needs a field.
Widget? trailingEditor(
  BuildContext context,
  SettingSchema setting,
  SettingEditor editor,
  SettingDisplay display, {
  required bool enabled,
  required SettingChanged onChanged,
}) {
  final value = display.value;
  switch (editor) {
    case SwitchEditor():
      return Switch(value: value == true, onChanged: enabled ? onChanged : null);
    case ChoiceEditor(:final options):
      final current = value?.toString();
      final known = options.any((option) => option.value == current);
      final select = AppSelect<String?>(
        value: current,
        options: [
          if (current == null) (null, context.t.config.settings.unset),
          for (final option in options) (option.value, option.label),
          // A value from the file that omp's list does not know (hand-edited, newer omp).
          if (current != null && !known) (current, current),
        ],
        onChanged: (choice) {
          if (choice != null && choice != current) onChanged(choice);
        },
      );
      return enabled ? select : IgnorePointer(child: Opacity(opacity: 0.38, child: select));
    case SecretEditor(:final type):
      return _SecretField(setting: setting, display: display, type: type, enabled: enabled, onChanged: onChanged);
    default:
      return null;
  }
}

/// A one-line field that fits at the end of a wide row.
bool isFieldEditor(SettingEditor editor) => editor is NumberEditor || editor is TextEditor;

/// The full-width editor under a row, or null for editors that sit at its end.
Widget? blockEditor(
  BuildContext context,
  SettingSchema setting,
  SettingEditor editor,
  SettingDisplay display, {
  required bool enabled,
  required SettingChanged onChanged,
}) => switch (editor) {
  SwitchEditor() || ChoiceEditor() || SecretEditor() => null,
  NumberEditor(:final presets) => _TextField(
    key: ValueKey('${setting.path}:${display.value}'),
    initial: display.value?.toString() ?? '',
    hint: setting.defaultValue?.toString(),
    enabled: enabled,
    number: true,
    presets: presets,
    onSubmit: (text) {
      if (text.trim().isEmpty) return null;
      final number = parseNumber(text);
      if (number == null) return context.t.config.settings.notANumber;
      onChanged(number);
      return null;
    },
    onPreset: (option) => onChanged(parseNumber(option.value)),
  ),
  TextEditor() => _TextField(
    key: ValueKey('${setting.path}:${display.value}'),
    initial: display.value?.toString() ?? '',
    hint: setting.defaultValue?.toString(),
    enabled: enabled,
    onSubmit: (text) {
      onChanged(text);
      return null;
    },
  ),
  MultiChoiceEditor(:final options, :final ordered) => _MultiChoice(
    options: options,
    ordered: ordered,
    values: _strings(display.value),
    enabled: enabled,
    onChanged: onChanged,
  ),
  StringListEditor() => _StringList(values: _strings(display.value), enabled: enabled, onChanged: onChanged),
  JsonEditor() => _JsonField(setting: setting, value: display.value, enabled: enabled, onChanged: onChanged),
};

List<String> _strings(Object? value) => value is List ? [for (final item in value) '$item'] : const [];

/// A text or number field that commits on Enter or with its check button. [onSubmit] returns an error text
/// to show, or null.
class _TextField extends StatefulWidget {
  const _TextField({
    super.key,
    required this.initial,
    required this.enabled,
    required this.onSubmit,
    this.hint,
    this.number = false,
    this.presets = const [],
    this.onPreset,
  });

  final String initial;
  final String? hint;
  final bool enabled;
  final bool number;
  final List<SettingOption> presets;
  final String? Function(String text) onSubmit;
  final ValueChanged<SettingOption>? onPreset;

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => setState(() => _error = widget.onSubmit(_controller.text));

  @override
  Widget build(BuildContext context) {
    final dirty = _controller.text != widget.initial;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
            decoration: InputDecoration(hintText: widget.hint, errorText: _error),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ),
        if (dirty)
          IconButton(
            tooltip: context.t.common.save,
            icon: const Icon(Icons.check),
            onPressed: widget.enabled ? _submit : null,
          ),
        if (widget.presets.isNotEmpty)
          PopupMenuButton<SettingOption>(
            tooltip: context.t.config.settings.presets,
            enabled: widget.enabled,
            icon: const Icon(Icons.expand_more),
            onSelected: widget.onPreset,
            itemBuilder: (context) => [
              for (final option in widget.presets)
                PopupMenuItem(
                  value: option,
                  child: ListTile(
                    dense: true,
                    title: Text(option.label),
                    subtitle: option.description == null ? null : Text(option.description!),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// A credential: only whether it is set shows; a new value is typed into a dialog and written through a
/// 0600 file.
class _SecretField extends StatelessWidget {
  const _SecretField({
    required this.setting,
    required this.display,
    required this.type,
    required this.enabled,
    required this.onChanged,
  });

  final SettingSchema setting;
  final SettingDisplay display;
  final SettingType type;
  final bool enabled;
  final SettingChanged onChanged;

  Future<void> _edit(BuildContext context) async {
    final result = await showDialog<({Object? value})>(
      context: context,
      builder: (context) => _SecretDialog(title: setting.label, type: type),
    );
    if (result != null) onChanged(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(display.configured ? Icons.lock : Icons.lock_open, size: 16),
        const SizedBox(width: 8),
        Text(display.configured ? t.config.settings.secretSet : t.config.settings.secretUnset),
        const SizedBox(width: 12),
        FilledButton.tonal(onPressed: enabled ? () => _edit(context) : null, child: Text(t.config.settings.secretEdit)),
      ],
    );
  }
}

class _SecretDialog extends StatefulWidget {
  const _SecretDialog({required this.title, required this.type});

  final String title;
  final SettingType type;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  final _controller = TextEditingController();
  String? _error;

  bool get _json => widget.type == SettingType.record || widget.type == SettingType.array;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!_json) {
      Navigator.pop(context, (value: _controller.text));
      return;
    }
    try {
      Navigator.pop(context, (value: parseJsonValue(_controller.text, widget.type)));
    } on JsonValueException catch (error) {
      setState(() => _error = _jsonError(context.t, error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          obscureText: !_json,
          maxLines: _json ? 6 : 1,
          style: _json ? codeTextStyle(Theme.of(context)).copyWith(fontSize: 13) : null,
          decoration: InputDecoration(helperText: t.config.settings.secretHelp, helperMaxLines: 3, errorText: _error),
          onSubmitted: _json ? null : (_) => _save(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _save, child: Text(t.common.save)),
      ],
    );
  }
}

/// A subset of a closed vocabulary. Unordered: one chip per option. Ordered: the chosen values in order,
/// removable, with the rest offered for appending.
class _MultiChoice extends StatelessWidget {
  const _MultiChoice({
    required this.options,
    required this.ordered,
    required this.values,
    required this.enabled,
    required this.onChanged,
  });

  final List<SettingOption> options;
  final bool ordered;
  final List<String> values;
  final bool enabled;
  final SettingChanged onChanged;

  String _label(String value) => options.where((option) => option.value == value).firstOrNull?.label ?? value;

  @override
  Widget build(BuildContext context) {
    if (!ordered) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final option in options)
            FilterChip(
              label: Text(option.label),
              tooltip: option.description,
              selected: values.contains(option.value),
              onSelected: enabled
                  ? (selected) => onChanged([
                      for (final candidate in options)
                        if (candidate.value == option.value ? selected : values.contains(candidate.value))
                          candidate.value,
                    ])
                  : null,
            ),
          // Values outside the vocabulary stay, so a hand-edited file is not silently rewritten.
          for (final value in values)
            if (!options.any((option) => option.value == value))
              InputChip(label: Text(value), onDeleted: enabled ? () => onChanged([...values]..remove(value)) : null),
        ],
      );
    }
    final rest = [
      for (final option in options)
        if (!values.contains(option.value)) option,
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (index, value) in values.indexed)
          InputChip(
            avatar: CircleAvatar(child: Text('${index + 1}')),
            label: Text(_label(value)),
            onDeleted: enabled ? () => onChanged([...values]..removeAt(index)) : null,
          ),
        if (rest.isNotEmpty)
          PopupMenuButton<String>(
            enabled: enabled,
            tooltip: context.t.config.settings.addItem,
            icon: const Icon(Icons.add),
            onSelected: (value) => onChanged([...values, value]),
            itemBuilder: (context) => [
              for (final option in rest) PopupMenuItem(value: option.value, child: Text(option.label)),
            ],
          ),
      ],
    );
  }
}

/// A list of free strings: chips plus a field that appends on Enter.
class _StringList extends StatefulWidget {
  const _StringList({required this.values, required this.enabled, required this.onChanged});

  final List<String> values;
  final bool enabled;
  final SettingChanged onChanged;

  @override
  State<_StringList> createState() => _StringListState();
}

class _StringListState extends State<_StringList> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onChanged([...widget.values, text]);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.values.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (index, value) in widget.values.indexed)
                  InputChip(
                    label: Text(value),
                    onDeleted: widget.enabled ? () => widget.onChanged([...widget.values]..removeAt(index)) : null,
                  ),
              ],
            ),
          ),
        TextField(
          controller: _controller,
          enabled: widget.enabled,
          decoration: InputDecoration(
            hintText: context.t.config.settings.addItem,
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: widget.enabled ? _add : null),
          ),
          onSubmitted: (_) => _add(),
        ),
      ],
    );
  }
}

/// Any JSON value: a one-line summary and a dialog editor.
class _JsonField extends StatelessWidget {
  const _JsonField({required this.setting, required this.value, required this.enabled, required this.onChanged});

  final SettingSchema setting;
  final Object? value;
  final bool enabled;
  final SettingChanged onChanged;

  Future<void> _edit(BuildContext context) async {
    final result = await showDialog<({Object? value})>(
      context: context,
      builder: (context) => _JsonDialog(title: setting.label, type: setting.type, initial: value),
    );
    if (result != null) onChanged(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            describeValue(value),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: enabled ? () => _edit(context) : null, child: Text(context.t.common.edit)),
      ],
    );
  }
}

class _JsonDialog extends StatefulWidget {
  const _JsonDialog({required this.title, required this.type, required this.initial});

  final String title;
  final SettingType type;
  final Object? initial;

  @override
  State<_JsonDialog> createState() => _JsonDialogState();
}

class _JsonDialogState extends State<_JsonDialog> {
  late final _controller = TextEditingController(text: formatJson(widget.initial));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final value = parseJsonValue(_controller.text, widget.type);
      Navigator.pop(context, (value: value));
    } on JsonValueException catch (error) {
      setState(() => _error = _jsonError(context.t, error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 16,
          minLines: 6,
          style: codeTextStyle(Theme.of(context)).copyWith(fontSize: 13),
          decoration: InputDecoration(errorText: _error),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _save, child: Text(t.common.save)),
      ],
    );
  }
}

String _jsonError(Translations t, JsonValueException error) => switch (error.problem) {
  JsonValueProblem.notJson => t.config.settings.notJson(error: error.detail ?? ''),
  JsonValueProblem.notObject => t.config.settings.expectedObject,
  JsonValueProblem.notArray => t.config.settings.expectedArray,
};
