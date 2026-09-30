import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omp_core/host.dart' show NotificationKind;

import '../app/palette.dart';
import '../database/app_database.dart';
import '../models/dock_tab.dart';

/// A typed app setting stored as a JSON value in the `settings` table.
sealed class Pref<T> {
  const Pref(this.key, this.defaultValue);

  final String key;
  final T defaultValue;

  /// Throws [FormatException] when a stored value does not fit the type.
  T decode(Object? json);

  Object? encode(T value);
}

final class BoolPref extends Pref<bool> {
  const BoolPref(super.key, super.defaultValue);

  @override
  bool decode(Object? json) => json is bool ? json : throw FormatException('setting $key: expected a bool');

  @override
  Object? encode(bool value) => value;
}

final class StringPref extends Pref<String> {
  const StringPref(super.key, super.defaultValue);

  @override
  String decode(Object? json) => json is String ? json : throw FormatException('setting $key: expected a string');

  @override
  Object? encode(String value) => value;
}

final class DoublePref extends Pref<double> {
  const DoublePref(super.key, super.defaultValue);

  /// JSON keeps a whole number as an int.
  @override
  double decode(Object? json) =>
      json is num ? json.toDouble() : throw FormatException('setting $key: expected a number');

  @override
  Object? encode(double value) => value;
}

final class EnumPref<T extends Enum> extends Pref<T> {
  const EnumPref(super.key, super.defaultValue, this.values);

  final List<T> values;

  @override
  T decode(Object? json) {
    for (final value in values) {
      if (value.name == json) return value;
    }
    throw FormatException('setting $key: unknown value $json');
  }

  @override
  Object? encode(T value) => value.name;
}

final class StringListPref extends Pref<List<String>> {
  const StringListPref(super.key, super.defaultValue);

  @override
  List<String> decode(Object? json) => json is List && json.every((item) => item is String)
      ? List.unmodifiable(json.cast<String>())
      : throw FormatException('setting $key: expected a list of strings');

  @override
  Object? encode(List<String> value) => value;
}

final class PalettePref extends Pref<AppPalette> {
  const PalettePref(super.key, super.defaultValue);

  @override
  AppPalette decode(Object? json) {
    try {
      return AppPalette.fromJson(json);
    } on FormatException catch (error) {
      throw FormatException('setting $key: ${error.message}');
    }
  }

  @override
  Object? encode(AppPalette value) => value.toJson();
}

abstract final class Prefs {
  static const themeMode = EnumPref<AppThemeMode>('theme_mode', AppThemeMode.system, AppThemeMode.values);

  /// The Custom theme's colours. Unset until the first switch to Custom, which starts it from the theme on screen.
  static const customTheme = PalettePref('custom_theme', AppPalette.dark);

  static const sidebarOpen = BoolPref('sidebar_open', true);
  static const dockOpen = BoolPref('dock_open', true);
  static const dockTab = EnumPref<DockTab>('dock_tab', DockTab.agents, DockTab.values);

  /// Widths of the sidebar and the inline dock on wide layouts, as the user dragged them (`paneWidths` fits them to
  /// the window).
  static const sidebarWidth = DoublePref('sidebar_width', 300);
  static const dockWidth = DoublePref('dock_width', 340);

  /// The usage pane masks account emails, ids and organizations, for screenshots.
  static const usageHideIdentities = BoolPref('usage_hide_identities', false);

  /// Whether the sidebar hides the sessions of the project folder [cwd] on machine [machineId].
  static BoolPref projectCollapsed(String machineId, String cwd) =>
      BoolPref('${projectCollapsedPrefix(machineId)}$cwd', false);

  /// The key prefix of machine [machineId]'s [projectCollapsed] settings, which go with the machine.
  static String projectCollapsedPrefix(String machineId) => 'project_collapsed:$machineId:';

  /// Set once "this computer" was added automatically, so deleting it sticks.
  static const localMachineSeeded = BoolPref('local_machine_seeded', false);

  /// Namespaces this install's RPC request ids and companion call ids on shared sessions; generated once.
  /// Empty until `main` generates it.
  static const deviceId = StringPref('device_id', '');

  /// Desktops: notifications about the sessions this device has open.
  static const desktopNotifications = BoolPref('desktop_notifications', true);

  /// Phones: push notifications from the machines (docs/contracts/push.md); off until the user turns them on.
  static const pushNotifications = BoolPref('push_notifications', false);

  /// Whether this device wants notifications of [kind]: the desktop's and the phone's registration `kinds`.
  static BoolPref notify(NotificationKind kind) => BoolPref('notify_${kind.name}', true);

  /// Machines that may still hold this phone's registration file after push was turned off; each one's next
  /// connect removes it.
  static const pushRemovals = StringListPref('push_removals', []);
}

/// App settings, loaded once at startup; reads are synchronous afterwards.
class SettingsProvider extends ChangeNotifier {
  SettingsProvider._(this._db, this._values);

  static Future<SettingsProvider> load(AppDatabase db) async {
    final rows = await db.select(db.settings).get();
    return SettingsProvider._(db, {for (final row in rows) row.key: jsonDecode(row.value)});
  }

  final AppDatabase _db;
  final Map<String, Object?> _values;

  T get<T>(Pref<T> pref) => _values.containsKey(pref.key) ? pref.decode(_values[pref.key]) : pref.defaultValue;

  /// Whether [pref] was ever set on this device.
  bool isSet(Pref<Object?> pref) => _values.containsKey(pref.key);

  Future<void> set<T>(Pref<T> pref, T value) async {
    final json = pref.encode(value);
    _values[pref.key] = json;
    notifyListeners();
    await _db
        .into(_db.settings)
        .insertOnConflictUpdate(SettingsCompanion.insert(key: pref.key, value: jsonEncode(json)));
  }
}
