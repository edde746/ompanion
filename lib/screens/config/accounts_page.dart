import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../../app/theme.dart';
import '../../config/accounts.dart';
import '../../config/config_target.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_search_field.dart';
import '../chat/transcript/code_style.dart';
import 'config_widgets.dart';
import 'login_dialogs.dart';

/// Every provider omp can use on the machine as one searchable list: sign-in providers, the providers of the
/// available models, the ones models.yml adds and the ones with stored credentials. A row opens in place to sign
/// in, paste an API key, pin an account or log out; the last row stores a key under any other provider id.
///
/// The credentials come from the active session on this machine when there is one, because `active`, `sticky`
/// and `pinnable` describe that session; otherwise from the control process. Credentials are machine-wide.
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  AccountsState? _accounts;
  List<RpcLoginProvider> _loginProviders = const [];
  Set<String> _modelProviders = const {};
  Object? _error;
  bool _loading = true;
  String _query = '';
  String? _open;

  LiveSession? get _project => widget.target.projectSession;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final control = await widget.target.control();
      final source = _project ?? control;
      final accounts = AccountsState.fromJson(asJsonObject(await source.companion.call('accounts.list'), 'accounts.list'));
      final providers = await control.rpc.getLoginProviders();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _loginProviders = providers;
      });
      // The model list is large over SSH; its providers may join the list after the page shows.
      unawaited(
        widget.target.sessions.models(widget.target.machine, control.rpc).then((models) {
          if (mounted) setState(() => _modelProviders = {for (final model in models) model.provider});
        }, onError: (Object error) => appLogger.w('model list for the provider list failed', error: error)),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Credentials changed: the available models follow, and the lists here.
  Future<void> _changed() async {
    final control = await widget.target.control();
    await widget.target.sessions.models(widget.target.machine, control.rpc, refresh: true);
    await _load();
  }

  Future<void> _signIn(ProviderRow row) async {
    LiveSession? control;
    if (!await runReporting(context, () async => control = await widget.target.control()) || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RpcLoginDialog(target: widget.target, control: control!, providerId: row.id, providerName: row.name),
    );
    if (mounted) await runReporting(context, _changed);
  }

  /// The key goes to the machine as a 0600 file; the companion stores it in omp's credential store and deletes
  /// the file.
  Future<bool> _setKey(String provider, String name, String key) {
    final t = context.t;
    return runReporting(context, () async {
      final control = await widget.target.control();
      final file = await widget.target.uploadSecret(key.trim());
      try {
        await control.companion.call('accounts.setKey', {'provider': provider, 'keyFile': file});
      } finally {
        await widget.target.discardSecret(file);
      }
      await _changed();
    }, done: t.config.accounts.keyStored(provider: name), secret: true);
  }

  Future<void> _logout(ProviderRow row, StoredCredential credential) async {
    final t = context.t;
    final confirmed = await confirmAction(
      context,
      title: t.config.accounts.logoutTitle(account: credential.label),
      body: t.config.accounts.logoutBody(provider: row.name),
      action: t.config.accounts.logout,
    );
    if (!confirmed || !mounted) return;
    await runReporting(context, () async {
      final control = await widget.target.control();
      await control.companion.call('accounts.logout', {'provider': row.id, 'credentialId': credential.credentialId});
      await _changed();
    });
  }

  Future<void> _pin(StoredCredential credential) async {
    final session = _project;
    if (session == null) return;
    await runReporting(context, () async {
      await session.companion.call('accounts.pin', {'credentialId': credential.credentialId});
      await _load();
    }, done: context.t.config.accounts.pinned);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accounts = _accounts;
    final bootstrap = widget.target.runtime.controlIsBootstrap;
    final rows = accounts == null
        ? const <ProviderRow>[]
        : filterProviderRows(
            providerRows(
              accounts: accounts,
              login: _loginProviders,
              modelProviders: _modelProviders,
              hidden: bootstrap ? _bootstrapProvider : null,
            ),
            _query,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.accounts,
          subtitle: _project == null ? t.config.accounts.machineWide : t.config.accounts.sessionView(path: _project!.cwd),
          actions: [
            RefreshAction(loading: _loading, onPressed: _load),
          ],
        ),
        if (bootstrap) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: ConfigBanner(t.config.accounts.bootstrap, error: true)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: AppSearchField(
            key: const ValueKey('accounts-search'),
            hint: t.config.accounts.search,
            onChanged: (text) => setState(() => _query = text),
          ),
        ),
        Expanded(
          child: switch ((accounts, _error)) {
            (null, final error?) => Center(child: ConfigError(error, onRetry: _load)),
            (null, _) => const Center(child: CircularProgressIndicator()),
            _ => ListView(
              // The rows' fill lines up with the search field above.
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Text(t.config.accounts.noMatches),
                  ),
                for (final row in rows)
                  _ProviderTile(
                    key: ValueKey('provider-${row.id}'),
                    row: row,
                    open: _open == row.id,
                    remote: !widget.target.isThisComputer,
                    canPin: _project != null,
                    onToggle: () => setState(() => _open = _open == row.id ? null : row.id),
                    onSignIn: () => unawaited(_signIn(row)),
                    onSaveKey: (key) => _setKey(row.id, row.name, key),
                    onLogout: (credential) => unawaited(_logout(row, credential)),
                    onPin: (credential) => unawaited(_pin(credential)),
                  ),
                _OtherProviderTile(
                  key: const ValueKey('provider-other'),
                  open: _open == _otherRow,
                  initialId: rows.isEmpty ? _query.trim() : '',
                  onToggle: () => setState(() => _open = _open == _otherRow ? null : _otherRow),
                  onSaveKey: (provider, key) async {
                    final saved = await _setKey(provider, provider, key);
                    if (saved && mounted) setState(() => _open = provider);
                    return saved;
                  },
                ),
              ],
            ),
          },
        ),
      ],
    );
  }
}

/// On a machine where no model works yet, the control process runs on this placeholder provider and
/// `accounts.list` names it as current; it is not a credential of the machine.
final _bootstrapProvider = bootstrapModel.split('/').first;

/// [_AccountsPageState._open] of the "Other provider" row; no provider id is empty.
const _otherRow = '';

/// One provider: name, kind and status on one dense line; open, the working source in plain words, stored
/// credentials, sign-in and an API key field.
class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    super.key,
    required this.row,
    required this.open,
    required this.remote,
    required this.canPin,
    required this.onToggle,
    required this.onSignIn,
    required this.onSaveKey,
    required this.onLogout,
    required this.onPin,
  });

  final ProviderRow row;
  final bool open;
  final bool remote;
  final bool canPin;
  final VoidCallback onToggle;
  final VoidCallback onSignIn;
  final Future<bool> Function(String key) onSaveKey;
  final ValueChanged<StoredCredential> onLogout;
  final ValueChanged<StoredCredential> onPin;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final radius = BorderRadius.circular(AppSizes.radius);
    final header = InkWell(
      borderRadius: radius,
      onTap: onToggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(row.name, style: theme.textTheme.bodyMedium),
                    if (row.name != row.id)
                      Text(row.id, style: codeTextStyle(theme).copyWith(fontSize: theme.textTheme.labelSmall?.fontSize, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 4,
                children: [
                  if (row.inUse) ConfigTag(t.config.accounts.active, color: scheme.onSurface),
                  if (row.pinned) ConfigTag(t.config.accounts.sticky, color: scheme.onSurface),
                  if (row.signedIn) ConfigTag(t.config.accounts.signedIn, color: colors.success),
                  ConfigTag(switch (row.kind) {
                    ProviderKind.account => t.config.accounts.kind.account,
                    ProviderKind.apiKey => t.config.accounts.kind.apiKey,
                    ProviderKind.local => t.config.accounts.kind.local,
                  }),
                ],
              ),
              const SizedBox(width: 4),
              Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
    if (!open) return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: header);
    final accounts = row.accounts;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_sourceText(t, row), style: muted),
                  if (accounts != null && accounts.storedOverridden)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        switch (accounts.sourceKind) {
                          AuthSourceKind.env => t.config.accounts.overridden.env(name: accounts.envVar ?? '?'),
                          AuthSourceKind.runtime => t.config.accounts.overridden.runtime,
                          _ => t.config.accounts.overridden.config,
                        },
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
                      ),
                    ),
                  for (final credential in row.credentials) _CredentialRow(credential: credential, canPin: canPin, onLogout: onLogout, onPin: onPin),
                  if (row.canSignIn) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          key: ValueKey('sign-in-${row.id}'),
                          onPressed: onSignIn,
                          icon: const Icon(Icons.login, size: 18),
                          label: Text(t.config.accounts.signIn),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(remote ? t.config.accounts.oauthRemote : t.config.accounts.oauthLocal, style: muted)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _KeyField(onSave: onSaveKey),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A key for a provider id the list does not show; open, the id and the key.
class _OtherProviderTile extends StatefulWidget {
  const _OtherProviderTile({super.key, required this.open, required this.initialId, required this.onToggle, required this.onSaveKey});

  final bool open;

  /// Fills the id when the row opens: the search text that matched no provider.
  final String initialId;
  final VoidCallback onToggle;
  final Future<bool> Function(String provider, String key) onSaveKey;

  @override
  State<_OtherProviderTile> createState() => _OtherProviderTileState();
}

class _OtherProviderTileState extends State<_OtherProviderTile> {
  final _id = TextEditingController();

  @override
  void didUpdateWidget(_OtherProviderTile old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open && widget.initialId.isNotEmpty) _id.text = widget.initialId;
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = InkWell(
      borderRadius: BorderRadius.circular(AppSizes.radius),
      onTap: widget.onToggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(t.config.accounts.other, style: theme.textTheme.bodyMedium)),
              Icon(widget.open ? Icons.expand_less : Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
    if (!widget.open) return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: header);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.config.accounts.otherNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('other-provider-id'),
                    controller: _id,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(hintText: t.config.accounts.otherId),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSizes.gap),
                  _KeyField(ready: _id.text.trim().isNotEmpty, onSave: (key) => widget.onSaveKey(_id.text.trim(), key)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What authenticates [row] now, in plain words.
String _sourceText(Translations t, ProviderRow row) => switch (row.accounts?.sourceKind) {
  AuthSourceKind.runtime => t.config.accounts.source.runtime,
  AuthSourceKind.config => t.config.accounts.source.config,
  AuthSourceKind.oauth => t.config.accounts.source.oauth,
  AuthSourceKind.apiKey => t.config.accounts.source.apiKey,
  AuthSourceKind.env => t.config.accounts.source.env(name: row.accounts?.envVar ?? '?'),
  null when row.authenticated => t.config.accounts.source.working,
  null when row.kind == ProviderKind.account => t.config.accounts.source.none,
  null => t.config.accounts.source.noKey,
};

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({required this.credential, required this.canPin, required this.onLogout, required this.onPin});

  final StoredCredential credential;
  final bool canPin;
  final ValueChanged<StoredCredential> onLogout;
  final ValueChanged<StoredCredential> onPin;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(credential.oauth ? Icons.account_circle_outlined : Icons.vpn_key_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(credential.label, style: theme.textTheme.bodyMedium),
                if (credentialStatus(t, credential) case final status?)
                  Text(status, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (credential.pinnable && canPin && !credential.sticky)
            TextButton(onPressed: () => onPin(credential), child: Text(t.config.accounts.pin)),
          TextButton(onPressed: () => onLogout(credential), child: Text(t.config.accounts.logout)),
        ],
      ),
    );
  }
}

/// The line under a stored credential's label: what the label does not already say. omp labels an API key
/// "API key #n" and details it "stored API key #n"; an OAuth account's label is its email and its detail the other
/// identity parts.
String? credentialStatus(Translations t, StoredCredential credential) {
  final parts = [
    if (credential.oauth) ?credential.detail,
    if (credential.active) t.config.accounts.active,
    if (credential.sticky) t.config.accounts.sticky,
    if (credential.expires case final expires?) t.config.accounts.expires(date: _date(expires)),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _date(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// A pasted API key for the row's provider and its save button, one control height.
class _KeyField extends StatefulWidget {
  const _KeyField({required this.onSave, this.ready = true});

  final Future<bool> Function(String key) onSave;

  /// Everything besides the key is filled in.
  final bool ready;

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  final _key = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_key.text.trim().isEmpty || !widget.ready || _saving) return;
    setState(() => _saving = true);
    final saved = await widget.onSave(_key.text);
    if (!mounted) return;
    if (saved) _key.clear();
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('api-key-value'),
            controller: _key,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(hintText: t.config.accounts.keyHint),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: AppSizes.gap),
        FilledButton.tonal(
          key: const ValueKey('api-key-save'),
          onPressed: _saving || !widget.ready || _key.text.trim().isEmpty ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.config.accounts.saveKey),
        ),
      ],
    );
  }
}
