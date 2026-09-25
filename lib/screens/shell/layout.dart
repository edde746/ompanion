import 'package:flutter/widgets.dart';

/// Below this width the app stacks screens like a phone (Material's compact window class).
const compactWidthBelow = 600.0;

/// From this width the dock sits beside the center pane; below it, it opens as a drawer.
const inlineDockFrom = 1100.0;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidthBelow;
