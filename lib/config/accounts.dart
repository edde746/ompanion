import 'package:omp_core/rpc.dart';

import 'settings_schema.dart';

/// `accounts.list`: one row per provider with stored credentials, plus the current model's provider.
final class AccountsState {
  AccountsState.fromJson(Map<String, Object?> json)
    : currentProvider = json.optString('currentProvider'),
      providers = [for (final row in json.objects('providers')) ProviderAccounts.fromJson(row)];

  final String? currentProvider;
  final List<ProviderAccounts> providers;
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
      sourceText = json.optString('sourceText'),
      credentials = [for (final row in json.objects('credentials')) StoredCredential.fromJson(row)];

  final String provider;
  final String name;

  /// Null when nothing authenticates the provider.
  final AuthSourceKind? sourceKind;
  final String? envVar;

  /// omp's own description of the source, e.g. "config override (models.yml)".
  final String? sourceText;
  final List<StoredCredential> credentials;
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
