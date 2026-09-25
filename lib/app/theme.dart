import 'package:flutter/material.dart';

/// Material 3 from one seed colour. omp's TUI palettes are deliberately not used (docs/PLAN.md D19).
ThemeData appTheme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE), brightness: brightness),
);
