import 'package:flutter/foundation.dart';

/// What the center pane (wide) or the pushed page (narrow) shows.
sealed class ShellSelection {
  const ShellSelection();
}

final class HomeSelection extends ShellSelection {
  const HomeSelection();
}

final class MachineSelection extends ShellSelection {
  const MachineSelection(this.machineId);

  final String machineId;

  @override
  bool operator ==(Object other) => other is MachineSelection && other.machineId == machineId;

  @override
  int get hashCode => machineId.hashCode;
}

final class KeysSelection extends ShellSelection {
  const KeysSelection();
}

/// Provider usage of every machine's accounts.
final class UsageSelection extends ShellSelection {
  const UsageSelection();
}

final class SettingsSelection extends ShellSelection {
  const SettingsSelection();
}

/// The chat of `SessionsProvider.active`.
final class SessionSelection extends ShellSelection {
  const SessionSelection();
}

/// Navigation state shared by the wide and the narrow layout, so resizing the window keeps the place.
class ShellProvider extends ChangeNotifier {
  ShellSelection _selection = const HomeSelection();
  bool _panelsPageOpen = false;

  ShellSelection get selection => _selection;

  /// Narrow layout only: the dock panels shown as their own page.
  bool get panelsPageOpen => _panelsPageOpen;


  void select(ShellSelection selection) {
    if (selection == _selection) return;
    _selection = selection;
    notifyListeners();
  }

  void setPanelsPageOpen(bool open) {
    if (open == _panelsPageOpen) return;
    _panelsPageOpen = open;
    notifyListeners();
  }
}
