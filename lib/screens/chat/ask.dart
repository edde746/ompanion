/// The companion's `ask` request and its answer (docs/contracts/ompx.md, "Requests").
library;

final class AskOption {
  const AskOption({required this.label, this.description, this.preview});

  factory AskOption.fromJson(Object? json) {
    final map = _object(json, 'option');
    return AskOption(
      label: _string(map, 'label'),
      description: _optString(map, 'description'),
      preview: _optString(map, 'preview'),
    );
  }

  final String label;
  final String? description;

  /// Text shown when the option is chosen, e.g. the code the option would produce.
  final String? preview;
}

final class AskQuestion {
  const AskQuestion({
    required this.id,
    required this.question,
    this.header,
    required this.options,
    this.multi = false,
    this.recommended,
  });

  factory AskQuestion.fromJson(Object? json) {
    final map = _object(json, 'question');
    final options = map['options'];
    if (options is! List) throw const FormatException('ask question: "options" is not a list');
    final recommended = map['recommended'];
    return AskQuestion(
      id: _string(map, 'id'),
      question: _string(map, 'question'),
      header: _optString(map, 'header'),
      options: [for (final option in options) AskOption.fromJson(option)],
      multi: map['multi'] == true,
      recommended: recommended is int && recommended >= 0 && recommended < options.length ? recommended : null,
    );
  }

  final String id;
  final String question;

  /// Short label of the question, e.g. `Color`.
  final String? header;
  final List<AskOption> options;
  final bool multi;

  /// Index into [options].
  final int? recommended;
}

final class AskParams {
  const AskParams({required this.questions, this.timeout, this.deadline});

  /// Throws [FormatException] when [params] do not follow the contract.
  factory AskParams.fromJson(Map<String, Object?> params) {
    final questions = params['questions'];
    if (questions is! List || questions.isEmpty) throw const FormatException('ask: "questions" is not a list');
    final timeout = params['timeout'];
    final deadline = params['deadline'];
    return AskParams(
      questions: [for (final question in questions) AskQuestion.fromJson(question)],
      timeout: timeout is int ? timeout : null,
      deadline: deadline is int ? deadline : null,
    );
  }

  final List<AskQuestion> questions;

  /// Milliseconds; absent when the `ask.timeout` setting is 0.
  final int? timeout;

  /// Host epoch milliseconds at which the companion answers with the recommended options.
  final int? deadline;
}

/// What the user has entered for one question.
final class AskDraft {
  AskDraft({Set<String>? selected, this.other = false, this.custom = '', this.note = ''}) : selected = selected ?? {};

  /// A draft with the recommended option chosen for a single-choice question, as the TUI preselects it.
  factory AskDraft.initial(AskQuestion question) {
    final recommended = question.recommended;
    return AskDraft(selected: !question.multi && recommended != null ? {question.options[recommended].label} : null);
  }

  /// Chosen option labels.
  final Set<String> selected;

  /// "Other" is chosen; [custom] holds its text.
  bool other;
  String custom;
  String note;

  /// Chooses [label]: the only choice of a single-choice question, toggled in a multi-choice one.
  void choose(AskQuestion question, String label) {
    if (question.multi) {
      if (!selected.remove(label)) selected.add(label);
      return;
    }
    selected
      ..clear()
      ..add(label);
    other = false;
  }

  /// Chooses "Other": exclusive in a single-choice question, toggled in a multi-choice one.
  void chooseOther(AskQuestion question) {
    if (question.multi) {
      other = !other;
      return;
    }
    selected.clear();
    other = true;
  }

  bool get answered => selected.isNotEmpty || (other && custom.trim().isNotEmpty);
}

/// True when every question has a choice or "Other" text.
bool askComplete(List<AskDraft> drafts) => drafts.every((draft) => draft.answered);

/// The `submit` answer: one result per question, in order, with option labels in the options' order.
Map<String, Object?> askSubmit(List<AskQuestion> questions, List<AskDraft> drafts) {
  if (questions.length != drafts.length) throw ArgumentError('one draft per question');
  return {
    'kind': 'submit',
    'results': [
      for (final (index, question) in questions.indexed)
        {
          'id': question.id,
          'selectedOptions': [
            for (final option in question.options)
              if (drafts[index].selected.contains(option.label)) option.label,
          ],
          if (drafts[index].other && drafts[index].custom.trim().isNotEmpty) 'customInput': drafts[index].custom.trim(),
          if (drafts[index].note.trim().isNotEmpty) 'note': drafts[index].note.trim(),
        },
    ],
  };
}

/// The user wants to talk about the questions instead of answering them.
const Map<String, Object?> askChat = {'kind': 'chat'};

Map<String, Object?> _object(Object? json, String what) =>
    json is Map<String, Object?> ? json : throw FormatException('ask: $what is not an object');

String _string(Map<String, Object?> json, String key) =>
    json[key] is String ? json[key]! as String : throw FormatException('ask: "$key" is not a string');

String? _optString(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String && value.isNotEmpty ? value : null;
}
