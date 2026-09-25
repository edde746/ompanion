/// Development and test overrides, set with `--dart-define`. All unset in normal builds.
library;

/// `OMP_APP_LOCAL_HOME=<dir>`: "this computer" runs every command with `HOME=<dir>`, so development builds
/// and UI tests drive an isolated omp home (`testing/dev-machine.sh`) and never the user's real `~/.omp`.
String? get devLocalHome => _nonEmpty(const String.fromEnvironment('OMP_APP_LOCAL_HOME'));

/// The environment of every process "this computer" starts while [devLocalHome] is set, else null. `PATH` holds
/// only the system directories, so the probe finds `<home>/.local/bin/omp` and never the user's own omp (e.g.
/// in `/opt/homebrew/bin`); omp's location variables are emptied, which omp reads as unset.
Map<String, String>? get devLocalEnvironment {
  final home = devLocalHome;
  if (home == null) return null;
  return {
    'HOME': home,
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'PI_CODING_AGENT_DIR': '',
    'PI_CONFIG_DIR': '',
    'OMP_PROFILE': '',
    'PI_PROFILE': '',
    'XDG_DATA_HOME': '',
    'XDG_STATE_HOME': '',
    'XDG_CACHE_HOME': '',
  };
}

/// `OMP_APP_DATA_DIR=<dir>`: the database and other app files live in `<dir>` instead of the platform's
/// application support directory, so several app instances (or a test run) do not share state.
String? get devDataDir => _nonEmpty(const String.fromEnvironment('OMP_APP_DATA_DIR'));

/// `OMP_APP_SECRET_PREFIX=<prefix>`: prepended to every secure-storage key, so the keychain entries of
/// such instances do not collide either. Empty when unset.
String get devSecretPrefix => const String.fromEnvironment('OMP_APP_SECRET_PREFIX');

String? _nonEmpty(String value) => value.isEmpty ? null : value;
