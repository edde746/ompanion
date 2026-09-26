import 'package:omp_core/rpc.dart';

import 'settings_schema.dart';

/// `accounts.list`: one row per provider with stored credentials, the current model's provider and every provider
/// models.yml adds; the kind of each of omp's login providers.
final class AccountsState {
  AccountsState.fromJson(Map<String, Object?> json)
    : currentProvider = json.optString('currentProvider'),
      providers = [for (final row in json.objects('providers')) ProviderAccounts.fromJson(row)],
      logins = {
        for (final row in json.objects('logins'))
          row.string('provider'): switch (row.string('kind')) {
            'key' => LoginKind.key,
            'optional_key' => LoginKind.optionalKey,
            'flow' => LoginKind.flow,
            final kind => throw FormatException('unknown login kind "$kind"'),
          },
      };

  final String? currentProvider;
  final List<ProviderAccounts> providers;
  final Map<String, LoginKind> logins;
}

/// What omp's `/login` asks for a provider.
enum LoginKind {
  /// Only an API key, which the row's key field stores the same way.
  key,

  /// An API key that may stay empty: a local server without auth.
  optionalKey,

  /// A browser, device-code or multi-prompt sign-in that only omp's `login` runs.
  flow,
}

/// Where a provider's working auth comes from (`source.kind`).
enum AuthSourceKind { runtime, config, oauth, apiKey, env }

final class ProviderAccounts {
  ProviderAccounts.fromJson(Map<String, Object?> json)
    : provider = json.string('provider'),
      name = json.string('name'),
      sourceKind = switch (json.optObject('source')?.string('kind')) {
        null => null,
        'runtime' => AuthSourceKind.runtime,
        'config' => AuthSourceKind.config,
        'oauth' => AuthSourceKind.oauth,
        'api_key' => AuthSourceKind.apiKey,
        'env' => AuthSourceKind.env,
        final kind => throw FormatException('unknown auth source kind "$kind"'),
      },
      envVar = json.optObject('source')?.optString('envVar'),
      credentials = [for (final row in json.objects('credentials')) StoredCredential.fromJson(row)];

  final String provider;
  final String name;

  /// Null when nothing authenticates the provider.
  final AuthSourceKind? sourceKind;
  final String? envVar;
  final List<StoredCredential> credentials;

  /// A models.yml key, an environment variable or a runtime override wins over the stored credentials.
  bool get storedOverridden =>
      credentials.isNotEmpty &&
      (sourceKind == AuthSourceKind.config || sourceKind == AuthSourceKind.env || sourceKind == AuthSourceKind.runtime);
}

/// How a provider authenticates, as the accounts list names it.
enum ProviderKind {
  /// A sign-in flow: a browser, a device code or several prompts.
  account,

  /// A pasted API key.
  apiKey,

  /// A server on the machine or the network whose key is optional.
  local,
}

/// One provider of the accounts list: omp's login providers, the providers of the available models and every
/// provider `accounts.list` names (stored credentials, models.yml), merged by id.
final class ProviderRow {
  const ProviderRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.canSignIn,
    required this.current,
    this.accounts,
    this.authenticated = false,
  });

  final String id;
  final String name;
  final ProviderKind kind;

  /// omp's `login` runs a flow for this id that the key field does not replace.
  final bool canSignIn;

  /// The provider of the current model.
  final bool current;

  /// Stored credentials and the working source; null when `accounts.list` does not name the provider.
  final ProviderAccounts? accounts;

  /// `get_login_providers` reports a working credential.
  final bool authenticated;

  List<StoredCredential> get credentials => accounts?.credentials ?? const [];
  bool get signedIn => authenticated || accounts?.sourceKind != null || credentials.isNotEmpty;
  bool get inUse => current || credentials.any((credential) => credential.active);
  bool get pinned => credentials.any((credential) => credential.sticky);
}

/// The rows of the accounts list: providers in use first, then signed-in ones, then the rest, each group by
/// name. [hidden] is a placeholder provider (the bootstrap model's) that stays out unless it has stored
/// credentials.
List<ProviderRow> providerRows({
  required AccountsState accounts,
  required List<RpcLoginProvider> login,
  required Iterable<String> modelProviders,
  String? hidden,
}) {
  final stored = {for (final row in accounts.providers) row.provider: row};
  final logins = {
    for (final provider in login)
      if (provider.available) provider.id: provider,
  };
  final rows = [
    for (final id in {...logins.keys, ...stored.keys, ...modelProviders})
      if (id != hidden || (stored[id]?.credentials.isNotEmpty ?? false))
        _row(id, accounts, logins[id], stored[id], hidden),
  ];
  int rank(ProviderRow row) => row.inUse ? 0 : (row.signedIn ? 1 : 2);
  return rows..sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

ProviderRow _row(String id, AccountsState accounts, RpcLoginProvider? login, ProviderAccounts? stored, String? hidden) {
  final kind = switch ((login, accounts.logins[id], stored)) {
    (_?, LoginKind.key, _) => ProviderKind.apiKey,
    (_?, LoginKind.optionalKey, _) => ProviderKind.local,
    (_?, _, _) => ProviderKind.account,
    (null, _, final row?) when row.credentials.isNotEmpty && row.credentials.every((credential) => credential.oauth) =>
      ProviderKind.account,
    _ => ProviderKind.apiKey,
  };
  return ProviderRow(
    id: id,
    name: login?.name ?? stored?.name ?? id,
    kind: kind,
    canSignIn: login != null && kind != ProviderKind.apiKey,
    current: id == accounts.currentProvider && id != hidden,
    accounts: stored,
    authenticated: login?.authenticated ?? false,
  );
}

/// The rows whose name or id contains every word of [query], case-insensitively.
List<ProviderRow> filterProviderRows(List<ProviderRow> rows, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return rows;
  return [
    for (final row in rows)
      if (words.every('${row.name} ${row.id}'.toLowerCase().contains)) row,
  ];
}

final class StoredCredential {
  StoredCredential.fromJson(Map<String, Object?> json)
    : credentialId = json.integer('credentialId'),
      oauth = json.string('type') == 'oauth',
      label = json.string('label'),
      detail = json.optString('detail'),
      active = json.boolean('active'),
      sticky = json.boolean('sticky'),
      pinnable = json.boolean('pinnable'),
      email = json.optObject('identity')?.optString('email'),
      orgName = json.optObject('identity')?.optString('orgName'),
      expires = switch (json.optObject('identity')?.optNumber('expires')) {
        final ms? when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      };

  final int credentialId;

  /// OAuth account; otherwise an API key.
  final bool oauth;
  final String label;
  final String? detail;

  /// The account the session uses.
  final bool active;

  /// Pinned or affine to the session (`/session pin`).
  final bool sticky;

  /// An OAuth account of the current model's provider.
  final bool pinnable;
  final String? email;
  final String? orgName;
  final DateTime? expires;
}

/// `roles.get` / `roles.set` / `roles.changed`.
final class RolesState {
  RolesState.fromJson(Map<String, Object?> json)
    : storage = json.string('storage'),
      roles = [for (final row in json.objects('roles')) ModelRole.fromJson(row)];

  /// Where omp's own model picker saves assignments: `global` or `project` (`modelRoleStorage`).
  final String storage;
  final List<ModelRole> roles;
}

final class ModelRole {
  ModelRole.fromJson(Map<String, Object?> json)
    : role = json.string('role'),
      name = json.string('name'),
      tag = json.optString('tag'),
      kindSection = json.string('section') == 'kind',
      model = json.optString('model'),
      provenance = Provenance.fromWire(json.string('provenance')),
      global = json.optString('global'),
      project = json.optString('project');

  final String role;
  final String name;
  final String? tag;

  /// A task-kind role (image, web, speech, …) rather than a chat role.
  final bool kindSection;

  /// Effective selector `provider/id[:thinking]`; null means auto-selection.
  final String? model;
  final Provenance provenance;
  final String? global;
  final String? project;
}

/// A model selector split into its model and optional thinking level: `anthropic/claude:high`.
({String model, String? thinking}) splitSelector(String selector) {
  final colon = selector.lastIndexOf(':');
  // Model ids may contain colons themselves (`ollama/llama3:8b`); only a known level is a suffix.
  if (colon > 0 && thinkingLevels.contains(selector.substring(colon + 1))) {
    return (model: selector.substring(0, colon), thinking: selector.substring(colon + 1));
  }
  return (model: selector, thinking: null);
}

/// omp's thinking levels, lowest first (`off` means no suffix).
const thinkingLevels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh'];
