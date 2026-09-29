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
///
/// The user's last choice of place wins. A navigation that finishes later, such as a session that takes a while to
/// open, takes a turn ([takeTurn]) when the user asks for it and shows its result only while [isLatest] holds for that
/// turn. Every [select] takes a turn too, so any later click supersedes it.
class ShellProvider extends ChangeNotifier {
  ShellSelection _selection = const HomeSelection();
  bool _panelsPageOpen = false;
  int _turn = 0;

  ShellSelection get selection => _selection;

  /// Narrow layout only: the dock panels shown as their own page.
  bool get panelsPageOpen => _panelsPageOpen;

  /// Starts a navigation that finishes later; see [isLatest].
  int takeTurn() => ++_turn;

  /// Whether no navigation started since the one that took [turn].
  bool isLatest(int turn) => turn == _turn;

  void select(ShellSelection selection) {
    _turn++;
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
