import 'package:flutter/material.dart';

/// The monospace style of code, terminal output and diffs in the transcript: JetBrains Mono, which gpt_markdown
/// bundles for its inline code, so every platform gets the same metrics and inline and block code match. Its
/// ligatures are off: code shows the characters the file holds (`=>`, `++`, `!=`), not glyphs standing for them.
TextStyle codeTextStyle(ThemeData theme) => TextStyle(
  fontFamily: 'JetBrainsMono',
  package: 'gpt_markdown',
  fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) - 2,
  height: 1.4,
  color: theme.colorScheme.onSurface,
  fontFeatures: const [FontFeature.disable('calt'), FontFeature.disable('liga')],
);
