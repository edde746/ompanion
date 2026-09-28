import 'dart:io';

/// Where this build is distributed, from `--dart-define=OMPANION_CHANNEL=<name>` (default `direct`).
///
/// The only place that reads the flag; features a store forbids are gated here (docs/PLAN.md §9).
enum BuildChannel {
  /// GitHub releases, the Flatpak among them: full feature set.
  direct,
  macappstore,
  appstore,
  play,
  flathub;

  /// Throws [ArgumentError] at startup for an unknown channel name.
  static final BuildChannel current = BuildChannel.values.byName(
    const String.fromEnvironment('OMPANION_CHANNEL', defaultValue: 'direct'),
  );
}

bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// "This computer" runs omp and shells through `Process`. The Mac App Store sandbox forbids child processes
/// outside the container. The GitHub Flatpak is a `direct` build that starts them on the host (`hostStart`).
bool get thisComputerAvailable => isDesktop && BuildChannel.current == BuildChannel.direct;

/// Reading `~/.ssh` (config aliases, `known_hosts`) and running local CLIs (`ssh -G`, `tailscale`).
/// Sandboxed desktop channels get no access to the user's home or host binaries.
bool get hostAccessAvailable => isDesktop && BuildChannel.current == BuildChannel.direct;
