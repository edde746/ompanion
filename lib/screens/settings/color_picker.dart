import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/palette.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../chat/transcript/code_style.dart';

/// Picks an opaque colour (docs/design.md, Colour picker): a saturation/value area, a hue track and a hex field.
/// [onChanged] follows a drag; [onChangeEnd] gets the colour when the drag ends or a hex is applied.
class ColorPicker extends StatefulWidget {
  const ColorPicker({super.key, required this.color, required this.onChanged, required this.onChangeEnd});

  final Color color;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onChangeEnd;

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  /// Kept apart from [ColorPicker.color]: a grey or black has no hue of its own, and the track keeps the one dragged to.
  late HSVColor _hsv = HSVColor.fromColor(widget.color);
  late final _hex = TextEditingController(text: colorHex(widget.color));
  final _hexFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus && mounted) _applyHex();
    });
  }

  @override
  void didUpdateWidget(ColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color != _hsv.toColor()) {
      final hsv = HSVColor.fromColor(widget.color);
      _hsv = hsv.saturation == 0 || hsv.value == 0 ? hsv.withHue(_hsv.hue) : hsv;
    }
    if (!_hexFocus.hasFocus) _hex.text = colorHex(widget.color);
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  void _drag(HSVColor hsv) {
    setState(() => _hsv = hsv);
    _hex.text = colorHex(hsv.toColor());
    widget.onChanged(hsv.toColor());
  }

  void _dragEnd() => widget.onChangeEnd(_hsv.toColor());

  /// Anything but six hex digits puts the current colour back.
  void _applyHex() {
    final color = parseColorHex(_hex.text);
    if (color == null || color == _hsv.toColor()) {
      _hex.text = colorHex(_hsv.toColor());
      return;
    }
    setState(() => _hsv = HSVColor.fromColor(color));
    _hex.text = colorHex(color);
    widget.onChangeEnd(color);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 160,
          child: _Drag(
            onDrag: (position, size) => _drag(
              _hsv
                  .withSaturation((position.dx / size.width).clamp(0.0, 1.0))
                  .withValue(1 - (position.dy / size.height).clamp(0.0, 1.0)),
            ),
            onEnd: _dragEnd,
            child: CustomPaint(painter: _AreaPainter(_hsv)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: _haloSize,
          child: _Drag(
            onDrag: (position, size) => _drag(_hsv.withHue((position.dx / size.width).clamp(0.0, 1.0) * 360)),
            onEnd: _dragEnd,
            child: CustomPaint(painter: _HuePainter(_hsv.hue)),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(
            width: 120,
            child: TextField(
              controller: _hex,
              focusNode: _hexFocus,
              style: codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodyMedium?.fontSize),
              decoration: InputDecoration(hintText: context.t.themeEditor.hex),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                LengthLimitingTextInputFormatter(7),
              ],
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _applyHex(),
            ),
          ),
        ),
      ],
    );
  }
}

const _haloSize = 18.0;
const _handleSize = 14.0;

/// Reports every pointer position over [child] from the pointer's first contact: it takes the pointer from any scroll
/// view around it at once, so a vertical drag on a phone moves the handle instead of the list.
class _Drag extends StatelessWidget {
  const _Drag({required this.onDrag, required this.onEnd, required this.child});

  final void Function(Offset position, Size size) onDrag;
  final VoidCallback onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          _EagerPanRecognizer: GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
            _EagerPanRecognizer.new,
            (recognizer) => recognizer
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = ((details) => onDrag(details.localPosition, size))
              ..onUpdate = ((details) => onDrag(details.localPosition, size))
              ..onEnd = ((_) => onEnd())
              ..onCancel = onEnd,
          ),
        },
        child: SizedBox.expand(child: child),
      );
    },
  );
}

/// A pan that wins the gesture arena on pointer down.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}

/// A handle: a disc in [color] on a halo of white or black, whichever stands apart from it. Not a stroke.
void _paintHandle(Canvas canvas, Offset center, Color color) {
  final halo = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
  canvas.drawCircle(center, _haloSize / 2, Paint()..color = halo);
  canvas.drawCircle(center, _handleSize / 2, Paint()..color = color);
}

class _AreaPainter extends CustomPainter {
  const _AreaPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final area = RRect.fromRectAndRadius(rect, const Radius.circular(AppSizes.radius));
    final hue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRRect(area, Paint()..shader = LinearGradient(colors: [Colors.white, hue]).createShader(rect));
    canvas.drawRRect(
      area,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    _paintHandle(canvas, Offset(hsv.saturation * size.width, (1 - hsv.value) * size.height), hsv.toColor());
  }

  @override
  bool shouldRepaint(_AreaPainter oldDelegate) => oldDelegate.hsv != hsv;
}

class _HuePainter extends CustomPainter {
  const _HuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    const height = 12.0;
    final track = Rect.fromLTWH(0, (size.height - height) / 2, size.width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(height / 2)),
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var degrees = 0; degrees <= 360; degrees += 60) HSVColor.fromAHSV(1, degrees % 360, 1, 1).toColor(),
          ],
        ).createShader(track),
    );
    _paintHandle(canvas, Offset(hue / 360 * size.width, size.height / 2), HSVColor.fromAHSV(1, hue, 1, 1).toColor());
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => oldDelegate.hue != hue;
}
