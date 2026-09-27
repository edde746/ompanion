import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/model_mention_palette.dart';
import 'package:ompanion/screens/chat/model_picker.dart';
import 'package:omp_core/rpc.dart';

RpcModel _model(String provider, String id, String name) => RpcModel.fromJson({
  'provider': provider,
  'id': id,
  'name': name,
  'reasoning': false,
  'input': const ['text'],
});

/// [text] with the cursor at `|`, or at the end without one.
({int start, String query})? _query(String text) {
  final cursor = text.indexOf('|');
  final plain = text.replaceFirst('|', '');
  return mentionQuery(
    TextEditingValue(
      text: plain,
      selection: TextSelection.collapsed(offset: cursor < 0 ? plain.length : cursor),
    ),
  );
}

void main() {
  group('mentionQuery', () {
    test('is the token from a ^ that starts the text or follows whitespace, up to the cursor', () {
      expect(_query('^'), (start: 0, query: ''));
      expect(_query('Have ^fake/fa'), (start: 5, query: 'fake/fa'));
      expect(_query('line\n^op| rest'), (start: 5, query: 'op'));
    });

    test('is absent inside a word, after the token ended, or with a selection', () {
      expect(_query('x^fake'), isNull);
      expect(_query('^fake/fake-1 '), isNull);
      expect(
        mentionQuery(const TextEditingValue(text: 'a ^b', selection: TextSelection(baseOffset: 2, extentOffset: 4))),
        isNull,
      );
    });

    test('is absent in a ! or \$ draft, which runs as typed', () {
      for (final text in ['!echo ^', '  !!ls ^fa', r'$print("^")', r'$$ x = ^']) {
        expect(_query(text), isNull, reason: text);
      }
      expect(_query('/btw ask ^'), (start: 9, query: ''), reason: 'a command argument takes mentions');
    });
  });

  test('the model omp matches a mention against is provider/id; its name drops quotes and falls back to the id', () {
    expect(modelSelector(_model('fake', 'fake-1', 'Fake One')), 'fake/fake-1');
    expect(modelDisplayName(_model('fake', 'fake-1', ' Say "hi" ')), 'Say hi');
    expect(modelDisplayName(_model('fake', 'fake-1', '  ')), 'fake-1');
  });

  test('the list keeps models holding the query in their selector or name, by provider, then name', () {
    final models = [
      _model('zeta', 'z-think', 'Zed Think'),
      _model('fake', 'fake-think', 'Fake Think'),
      _model('fake', 'fake-1', 'Fake One'),
      _model('anthropic', 'claude-opus', 'Opus'),
    ];
    List<String> selectors(String query) => [for (final model in filterModels(models, query)) modelSelector(model)];
    expect(selectors(''), ['anthropic/claude-opus', 'fake/fake-1', 'fake/fake-think', 'zeta/z-think']);
    expect(selectors('THINK'), ['fake/fake-think', 'zeta/z-think']);
    expect(selectors('fake/fake-t'), ['fake/fake-think']);
    expect(selectors('opus'), ['anthropic/claude-opus']);
    expect(selectors('nothing'), isEmpty);
  });
}
