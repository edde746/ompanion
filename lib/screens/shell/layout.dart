import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';

/// Below this width the app stacks screens like a phone (Material's compact window class).
const compactWidthBelow = 600.0;

/// From this width the dock sits beside the center pane; below it, it opens as a drawer.
const inlineDockFrom = 1100.0;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidthBelow;

/// How narrow and wide the user can drag the sidebar: at its narrowest, the header still holds the macOS traffic
/// lights and its three buttons.
const sidebarWidthRange = (min: 240.0, max: 480.0);

/// How narrow and wide the user can drag the inline dock.
const dockWidthRange = (min: 280.0, max: 800.0);

/// The center pane keeps at least this width beside the sidebar and the dock, where the window allows it.
const centerMinWidth = 400.0;

/// The widths a [window] this wide gives the sidebar and the inline dock, from the widths the user chose (null for a
/// pane that is closed, which gets 0): each within its range, and together leaving the center [centerMinWidth] as far
/// as their minimums allow. One pane gives way to the other: the sidebar, unless [dockGivesWay]. A dragged pane is the
/// one that gives way, so widening it never narrows the other; a narrowing window takes from the sidebar first.
({double sidebar, double dock}) paneWidths(
  double window, {
  required double? sidebar,
  required double? dock,
  bool dockGivesWay = false,
}) {
  final room = window - centerMinWidth;
  double fit(double? chosen, ({double min, double max}) range, double besides) =>
      chosen == null ? 0 : clampDouble(chosen, range.min, math.max(range.min, math.min(range.max, room - besides)));
  if (dockGivesWay) {
    final kept = fit(sidebar, sidebarWidthRange, dock == null ? 0 : dockWidthRange.min);
    return (sidebar: kept, dock: fit(dock, dockWidthRange, kept));
  }
  final kept = dock == null ? 0.0 : clampDouble(dock, dockWidthRange.min, dockWidthRange.max);
  final given = fit(sidebar, sidebarWidthRange, kept);
  return (sidebar: given, dock: fit(dock, dockWidthRange, given));
}
