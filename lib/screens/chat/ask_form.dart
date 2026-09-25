import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import 'ask.dart';
import 'request_frame.dart';
import 'transcript/code_style.dart';

/// The companion's full-fidelity `ask` form, inline: every question with its header, options with descriptions,
/// previews and the recommended mark, multi-select, an "Other" answer and a note, plus "chat about this".
class AskForm extends StatefulWidget {
  const AskForm({
    super.key,
    required this.params,
    required this.drafts,
    required this.busy,
    required this.error,
    required this.onSubmit,
    required this.onCancel,
    this.navigation,
  });

  final Map<String, Object?> params;

  /// The answers entered so far, one per question: empty the first time, filled and kept up to date here, so a form
  /// the user navigated away from comes back as it was left.
  final List<AskDraft> drafts;
  final bool busy;
  final String? error;

  /// Called with the `ask` answer value (`{kind: "submit" | "chat", …}`).
  final ValueChanged<Map<String, Object?>> onSubmit;

  /// Cancels the request, which aborts the turn as Esc does in the TUI.
  final VoidCallback onCancel;
  final Widget? navigation;

  @override
  State<AskForm> createState() => _AskFormState();
}

/// Radio value of the "Other" choice; option labels are the other values.
const _otherValue = '\u0000other';

class _AskFormState extends State<AskForm> {
  AskParams? _params;
  String? _invalid;
  List<TextEditingController> _custom = const [];
  List<TextEditingController> _notes = const [];

  List<AskDraft> get _drafts => widget.drafts;

  @override
  void initState() {
    super.initState();
    try {
      final params = AskParams.fromJson(widget.params);
      _params = params;
      if (_drafts.isEmpty) _drafts.addAll([for (final question in params.questions) AskDraft.initial(question)]);
      _custom = [for (final draft in _drafts) TextEditingController(text: draft.custom)];
      _notes = [for (final draft in _drafts) TextEditingController(text: draft.note)];
    } on FormatException catch (error) {
      _invalid = error.message;
    }
  }

  @override
  void dispose() {
    _syncText();
    for (final controller in [..._custom, ..._notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncText() {
    for (final (index, draft) in _drafts.indexed) {
      draft
        ..custom = _custom[index].text
        ..note = _notes[index].text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final params = _params;
    final busy = widget.busy;
    final cancel = TextButton(onPressed: busy ? null : widget.onCancel, child: Text(t.common.cancel));
    if (params == null) {
      return RequestFrame(
        title: t.ask.title,
        navigation: widget.navigation,
        error: widget.error,
        body: Text(t.ask.invalid(error: _invalid ?? '')),
        actions: [cancel],
      );
    }
    _syncText();
    final deadline = params.deadline;
    return RequestFrame(
      title: params.questions.length == 1 ? t.ask.title : t.ask.titleMany(n: params.questions.length),
      navigation: widget.navigation,
      error: widget.error,
      deadline: deadline == null ? null : DateTime.fromMillisecondsSinceEpoch(deadline),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, question) in params.questions.indexed) ...[
            if (index > 0) const SizedBox(height: 20),
            _QuestionForm(
              question: question,
              draft: _drafts[index],
              custom: _custom[index],
              note: _notes[index],
              enabled: !busy,
              onChanged: () => setState(() {}),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => widget.onSubmit(askChat), child: Text(t.ask.chat)),
        cancel,
        FilledButton(
          onPressed: busy || !askComplete(_drafts) ? null : () => widget.onSubmit(askSubmit(params.questions, _drafts)),
          child: Text(t.requests.submit),
        ),
      ],
    );
  }
}

class _QuestionForm extends StatelessWidget {
  const _QuestionForm({
    required this.question,
    required this.draft,
    required this.custom,
    required this.note,
    required this.enabled,
    required this.onChanged,
  });

  final AskQuestion question;
  final AskDraft draft;
  final TextEditingController custom;
  final TextEditingController note;
  final bool enabled;
  final VoidCallback onChanged;

  void _choose(String label) {
    draft.choose(question, label);
    onChanged();
  }

  void _chooseOther() {
    draft.chooseOther(question);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final header = question.header;
    final options = [
      for (final (index, option) in question.options.indexed)
        _optionTile(context, option, recommended: index == question.recommended),
    ];
    final otherField = TextField(
      controller: custom,
      enabled: enabled,
      decoration: InputDecoration(hintText: t.ask.otherHint, isDense: true),
      onChanged: (text) {
        // Typing an answer chooses "Other".
        if (text.isNotEmpty && !draft.other) {
          draft.chooseOther(question);
        }
        onChanged();
      },
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Text(header, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(question.question, style: theme.textTheme.bodyLarge),
        if (question.multi) Text(t.ask.multi, style: secondary),
        const SizedBox(height: 4),
        if (question.multi) ...[
          ...options,
          CheckboxListTile(
            value: draft.other,
            onChanged: enabled ? (_) => _chooseOther() : null,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: otherField,
          ),
        ] else
          RadioGroup<String>(
            groupValue: draft.other ? _otherValue : draft.selected.firstOrNull,
            onChanged: (value) {
              if (!enabled || value == null) return;
              value == _otherValue ? _chooseOther() : _choose(value);
            },
            child: Column(
              children: [
                ...options,
                RadioListTile<String>(
                  value: _otherValue,
                  enabled: enabled,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: otherField,
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSizes.gap),
        TextField(
          controller: note,
          enabled: enabled,
          decoration: InputDecoration(hintText: t.ask.note, isDense: true),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }

  Widget _optionTile(BuildContext context, AskOption option, {required bool recommended}) {
    final t = context.t;
    final theme = Theme.of(context);
    final chosen = draft.selected.contains(option.label);
    final title = Row(
      children: [
        Flexible(child: Text(option.label)),
        if (recommended) ...[
          const SizedBox(width: AppSizes.gap),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: Text(t.ask.recommended, style: theme.textTheme.labelSmall),
          ),
        ],
      ],
    );
    final preview = option.preview;
    final subtitle = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (option.description != null) Text(option.description!),
        if (preview != null && chosen)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
            child: SelectableText(preview, style: codeTextStyle(theme)),
          ),
      ],
    );
    final hasSubtitle = option.description != null || (preview != null && chosen);
    if (question.multi) {
      return CheckboxListTile(
        value: chosen,
        onChanged: enabled ? (_) => _choose(option.label) : null,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: title,
        subtitle: hasSubtitle ? subtitle : null,
      );
    }
    return RadioListTile<String>(
      value: option.label,
      enabled: enabled,
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      title: title,
      subtitle: hasSubtitle ? subtitle : null,
    );
  }
}
