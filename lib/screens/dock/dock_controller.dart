import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../files/file_workspace.dart';
import '../../models/dock_tab.dart';
import '../../providers/machines_provider.dart';
import '../../terminal/terminal_deck.dart';

/// A file another screen asked the Files tab to open.
final class FileRequest {
  const FileRequest(this.path, {this.line});

  /// Absolute, host-native, `~/…`, or relative to the session's directory.
  final String path;

  /// 1-based line to reveal.
  final int? line;
}

/// The right dock's state that outlives its widgets: requests from other screens (switch tab, open a file, open a
/// subagent), the terminals and the Files workspaces of every machine, and the terminal font size.
class DockController extends ChangeNotifier {
  DockController(this._machines) {
    _machines.addListener(_onMachinesChanged);
  }

  final MachinesProvider _machines;
  final _reveals = StreamController<DockTab>.broadcast();
  final _terminals = <String, TerminalDeck>{};
  final _workspaces = <String, FileWorkspace>{};
  FileRequest? _fileRequest;
  String? _agentRequest;
  double _terminalFontSize = 13;

  /// Tabs to bring into view. The shell shows the dock (inline, drawer, or the narrow panels page) and selects the
  /// tab.
  Stream<DockTab> get reveals => _reveals.stream;

  void show(DockTab tab) => _reveals.add(tab);

  /// Opens [path] in the Files tab of the active session's machine and reveals [line].
  void openFile(String path, {int? line}) {
    _fileRequest = FileRequest(path, line: line);
    notifyListeners();
    show(DockTab.files);
  }

  /// Selects the agent [id] in the Agent Hub.
  void openSubagent(String id) {
    _agentRequest = id;
    notifyListeners();
    show(DockTab.agents);
  }

  /// The pending file request, once.
  FileRequest? takeFileRequest() {
    final request = _fileRequest;
    _fileRequest = null;
    return request;
  }

  /// The pending agent selection, once.
  String? takeAgentRequest() {
    final request = _agentRequest;
    _agentRequest = null;
    return request;
  }

  TerminalDeck terminals(String machineId) => _terminals.putIfAbsent(machineId, TerminalDeck.new);

  FileWorkspace files(String machineId) => _workspaces.putIfAbsent(machineId, FileWorkspace.new);

  /// A deleted machine's shells end and its open files close, unsaved edits included: nothing reaches it any more.
  void _onMachinesChanged() {
    final ids = {for (final machine in _machines.machines) machine.id};
    for (final id in [..._terminals.keys]) {
      if (!ids.contains(id)) _terminals.remove(id)!.dispose();
    }
    for (final id in [..._workspaces.keys]) {
      if (!ids.contains(id)) _workspaces.remove(id)!.dispose();
    }
  }

  double get terminalFontSize => _terminalFontSize;

  static const minTerminalFontSize = 8.0;
  static const maxTerminalFontSize = 28.0;

  void setTerminalFontSize(double size) {
    final clamped = size.clamp(minTerminalFontSize, maxTerminalFontSize).toDouble();
    if (clamped == _terminalFontSize) return;
    _terminalFontSize = clamped;
    notifyListeners();
  }

  @override
  void dispose() {
    _machines.removeListener(_onMachinesChanged);
    for (final deck in _terminals.values) {
      deck.dispose();
    }
    for (final workspace in _workspaces.values) {
      workspace.dispose();
    }
    unawaited(_reveals.close());
    super.dispose();
  }
}
