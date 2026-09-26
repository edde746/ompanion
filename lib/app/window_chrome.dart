import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Height of the top header rows (the sidebar's, the chat's). On macOS the traffic lights are centred in it; mirrors
/// `titleBarHeight` in macos/Runner/MainFlutterWindow.swift.
const double titleBarHeight = 52;

/// Space between the zoom button and a header row's content.
const double _afterTrafficLights = 12;

/// Where the top-left corner is clear of the traffic lights again: their bottom edge (centred 14 px buttons) plus 3 px.
const double trafficLightsBottom = titleBarHeight / 2 + 7 + 3;

const _channel = MethodChannel('ompanion/window_chrome');

/// macOS: AppKit's title bar is gone and the app's surfaces reach the top edge (MainFlutterWindow.swift). The
/// traffic lights float over the top-left corner until the window goes full screen; [WindowChrome.trafficLights]
/// tells header rows whether to keep room for them, [WindowChrome.trafficLightsInset] how much. Other platforms keep
/// their native frame.
class WindowChrome extends StatefulWidget {
  const WindowChrome({super.key, required this.child});

  final Widget child;

  /// Whether the window has no title bar of its own. Only the macOS app does.
  static bool get custom => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Whether the traffic lights are over the window's top-left corner now: macOS, not full screen.
  static bool trafficLights(BuildContext context) => trafficLightsInset(context) > 0;

  /// Where a header row's content starts so the traffic lights keep their room: 12 px after the zoom button while
  /// [trafficLights], else 0. The buttons' spacing differs between macOS versions, so AppKit reports where they end.
  static double trafficLightsInset(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WindowChromeScope>()?.inset ?? 0;

  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> {
  bool _fullScreen = false;

  /// The zoom button's right edge; null until AppKit said.
  double? _trafficLightsEnd;

  @override
  void initState() {
    super.initState();
    if (!WindowChrome.custom) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreen' && mounted) setState(() => _fullScreen = call.arguments as bool);
    });
    _channel.invokeMapMethod<String, Object?>('state').then((state) {
      if (!mounted) return;
      setState(() {
        _fullScreen = state!['fullScreen']! as bool;
        _trafficLightsEnd = state['trafficLightsEnd']! as double;
      });
    });
  }

  @override
  void dispose() {
    if (WindowChrome.custom) _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final end = _trafficLightsEnd;
    return _WindowChromeScope(
      inset: end == null || _fullScreen ? 0 : (end + _afterTrafficLights).roundToDouble(),
      child: widget.child,
    );
  }
}

class _WindowChromeScope extends InheritedWidget {
  const _WindowChromeScope({required this.inset, required super.child});

  final double inset;

  @override
  bool updateShouldNotify(_WindowChromeScope oldWidget) => inset != oldWidget.inset;
}

/// Makes the empty parts of a header row move the window, as a title bar does: a drag moves it, a double click does
/// what the user set for title bars in System Settings. Pointers on the row's own widgets (buttons, fields, text) stay
/// theirs: the area sits behind [child] and only gets what [child] does not hit.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!WindowChrome.trafficLights(context)) return child;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: () => _channel.invokeMethod<void>('doubleClickTitleBar'),
          ),
        ),
        child,
      ],
    );
  }
}

/// The app bar of a page that reaches the window's top edge: on macOS it is [titleBarHeight] tall, so the traffic
/// lights sit centred in it, its back button starts after them, and its empty parts move the window.
AppBar windowAppBar(
  BuildContext context, {
  Widget? title,
  List<Widget>? actions,
  bool automaticallyImplyLeading = true,
  bool? centerTitle,
}) {
  final inset = WindowChrome.trafficLightsInset(context);
  final back = automaticallyImplyLeading && (ModalRoute.of(context)?.impliesAppBarDismissal ?? false);
  return AppBar(
    title: title,
    actions: actions,
    centerTitle: centerTitle,
    automaticallyImplyLeading: automaticallyImplyLeading,
    toolbarHeight: inset == 0 ? null : titleBarHeight,
    // The back button's 40 px ink starts 8 px before its glyph; the glyph lines up with header text after the lights.
    leadingWidth: inset == 0 || !back ? null : inset - 8 + 48,
    leading: inset == 0 || !back
        ? null
        : Padding(
            padding: EdgeInsets.only(left: inset - 8),
            child: const Align(alignment: Alignment.centerLeft, child: BackButton()),
          ),
    titleSpacing: inset != 0 && !back ? inset : null,
    flexibleSpace: inset == 0 ? null : const WindowDragArea(child: SizedBox.expand()),
  );
}
