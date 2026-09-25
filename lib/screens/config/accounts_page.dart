import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../../config/accounts.dart';
import '../../config/config_target.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import 'config_widgets.dart';
import 'login_dialogs.dart';

/// Stored credentials per provider, OAuth login, API keys, logout and the account pin.
///
/// The list comes from the active session on this machine when there is one, because `active`, `sticky` and
/// `pinnable` describe that session; otherwise from the control process. Credentials are machine-wide.
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  AccountsState? _accounts;
  List<RpcLoginProvider>? _loginProviders;
  List<String> _knownProviders = const [];
  Object? _error;
  bool _loading = true;

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
        _knownProviders = {for (final row in accounts.providers) row.provider, for (final provider in providers) provider.id}.toList()
          ..sort();
      });
      // The model list is large over SSH; suggestions may arrive after the page shows.
      unawaited(
        widget.target.sessions.models(widget.target.machine, control.rpc).then((models) {
          if (!mounted) return;
          setState(() => _knownProviders = {..._knownProviders, for (final model in models) model.provider}.toList()..sort());
        }, onError: (Object error) => appLogger.w('model list for provider suggestions failed', error: error)),
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

  Future<void> _oauth(RpcLoginProvider provider) async {
    LiveSession? control;
    if (!await runReporting(context, () async => control = await widget.target.control()) || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RpcLoginDialog(target: widget.target, control: control!, providerId: provider.id, providerName: provider.name),
    );
    if (mounted) await runReporting(context, _changed);
  }

  Future<void> _setKey(String provider, String key) async {
    final t = context.t;
    await runReporting(context, () async {
      final control = await widget.target.control();
      final file = await widget.target.uploadSecret(key.trim());
      try {
        await control.companion.call('accounts.setKey', {'provider': provider, 'keyFile': file});
      } finally {
        await widget.target.discardSecret(file);
      }
      await _changed();
    }, done: t.config.accounts.keyStored(provider: provider), secret: true);
  }

  Future<void> _logout(ProviderAccounts provider, StoredCredential credential) async {
    final t = context.t;
    final confirmed = await confirmAction(
      context,
      title: t.config.accounts.logoutTitle(account: credential.label),
      body: t.config.accounts.logoutBody(provider: provider.name),
      action: t.config.accounts.logout,
    );
    if (!confirmed || !mounted) return;
    await runReporting(context, () async {
      final control = await widget.target.control();
      await control.companion.call('accounts.logout', {'provider': provider.provider, 'credentialId': credential.credentialId});
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
    final theme = Theme.of(context);
    final accounts = _accounts;
    final bootstrap = widget.target.runtime.controlIsBootstrap;
    final providers = [
      for (final provider in accounts?.providers ?? const <ProviderAccounts>[])
        if (!bootstrap || provider.provider != _bootstrapProvider) provider,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.accounts,
          subtitle: _project == null ? t.config.accounts.machineWide : t.config.accounts.sessionView(path: _project!.cwd),
          actions: [IconButton(tooltip: t.config.refresh, onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              if (_loading && accounts == null) const Center(child: CircularProgressIndicator()),
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (accounts != null) ...[
                if (bootstrap)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(t.config.accounts.bootstrap, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
                  ),
                Text(t.config.accounts.stored, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (providers.isEmpty) Text(t.config.accounts.none),
                for (final provider in providers)
                  _ProviderCard(
                    provider: provider,
                    current: provider.provider == accounts.currentProvider,
                    canPin: _project != null,
                    onLogout: (credential) => unawaited(_logout(provider, credential)),
                    onPin: (credential) => unawaited(_pin(credential)),
                  ),
                const SizedBox(height: 24),
                Text(t.config.accounts.oauth, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  widget.target.isThisComputer ? t.config.accounts.oauthLocal : t.config.accounts.oauthRemote,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final provider in _loginProviders ?? const <RpcLoginProvider>[])
                      if (provider.available)
                        ActionChip(
                          avatar: Icon(provider.authenticated ? Icons.check_circle : Icons.login, size: 18),
                          label: Text(provider.name),
                          tooltip: provider.id,
                          onPressed: () => unawaited(_oauth(provider)),
                        ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(t.config.accounts.apiKey, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(t.config.accounts.apiKeyHint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                _ApiKeyForm(providers: _knownProviders, onSave: _setKey),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// On a machine where no model works yet, the control process runs on this placeholder provider and
/// `accounts.list` names it as current; it is not a credential of the machine.
final _bootstrapProvider = bootstrapModel.split('/').first;

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.provider, required this.current, required this.canPin, required this.onLogout, required this.onPin});

  final ProviderAccounts provider;
  final bool current;
  final bool canPin;
  final ValueChanged<StoredCredential> onLogout;
  final ValueChanged<StoredCredential> onPin;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(provider.name, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(provider.provider, style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline)),
                if (current) ...[const SizedBox(width: 8), Chip(label: Text(t.config.accounts.currentModel), visualDensity: VisualDensity.compact)],
              ],
            ),
            Text(
              provider.sourceText ?? t.config.accounts.noSource,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (provider.envVar case final envVar?) Text(t.config.accounts.fromEnv(name: envVar), style: theme.textTheme.bodySmall),
            for (final credential in provider.credentials)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(credential.oauth ? Icons.account_circle_outlined : Icons.vpn_key_outlined),
                title: Text(credential.label),
                subtitle: Text(
                  [
                    credential.oauth ? t.config.accounts.oauthAccount : t.config.accounts.apiKeyAccount,
                    ?credential.detail,
                    if (credential.active) t.config.accounts.active,
                    if (credential.sticky) t.config.accounts.sticky,
                    if (credential.expires case final expires?) t.config.accounts.expires(date: _date(expires)),
                  ].join(' · '),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (credential.pinnable && canPin && !credential.sticky)
                      TextButton(onPressed: () => onPin(credential), child: Text(t.config.accounts.pin)),
                    TextButton(onPressed: () => onLogout(credential), child: Text(t.config.accounts.logout)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _date(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// Provider id and key. The key goes to the machine as a 0600 file; the companion stores it in omp's
/// credential store and deletes the file.
class _ApiKeyForm extends StatefulWidget {
  const _ApiKeyForm({required this.providers, required this.onSave});

  final List<String> providers;
  final Future<void> Function(String provider, String key) onSave;

  @override
  State<_ApiKeyForm> createState() => _ApiKeyFormState();
}

class _ApiKeyFormState extends State<_ApiKeyForm> {
  final _key = TextEditingController();
  String _provider = '';
  bool _saving = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_provider.trim().isEmpty || _key.text.trim().isEmpty) return;
    setState(() => _saving = true);
    await widget.onSave(_provider.trim(), _key.text);
    _key.clear();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 240,
          child: Autocomplete<String>(
            optionsBuilder: (value) => widget.providers.where((provider) => provider.contains(value.text.trim().toLowerCase())),
            onSelected: (provider) => setState(() => _provider = provider),
            fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
              key: const ValueKey('api-key-provider'),
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: t.config.accounts.provider),
              onChanged: (value) => setState(() => _provider = value),
            ),
          ),
        ),
        SizedBox(
          width: 320,
          child: TextField(
            key: const ValueKey('api-key-value'),
            controller: _key,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: t.config.accounts.key),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        FilledButton(
          key: const ValueKey('api-key-save'),
          onPressed: _saving || _provider.trim().isEmpty || _key.text.trim().isEmpty ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.config.accounts.saveKey),
        ),
      ],
    );
  }
}
