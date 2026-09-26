import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Monochrome, flat, dense. The contract is docs/design.md; tokens here mirror its tables.
ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark ? _darkScheme : _lightScheme;
  final colors = dark ? AppColors.dark : AppColors.light;
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
        backgroundColor: _stateColor(
          scheme.secondaryContainer,
          disabled: scheme.onSurface.withValues(alpha: 0.12),
        ),
        foregroundColor: _stateColor(
          scheme.onSecondaryContainer,
          disabled: scheme.onSurface.withValues(alpha: 0.38),
        ),
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
        backgroundColor: _stateColor(
          scheme.secondaryContainer,
          disabled: scheme.onSurface.withValues(alpha: 0.12),
        ),
        foregroundColor: _stateColor(
          scheme.onSecondaryContainer,
          disabled: scheme.onSurface.withValues(alpha: 0.38),
        ),
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
      selectedIconTheme: IconThemeData(color: scheme.onSurface),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
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
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
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

  /// Dense list row on desktop.
  static const double rowHeight = 32;

  /// Dense list row on phones.
  static const double rowHeightTouch = 44;
}

/// Colours that carry meaning in content. Chrome never uses these; see docs/design.md rule 2.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.error,
    required this.errorSurface,
    required this.warning,
    required this.success,
    required this.diffAdd,
    required this.diffAddSurface,
    required this.diffRemove,
    required this.diffRemoveSurface,
    required this.running,
  });

  final Color error;
  final Color errorSurface;
  final Color warning;
  final Color success;
  final Color diffAdd;
  final Color diffAddSurface;
  final Color diffRemove;
  final Color diffRemoveSurface;
  final Color running;

  static const dark = AppColors(
    error: Color(0xFFE07A76),
    errorSurface: Color(0xFF2A1413),
    warning: Color(0xFFD6A85C),
    success: Color(0xFF7DBA8A),
    diffAdd: Color(0xFF7DBA8A),
    diffAddSurface: Color(0xFF0E2215),
    diffRemove: Color(0xFFE07A76),
    diffRemoveSurface: Color(0xFF2A1212),
    running: Color(0xFF8F8F8F),
  );

  static const light = AppColors(
    error: Color(0xFFB0413C),
    errorSurface: Color(0xFFFBECEB),
    warning: Color(0xFF946200),
    success: Color(0xFF357A45),
    diffAdd: Color(0xFF357A45),
    diffAddSurface: Color(0xFFE7F4EA),
    diffRemove: Color(0xFFB0413C),
    diffRemoveSurface: Color(0xFFFBECEB),
    running: Color(0xFF5C5C5C),
  );

  /// Falls back to the set for the ambient brightness under a theme not built by [appTheme] (widget tests).
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ?? (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppColors copyWith({
    Color? error,
    Color? errorSurface,
    Color? warning,
    Color? success,
    Color? diffAdd,
    Color? diffAddSurface,
    Color? diffRemove,
    Color? diffRemoveSurface,
    Color? running,
  }) => AppColors(
    error: error ?? this.error,
    errorSurface: errorSurface ?? this.errorSurface,
    warning: warning ?? this.warning,
    success: success ?? this.success,
    diffAdd: diffAdd ?? this.diffAdd,
    diffAddSurface: diffAddSurface ?? this.diffAddSurface,
    diffRemove: diffRemove ?? this.diffRemove,
    diffRemoveSurface: diffRemoveSurface ?? this.diffRemoveSurface,
    running: running ?? this.running,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      error: Color.lerp(error, other.error, t)!,
      errorSurface: Color.lerp(errorSurface, other.errorSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      diffAdd: Color.lerp(diffAdd, other.diffAdd, t)!,
      diffAddSurface: Color.lerp(diffAddSurface, other.diffAddSurface, t)!,
      diffRemove: Color.lerp(diffRemove, other.diffRemove, t)!,
      diffRemoveSurface: Color.lerp(diffRemoveSurface, other.diffRemoveSurface, t)!,
      running: Color.lerp(running, other.running, t)!,
    );
  }
}

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFEDEDED),
  onPrimary: Color(0xFF000000),
  primaryContainer: Color(0xFF262626),
  onPrimaryContainer: Color(0xFFEDEDED),
  secondary: Color(0xFFBDBDBD),
  onSecondary: Color(0xFF000000),
  secondaryContainer: Color(0xFF1A1A1A),
  onSecondaryContainer: Color(0xFFEDEDED),
  tertiary: Color(0xFFBDBDBD),
  onTertiary: Color(0xFF000000),
  tertiaryContainer: Color(0xFF262626),
  onTertiaryContainer: Color(0xFFEDEDED),
  error: Color(0xFFE07A76),
  onError: Color(0xFF000000),
  errorContainer: Color(0xFF2A1413),
  onErrorContainer: Color(0xFFF2B8B5),
  surface: Color(0xFF000000),
  onSurface: Color(0xFFEDEDED),
  surfaceDim: Color(0xFF000000),
  surfaceBright: Color(0xFF1E1E1E),
  surfaceContainerLowest: Color(0xFF000000),
  surfaceContainerLow: Color(0xFF0B0B0B),
  surfaceContainer: Color(0xFF121212),
  surfaceContainerHigh: Color(0xFF1A1A1A),
  surfaceContainerHighest: Color(0xFF262626),
  onSurfaceVariant: Color(0xFF8F8F8F),
  outline: Color(0xFF5C5C5C),
  outlineVariant: Color(0xFF262626),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFEDEDED),
  onInverseSurface: Color(0xFF000000),
  inversePrimary: Color(0xFF111111),
  surfaceTint: Colors.transparent,
);

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF111111),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFDDDDDD),
  onPrimaryContainer: Color(0xFF111111),
  secondary: Color(0xFF444444),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE8E8E8),
  onSecondaryContainer: Color(0xFF111111),
  tertiary: Color(0xFF444444),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFDDDDDD),
  onTertiaryContainer: Color(0xFF111111),
  error: Color(0xFFB0413C),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFBECEB),
  onErrorContainer: Color(0xFF5C1512),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF111111),
  surfaceDim: Color(0xFFDDDDDD),
  surfaceBright: Color(0xFFE4E4E4),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F7F7),
  surfaceContainer: Color(0xFFF0F0F0),
  surfaceContainerHigh: Color(0xFFE8E8E8),
  surfaceContainerHighest: Color(0xFFDDDDDD),
  onSurfaceVariant: Color(0xFF5C5C5C),
  outline: Color(0xFF8F8F8F),
  outlineVariant: Color(0xFFDDDDDD),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF111111),
  onInverseSurface: Color(0xFFFFFFFF),
  inversePrimary: Color(0xFFEDEDED),
  surfaceTint: Colors.transparent,
);

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
