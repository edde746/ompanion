import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'palette.dart';

// Built once: a new ThemeData compares unequal to the last (its extensions have no ==), and MaterialApp then animates
// the whole app from the old theme to the new one for 200 ms, rebuilding every widget that reads it.
final lightAppTheme = appTheme(AppPalette.light);
final darkAppTheme = appTheme(AppPalette.dark);

/// Monochrome, flat, dense. The contract is docs/design.md; the colours are [palette]'s tokens.
ThemeData appTheme(AppPalette palette) {
  final brightness = palette.brightness;
  final dark = brightness == Brightness.dark;
  final scheme = _colorScheme(palette);
  final colors = AppColors.from(palette);
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.radius));
  final cardShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.cardRadius));
  const controlSize = Size(0, AppSizes.control);
  const controlPadding = EdgeInsets.symmetric(horizontal: 14);
  // Explicit sizes below opt out of density so every inline control is exactly AppSizes.control tall.
  const controlDensity = VisualDensity.standard;
  final noFill = WidgetStateProperty.all<Color>(Colors.transparent);
  final desktop = switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows => true,
    _ => false,
  };

  // Popovers open over every other surface tone, so they take one of their own: surfaceBright.
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(scheme.surfaceBright),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    side: const WidgetStatePropertyAll(BorderSide.none),
    shape: WidgetStatePropertyAll(controlShape),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
    visualDensity: controlDensity,
  );

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    extensions: [colors],
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: Colors.transparent,
    splashFactory: InkRipple.splashFactory,
    // Material Symbols' optical size is 24 (the size its glyphs are drawn for) instead of the 48 Flutter falls back to.
    // IconButton takes this colour as its foreground over every variant's default, so IconButton.filled sets onPrimary.
    iconTheme: IconThemeData(color: scheme.onSurface, opticalSize: AppSizes.iconOpticalSize),
    // BackButton's own glyph comes from Material Icons; this draws the same per-platform arrow from Material Symbols.
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) => Icon(switch (Theme.of(context).platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => Symbols.arrow_back_ios_new,
        _ => Symbols.arrow_back,
      }),
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        elevation: const WidgetStatePropertyAll(0),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(controlShape),
        foregroundColor: _stateColor(scheme.onSurface, disabled: scheme.onSurface.withValues(alpha: 0.38)),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    // Safety net: an OutlinedButton renders exactly like FilledButton.tonal, without a side.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundColor: _stateColor(scheme.secondaryContainer, disabled: scheme.onSurface.withValues(alpha: 0.12)),
        foregroundColor: _stateColor(scheme.onSecondaryContainer, disabled: scheme.onSurface.withValues(alpha: 0.38)),
        elevation: const WidgetStatePropertyAll(0),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(controlPadding),
        shape: WidgetStatePropertyAll(controlShape),
        backgroundColor: _stateColor(scheme.secondaryContainer, disabled: scheme.onSurface.withValues(alpha: 0.12)),
        foregroundColor: _stateColor(scheme.onSecondaryContainer, disabled: scheme.onSurface.withValues(alpha: 0.38)),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    iconButtonTheme: const IconButtonThemeData(style: ButtonStyle(side: WidgetStatePropertyAll(BorderSide.none))),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: _stateColor(
        scheme.surfaceContainerHigh,
        focused: scheme.surfaceContainerHighest,
        disabled: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
      ),
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      isDense: true,
      visualDensity: controlDensity,
      // 24 px text line + 2 × 6 = AppSizes.control.
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      prefixIconConstraints: const BoxConstraints(minWidth: AppSizes.control, minHeight: AppSizes.control),
      suffixIconConstraints: const BoxConstraints(minWidth: AppSizes.control, minHeight: AppSizes.control),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      // Safety net: a label floats across the top edge of a fill one control tall. Labels go above fields
      // (LabeledField); a stray labelText stays a placeholder.
      floatingLabelBehavior: FloatingLabelBehavior.never,
      border: _noBorder,
      enabledBorder: _noBorder,
      focusedBorder: _noBorder,
      disabledBorder: _noBorder,
      errorBorder: _noBorder,
      focusedErrorBorder: _noBorder,
      activeIndicatorBorder: BorderSide.none,
      outlineBorder: BorderSide.none,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.onSurface,
      selectionColor: scheme.onSurface.withValues(alpha: 0.25),
      selectionHandleColor: scheme.onSurface,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.surfaceContainerHighest,
      disabledColor: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
      checkmarkColor: scheme.onSurface,
      deleteIconColor: scheme.onSurfaceVariant,
      // A chip's delete icon gets a fresh icon theme from this one or the chip defaults, never the app's.
      iconTheme: const IconThemeData(opticalSize: AppSizes.iconOpticalSize),
      labelStyle: TextStyle(color: scheme.onSurface),
      side: BorderSide.none,
      // Chips follow the global density; this padding brings their visual height to AppSizes.control.
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: desktop ? 13 : 11),
      shape: controlShape,
      elevation: 0,
      pressElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      selectedShadowColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: cardShape,
      clipBehavior: Clip.antiAlias,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainer,
      // A dialog over a dialog: the scrim drops the lower one to near black, so the top one stands apart.
      barrierColor: Colors.black.withValues(alpha: dark ? 0.8 : 0.5),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSizes.sheetRadius)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      modalBackgroundColor: scheme.surfaceContainer,
      elevation: 0,
      modalElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppSizes.sheetRadius)),
      ),
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    menuBarTheme: MenuBarThemeData(style: menuStyle),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(controlSize),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuStyle),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceBright,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: controlShape,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      side: const WidgetStatePropertyAll(BorderSide.none),
      shape: WidgetStatePropertyAll(controlShape),
      constraints: const BoxConstraints(minHeight: AppSizes.control),
    ),
    searchViewTheme: SearchViewThemeData(
      backgroundColor: scheme.surfaceContainer,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      side: BorderSide.none,
      dividerColor: Colors.transparent,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(controlShape),
        backgroundColor: _stateColor(scheme.surfaceContainerHigh, selected: scheme.surfaceContainerHighest),
        foregroundColor: _stateColor(
          scheme.onSurfaceVariant,
          selected: scheme.onSurface,
          disabled: scheme.onSurface.withValues(alpha: 0.38),
        ),
        minimumSize: const WidgetStatePropertyAll(controlSize),
        visualDensity: controlDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    toggleButtonsTheme: ToggleButtonsThemeData(
      borderColor: Colors.transparent,
      selectedBorderColor: Colors.transparent,
      disabledBorderColor: Colors.transparent,
      borderWidth: 0,
      borderRadius: BorderRadius.circular(AppSizes.radius),
      fillColor: scheme.surfaceContainerHighest,
      selectedColor: scheme.onSurface,
      color: scheme.onSurfaceVariant,
      constraints: const BoxConstraints(minWidth: AppSizes.control, minHeight: AppSizes.control),
    ),
    // Safety net: dividers are not used (docs/design.md rule 1); any left over render invisible.
    dividerTheme: const DividerThemeData(color: Colors.transparent, thickness: 0),
    dataTableTheme: const DataTableThemeData(dividerThickness: 0),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: RoundedRectangleBorder(),
      collapsedShape: RoundedRectangleBorder(),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      indicatorColor: scheme.surfaceContainerHighest,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(color: scheme.onSurface, opticalSize: AppSizes.iconOpticalSize),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant, opticalSize: AppSizes.iconOpticalSize),
      selectedLabelTextStyle: TextStyle(color: scheme.onSurface),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHighest,
      indicatorShape: const StadiumBorder(),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHighest,
      indicatorShape: const StadiumBorder(),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      indicator: _PillIndicator(scheme.surfaceContainerHighest),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      dividerHeight: 0,
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      overlayColor: noFill,
      splashFactory: NoSplash.splashFactory,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: _stateColor(
        scheme.onSurfaceVariant,
        selected: scheme.onPrimary,
        disabled: scheme.onSurface.withValues(alpha: 0.38),
      ),
      trackColor: _stateColor(
        scheme.surfaceContainerHighest,
        selected: scheme.primary,
        disabled: scheme.onSurface.withValues(alpha: 0.12),
      ),
      trackOutlineColor: noFill,
      trackOutlineWidth: const WidgetStatePropertyAll(0),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: _stateColor(Colors.transparent, selected: scheme.onSurface),
      checkColor: WidgetStatePropertyAll(scheme.surface),
    ),
    radioTheme: RadioThemeData(fillColor: _stateColor(scheme.onSurfaceVariant, selected: scheme.onSurface)),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.onSurfaceVariant,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.onSurface,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.onSurface,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(scheme.onSurfaceVariant.withValues(alpha: 0.5)),
      trackColor: noFill,
      trackBorderColor: noFill,
      radius: const Radius.circular(4),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: scheme.onSurface, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.onSurface,
      selectedTileColor: scheme.surfaceContainerHighest,
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      actionTextColor: scheme.onInverseSurface,
      shape: controlShape,
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: scheme.surfaceContainer,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      dividerColor: Colors.transparent,
    ),
    badgeTheme: BadgeThemeData(backgroundColor: scheme.onSurface, textColor: scheme.surface),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
    ),
  );
}

/// Sizes shared by every screen (docs/design.md).
abstract final class AppSizes {
  /// Height of every inline control: buttons, fields, selects, segmented controls.
  static const double control = 36;

  /// Corner radius of controls.
  static const double radius = 10;
  static const double cardRadius = 12;
  static const double sheetRadius = 16;
  static const double gap = 8;

  /// Material Symbols optical size of every icon (docs/design.md, Icons).
  static const double iconOpticalSize = 24;

  /// Dense list row on desktop.
  static const double rowHeight = 32;

  /// Dense list row on phones.
  static const double rowHeightTouch = 44;
}

/// Every palette token of the theme by name; content reads its colours here (docs/design.md, Tokens). Chrome reads the
/// [ColorScheme] roles the same tokens drive.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  AppColors.from(AppPalette palette) : this._([for (final token in ThemeToken.values) palette[token]]);

  const AppColors._(this._colors);

  /// Indexed by [ThemeToken.index].
  final List<Color> _colors;

  static final dark = AppColors.from(AppPalette.dark);
  static final light = AppColors.from(AppPalette.light);

  Color operator [](ThemeToken token) => _colors[token.index];

  Color get error => this[ThemeToken.error];
  Color get errorSurface => this[ThemeToken.errorSurface];
  Color get warning => this[ThemeToken.warning];
  Color get success => this[ThemeToken.success];
  Color get diffAdd => this[ThemeToken.diffAdd];
  Color get diffAddSurface => this[ThemeToken.diffAddSurface];
  Color get diffRemove => this[ThemeToken.diffRemove];
  Color get diffRemoveSurface => this[ThemeToken.diffRemoveSurface];
  Color get running => this[ThemeToken.running];

  /// Falls back to the set for the ambient brightness under a theme not built by [appTheme] (widget tests).
  static AppColors of(BuildContext context) => ofTheme(Theme.of(context));

  static AppColors ofTheme(ThemeData theme) =>
      theme.extension<AppColors>() ?? (theme.brightness == Brightness.dark ? dark : light);

  @override
  AppColors copyWith({List<Color>? colors}) => AppColors._(colors ?? _colors);

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors._([for (var i = 0; i < _colors.length; i++) Color.lerp(_colors[i], other._colors[i], t)!]);
  }
}

/// Each token's roles (docs/design.md, Tokens); the roles no token drives keep the base's greys.
ColorScheme _colorScheme(AppPalette palette) {
  Color c(ThemeToken token) => palette[token];
  final dark = palette.base == ThemeBase.dark;
  return ColorScheme(
    brightness: palette.brightness,
    primary: c(ThemeToken.accent),
    onPrimary: c(ThemeToken.onAccent),
    primaryContainer: c(ThemeToken.selected),
    onPrimaryContainer: c(ThemeToken.text),
    secondary: dark ? const Color(0xFFBDBDBD) : const Color(0xFF444444),
    onSecondary: c(ThemeToken.background),
    secondaryContainer: c(ThemeToken.field),
    onSecondaryContainer: c(ThemeToken.text),
    tertiary: dark ? const Color(0xFFBDBDBD) : const Color(0xFF444444),
    onTertiary: c(ThemeToken.background),
    tertiaryContainer: c(ThemeToken.selected),
    onTertiaryContainer: c(ThemeToken.text),
    error: c(ThemeToken.error),
    onError: c(ThemeToken.background),
    errorContainer: c(ThemeToken.errorSurface),
    onErrorContainer: dark ? const Color(0xFFF2B8B5) : const Color(0xFF5C1512),
    surface: c(ThemeToken.background),
    onSurface: c(ThemeToken.text),
    surfaceDim: dark ? const Color(0xFF000000) : const Color(0xFFDDDDDD),
    surfaceBright: c(ThemeToken.popover),
    surfaceContainerLowest: c(ThemeToken.background),
    surfaceContainerLow: c(ThemeToken.pane),
    surfaceContainer: c(ThemeToken.card),
    surfaceContainerHigh: c(ThemeToken.field),
    surfaceContainerHighest: c(ThemeToken.selected),
    onSurfaceVariant: c(ThemeToken.textMuted),
    outline: dark ? const Color(0xFF5C5C5C) : const Color(0xFF8F8F8F),
    outlineVariant: c(ThemeToken.selected),
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: c(ThemeToken.text),
    onInverseSurface: c(ThemeToken.background),
    inversePrimary: dark ? const Color(0xFF111111) : const Color(0xFFEDEDED),
    surfaceTint: Colors.transparent,
  );
}

const _noBorder = OutlineInputBorder(
  borderSide: BorderSide.none,
  borderRadius: BorderRadius.all(Radius.circular(AppSizes.radius)),
);

WidgetStateColor _stateColor(Color base, {Color? selected, Color? focused, Color? disabled}) =>
    WidgetStateColor.resolveWith((states) {
      if (disabled != null && states.contains(WidgetState.disabled)) return disabled;
      if (selected != null && states.contains(WidgetState.selected)) return selected;
      if (focused != null && states.contains(WidgetState.focused)) return focused;
      return base;
    });

/// Selected tab: a stadium, at most one control tall, filling the tab's width. No underline.
class _PillIndicator extends Decoration {
  const _PillIndicator(this.color);

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _PillPainter(color);
}

class _PillPainter extends BoxPainter {
  _PillPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final height = size.height < AppSizes.control ? size.height : AppSizes.control;
    final rect = Rect.fromLTWH(offset.dx, offset.dy + (size.height - height) / 2, size.width, height);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(height / 2)), Paint()..color = color);
  }
}
