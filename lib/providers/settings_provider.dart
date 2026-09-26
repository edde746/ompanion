import 'dart:convert';

import 'package:flutter/material.dart';

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

abstract final class Prefs {
  static const themeMode = EnumPref<ThemeMode>('theme_mode', ThemeMode.system, ThemeMode.values);
  static const sidebarOpen = BoolPref('sidebar_open', true);
  static const dockOpen = BoolPref('dock_open', true);
  static const dockTab = EnumPref<DockTab>('dock_tab', DockTab.agents, DockTab.values);

  /// Whether the sidebar hides the sessions of the project folder [cwd] on machine [machineId].
  static BoolPref projectCollapsed(String machineId, String cwd) =>
      BoolPref('project_collapsed:$machineId:$cwd', false);

  /// Set once "this computer" was added automatically, so deleting it sticks.
  static const localMachineSeeded = BoolPref('local_machine_seeded', false);

  /// Namespaces this install's RPC request ids and companion call ids on shared sessions; generated once.
  /// Empty until `main` generates it.
  static const deviceId = StringPref('device_id', '');
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

  Future<void> set<T>(Pref<T> pref, T value) async {
    final json = pref.encode(value);
    _values[pref.key] = json;
    notifyListeners();
    await _db
        .into(_db.settings)
        .insertOnConflictUpdate(SettingsCompanion.insert(key: pref.key, value: jsonEncode(json)));
  }
}
