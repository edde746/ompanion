import 'dart:async';

import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Search that filters as you type: [onChanged] fires [debounce] after the last keystroke, at once on
/// Enter and on clear. No separate search button (docs/design.md rule 7).
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    required this.onChanged,
    this.hint,
    this.controller,
    this.debounce = const Duration(milliseconds: 250),
    this.onSubmitted,
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;
  final String? hint;
  final TextEditingController? controller;
  final Duration debounce;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  TextEditingController? _own;
  Timer? _timer;

  TextEditingController get _controller => widget.controller ?? (_own ??= TextEditingController());

  @override
  void dispose() {
    _timer?.cancel();
    _own?.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _timer?.cancel();
    _timer = Timer(widget.debounce, () => widget.onChanged(text));
  }

  void _flush(String text) {
    _timer?.cancel();
    _timer = null;
    widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    autofocus: widget.autofocus,
    textInputAction: TextInputAction.search,
    onChanged: _changed,
    onSubmitted: (text) {
      _flush(text);
      widget.onSubmitted?.call(text);
    },
    decoration: InputDecoration(
      hintText: widget.hint,
      // The glyph's ink sits 12 px from the field's edge and 12 px from the text, the field's own text inset:
      // Icons.search draws 2.25 px inside its 18 px box, and the decorator adds 4 px before the text.
      prefixIcon: const Padding(
        padding: EdgeInsetsDirectional.only(start: 10, end: 5),
        child: Icon(Icons.search, size: 18),
      ),
      prefixIconConstraints: const BoxConstraints(minHeight: AppSizes.control),
      suffixIcon: ValueListenableBuilder(
        valueListenable: _controller,
        builder: (context, value, _) => value.text.isEmpty
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                onPressed: () {
                  _controller.clear();
                  _flush('');
                },
              ),
      ),
    ),
  );
}
