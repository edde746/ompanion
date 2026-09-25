///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element
class Translations with BaseTranslations<AppLocale, Translations> {
	/// Returns the current translations of the given [context].
	///
	/// Usage:
	/// final t = Translations.of(context);
	static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	Translations({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  _meta = meta ?? TranslationMetadata(
		    locale: AppLocale.en,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ) {
		_meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <en>.
	final TranslationMetadata<AppLocale, Translations> _meta;
	@override TranslationMetadata<AppLocale, Translations> get $meta => _meta;

	/// Access flat map
	dynamic operator[](String key) => _meta.getTranslation(key);

	late final Translations _root = this; // ignore: unused_field

	Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

	// Translations
	late final Translations$app$en app = Translations$app$en.internal(_root);
	late final Translations$common$en common = Translations$common$en.internal(_root);
	late final Translations$shell$en shell = Translations$shell$en.internal(_root);
	late final Translations$dock$en dock = Translations$dock$en.internal(_root);
	late final Translations$sidebar$en sidebar = Translations$sidebar$en.internal(_root);
	late final Translations$machines$en machines = Translations$machines$en.internal(_root);
	late final Translations$auth$en auth = Translations$auth$en.internal(_root);
	late final Translations$editor$en editor = Translations$editor$en.internal(_root);
	late final Translations$keys$en keys = Translations$keys$en.internal(_root);
	late final Translations$hostKey$en hostKey = Translations$hostKey$en.internal(_root);
	late final Translations$prompt$en prompt = Translations$prompt$en.internal(_root);
	late final Translations$connectError$en connectError = Translations$connectError$en.internal(_root);
	late final Translations$tailscale$en tailscale = Translations$tailscale$en.internal(_root);
	late final Translations$sshConfig$en sshConfig = Translations$sshConfig$en.internal(_root);
	late final Translations$transfer$en transfer = Translations$transfer$en.internal(_root);
	late final Translations$settings$en settings = Translations$settings$en.internal(_root);
}

// Path: app
class Translations$app$en {
	Translations$app$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'omp-app'
	String get title => 'omp-app';
}

// Path: common
class Translations$common$en {
	Translations$common$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Cancel'
	String get cancel => 'Cancel';

	/// en: 'Close'
	String get close => 'Close';

	/// en: 'Save'
	String get save => 'Save';

	/// en: 'Delete'
	String get delete => 'Delete';

	/// en: 'Edit'
	String get edit => 'Edit';

	/// en: 'Retry'
	String get retry => 'Retry';

	/// en: 'Copy'
	String get copy => 'Copy';

	/// en: 'Copied'
	String get copied => 'Copied';

	/// en: 'Continue'
	String get continueAction => 'Continue';

	/// en: 'Required'
	String get required => 'Required';

	/// en: 'Choose file…'
	String get chooseFile => 'Choose file…';

	/// en: 'Cancelled.'
	String get cancelled => 'Cancelled.';
}

// Path: shell
class Translations$shell$en {
	Translations$shell$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Show sidebar'
	String get showSidebar => 'Show sidebar';

	/// en: 'Hide sidebar'
	String get hideSidebar => 'Hide sidebar';

	/// en: 'Show panels'
	String get showPanels => 'Show panels';

	/// en: 'Hide panels'
	String get hidePanels => 'Hide panels';

	/// en: 'Panels'
	String get panels => 'Panels';

	/// en: 'No machine selected'
	String get homeTitle => 'No machine selected';

	/// en: 'Select a machine in the sidebar, or add one.'
	String get homeBody => 'Select a machine in the sidebar, or add one.';

	/// en: 'SSH keys'
	String get keysTitle => 'SSH keys';

	/// en: 'Settings'
	String get settingsTitle => 'Settings';
}

// Path: dock
class Translations$dock$en {
	Translations$dock$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Agents'
	String get agents => 'Agents';

	/// en: 'Todos'
	String get todos => 'Todos';

	/// en: 'Tree'
	String get tree => 'Tree';

	/// en: 'Files'
	String get files => 'Files';

	/// en: 'Terminal'
	String get terminal => 'Terminal';

	/// en: 'Open a session to use this panel.'
	String get noSession => 'Open a session to use this panel.';
}

// Path: sidebar
class Translations$sidebar$en {
	Translations$sidebar$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Machines'
	String get machines => 'Machines';

	/// en: 'Add machine'
	String get addMachine => 'Add machine';

	/// en: 'More'
	String get more => 'More';

	/// en: 'Import machines…'
	String get importMachines => 'Import machines…';

	/// en: 'Export machines…'
	String get exportMachines => 'Export machines…';

	/// en: 'SSH keys'
	String get keys => 'SSH keys';

	/// en: 'Settings'
	String get settings => 'Settings';

	/// en: 'No machines yet.'
	String get noMachines => 'No machines yet.';
}

// Path: machines
class Translations$machines$en {
	Translations$machines$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'This computer'
	String get thisComputer => 'This computer';

	/// en: 'Tailscale'
	String get tailscale => 'Tailscale';

	/// en: 'Route'
	String get route => 'Route';

	/// en: 'Machine'
	String get target => 'Machine';

	/// en: 'From SSH config alias $alias'
	String sshConfigAlias({required Object alias}) => 'From SSH config alias ${alias}';

	/// en: 'Delete $name?'
	String deleteTitle({required Object name}) => 'Delete ${name}?';

	/// en: 'Saved passwords of this machine are deleted too. Keys and trusted host keys stay.'
	String get deleteBody => 'Saved passwords of this machine are deleted too. Keys and trusted host keys stay.';

	/// en: 'Test connection'
	String get testConnection => 'Test connection';

	/// en: 'Connecting…'
	String get connecting => 'Connecting…';

	/// en: 'Connected in $ms ms.'
	String connectedIn({required Object ms}) => 'Connected in ${ms} ms.';

	/// en: 'Failed: $error'
	String failed({required Object error}) => 'Failed: ${error}';

	/// en: 'Trusted host keys'
	String get hostKeys => 'Trusted host keys';

	/// en: 'No host key trusted yet. The first connection asks.'
	String get noHostKeys => 'No host key trusted yet. The first connection asks.';

	/// en: 'Forget this host key'
	String get forgetHostKey => 'Forget this host key';

	/// en: 'no key selected'
	String get noKeySelected => 'no key selected';

	/// en: 'key $name'
	String keyNamed({required Object name}) => 'key ${name}';
}

// Path: auth
class Translations$auth$en {
	Translations$auth$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Key'
	String get key => 'Key';

	/// en: 'Password'
	String get password => 'Password';

	/// en: 'SSH agent'
	String get agent => 'SSH agent';

	/// en: 'None (Tailscale SSH)'
	String get none => 'None (Tailscale SSH)';

	/// en: 'Keyboard-interactive'
	String get keyboardInteractive => 'Keyboard-interactive';
}

// Path: editor
class Translations$editor$en {
	Translations$editor$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Add machine'
	String get addTitle => 'Add machine';

	/// en: 'Edit machine'
	String get editTitle => 'Edit machine';

	/// en: 'Kind'
	String get kind => 'Kind';

	/// en: 'SSH'
	String get kindSsh => 'SSH';

	/// en: 'Name'
	String get name => 'Name';

	/// en: 'Host'
	String get host => 'Host';

	/// en: 'Host name, IP address, MagicDNS name or 100.x address'
	String get hostHelper => 'Host name, IP address, MagicDNS name or 100.x address';

	/// en: 'Port'
	String get port => 'Port';

	/// en: 'Between 1 and 65535'
	String get invalidPort => 'Between 1 and 65535';

	/// en: 'User'
	String get user => 'User';

	/// en: 'Authentication'
	String get auth => 'Authentication';

	/// en: 'Key'
	String get key => 'Key';

	/// en: 'Choose a key'
	String get chooseKey => 'Choose a key';

	/// en: 'No keys on this device yet.'
	String get noKeys => 'No keys on this device yet.';

	/// en: 'Import key…'
	String get importKey => 'Import key…';

	/// en: 'Generate key…'
	String get generateKey => 'Generate key…';

	/// en: 'Password'
	String get password => 'Password';

	/// en: 'Leave empty to keep the saved password'
	String get passwordSavedHint => 'Leave empty to keep the saved password';

	/// en: 'Leave empty to be asked when connecting'
	String get passwordAskHint => 'Leave empty to be asked when connecting';

	/// en: 'Save password on this device'
	String get savePassword => 'Save password on this device';

	/// en: 'Reached over Tailscale'
	String get tailscale => 'Reached over Tailscale';

	/// en: 'Jump hosts'
	String get jumpHosts => 'Jump hosts';

	/// en: 'Dialed in order before the machine. For a host behind NAT with a reverse tunnel, add the relay host here and set the machine's host to localhost and the tunnel port.'
	String get jumpHostsHelp => 'Dialed in order before the machine. For a host behind NAT with a reverse tunnel, add the relay host here and set the machine\'s host to localhost and the tunnel port.';

	/// en: 'Jump host $n'
	String jumpHostN({required Object n}) => 'Jump host ${n}';

	/// en: 'Add jump host'
	String get addJumpHost => 'Add jump host';

	/// en: 'Move up'
	String get moveUp => 'Move up';

	/// en: 'Move down'
	String get moveDown => 'Move down';

	/// en: 'Remove'
	String get remove => 'Remove';

	/// en: 'From SSH config'
	String get fromSshConfig => 'From SSH config';

	/// en: 'From Tailscale'
	String get fromTailscale => 'From Tailscale';

	/// en: 'ProxyCommand is not supported and was ignored: $command'
	String proxyCommandIgnored({required Object command}) => 'ProxyCommand is not supported and was ignored: ${command}';

	/// en: 'Host keys from Tailscale are trusted when you save.'
	String get hostKeysPretrusted => 'Host keys from Tailscale are trusted when you save.';
}

// Path: keys
class Translations$keys$en {
	Translations$keys$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No keys yet. Import an existing key or generate a new one.'
	String get empty => 'No keys yet. Import an existing key or generate a new one.';

	/// en: 'Import key'
	String get import => 'Import key';

	/// en: 'Generate key'
	String get generate => 'Generate key';

	/// en: 'Copy public key'
	String get copyPublicKey => 'Copy public key';

	/// en: 'Public key copied.'
	String get publicKeyCopied => 'Public key copied.';

	/// en: 'Delete $name?'
	String deleteTitle({required Object name}) => 'Delete ${name}?';

	/// en: 'The private key is removed from this device.'
	String get deleteBody => 'The private key is removed from this device.';

	/// en: 'Machines using it need another key: $machines.'
	String deleteUsedBy({required Object machines}) => 'Machines using it need another key: ${machines}.';

	/// en: 'Name'
	String get name => 'Name';

	/// en: 'Private key'
	String get privateKey => 'Private key';

	/// en: 'Paste an OpenSSH or PEM private key'
	String get privateKeyHint => 'Paste an OpenSSH or PEM private key';

	/// en: 'Passphrase'
	String get passphrase => 'Passphrase';

	/// en: 'Only for encrypted keys'
	String get passphraseHint => 'Only for encrypted keys';

	/// en: 'Import SSH key'
	String get importTitle => 'Import SSH key';

	/// en: 'Import'
	String get importAction => 'Import';

	/// en: 'Generate Ed25519 key'
	String get generateTitle => 'Generate Ed25519 key';

	/// en: 'Generate'
	String get generateAction => 'Generate';

	/// en: 'Add this public key to ~/.ssh/authorized_keys on your machines.'
	String get generatedBody => 'Add this public key to ~/.ssh/authorized_keys on your machines.';

	/// en: 'This is not a private key the app can read.'
	String get malformed => 'This is not a private key the app can read.';

	/// en: 'This key type is not supported.'
	String get unsupported => 'This key type is not supported.';

	/// en: 'This key is encrypted. Enter its passphrase.'
	String get passphraseRequired => 'This key is encrypted. Enter its passphrase.';

	/// en: 'Wrong passphrase.'
	String get wrongPassphrase => 'Wrong passphrase.';

	/// en: 'This key is already stored as $name.'
	String duplicate({required Object name}) => 'This key is already stored as ${name}.';

	/// en: 'This file is too large to be a private key.'
	String get fileTooLarge => 'This file is too large to be a private key.';
}

// Path: hostKey
class Translations$hostKey$en {
	Translations$hostKey$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Trust this host?'
	String get unknownTitle => 'Trust this host?';

	/// en: 'First connection to $host. Compare the fingerprint with the server's key before you trust it.'
	String unknownBody({required Object host}) => 'First connection to ${host}. Compare the fingerprint with the server\'s key before you trust it.';

	/// en: 'Host key changed'
	String get changedTitle => 'Host key changed';

	/// en: '$host presented a different key than the one trusted before. The server may have been reinstalled, or someone may be intercepting the connection.'
	String changedBody({required Object host}) => '${host} presented a different key than the one trusted before. The server may have been reinstalled, or someone may be intercepting the connection.';

	/// en: '$host presented a key that differs from ~/.ssh/known_hosts. The server may have been reinstalled, or someone may be intercepting the connection.'
	String changedOpenSshBody({required Object host}) => '${host} presented a key that differs from ~/.ssh/known_hosts. The server may have been reinstalled, or someone may be intercepting the connection.';

	/// en: 'Previously trusted'
	String get previouslyTrusted => 'Previously trusted';

	/// en: 'Host key revoked'
	String get revokedTitle => 'Host key revoked';

	/// en: '~/.ssh/known_hosts marks the key of $host as revoked. The connection is refused.'
	String revokedBody({required Object host}) => '~/.ssh/known_hosts marks the key of ${host} as revoked. The connection is refused.';

	/// en: 'Key type'
	String get keyType => 'Key type';

	/// en: 'Fingerprint'
	String get fingerprint => 'Fingerprint';

	/// en: 'Trust'
	String get trust => 'Trust';

	/// en: 'Replace and connect'
	String get replace => 'Replace and connect';
}

// Path: prompt
class Translations$prompt$en {
	Translations$prompt$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Password for $hop'
	String passwordTitle({required Object hop}) => 'Password for ${hop}';
}

// Path: connectError
class Translations$connectError$en {
	Translations$connectError$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '$hop uses key authentication, but no key is selected. Edit the machine to choose one.'
	String noKeySelected({required Object hop}) => '${hop} uses key authentication, but no key is selected. Edit the machine to choose one.';

	/// en: 'The private key for $hop is missing from this device.'
	String keyMissing({required Object hop}) => 'The private key for ${hop} is missing from this device.';

	/// en: 'No password for $hop.'
	String passwordMissing({required Object hop}) => 'No password for ${hop}.';

	/// en: 'Could not reach $hop.'
	String unreachable({required Object hop}) => 'Could not reach ${hop}.';

	/// en: 'The host key of $hop was not trusted.'
	String hostKeyRejected({required Object hop}) => 'The host key of ${hop} was not trusted.';

	/// en: '$hop rejected the credentials.'
	String authFailed({required Object hop}) => '${hop} rejected the credentials.';

	/// en: '$hop did not answer in time.'
	String timeout({required Object hop}) => '${hop} did not answer in time.';

	/// en: 'The key for $hop cannot be used on this device.'
	String keyUnavailable({required Object hop}) => 'The key for ${hop} cannot be used on this device.';

	/// en: 'SSH handshake with $hop failed.'
	String protocol({required Object hop}) => 'SSH handshake with ${hop} failed.';
}

// Path: tailscale
class Translations$tailscale$en {
	Translations$tailscale$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Tailscale devices'
	String get title => 'Tailscale devices';

	/// en: 'Tailscale is not installed on this computer.'
	String get notInstalled => 'Tailscale is not installed on this computer.';

	/// en: 'Tailscale did not answer: $message'
	String failed({required Object message}) => 'Tailscale did not answer: ${message}';

	/// en: 'Tailscale is not connected (state: $state).'
	String notRunning({required Object state}) => 'Tailscale is not connected (state: ${state}).';

	/// en: 'No other devices in this tailnet.'
	String get noPeers => 'No other devices in this tailnet.';

	/// en: 'offline'
	String get offline => 'offline';
}

// Path: sshConfig
class Translations$sshConfig$en {
	Translations$sshConfig$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'SSH config hosts'
	String get title => 'SSH config hosts';

	/// en: 'No hosts in ~/.ssh/config.'
	String get empty => 'No hosts in ~/.ssh/config.';

	/// en: 'Could not read ~/.ssh/config: $error'
	String failed({required Object error}) => 'Could not read ~/.ssh/config: ${error}';
}

// Path: transfer
class Translations$transfer$en {
	Translations$transfer$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Export machines'
	String get exportTitle => 'Export machines';

	/// en: '$count SSH machines with their jump hosts and trusted host keys. Private keys, passphrases and passwords are never exported.'
	String exportBody({required Object count}) => '${count} SSH machines with their jump hosts and trusted host keys. Private keys, passphrases and passwords are never exported.';

	/// en: 'There are no SSH machines to export.'
	String get exportNone => 'There are no SSH machines to export.';

	/// en: 'Save to file…'
	String get saveFile => 'Save to file…';

	/// en: 'Saved.'
	String get saved => 'Saved.';

	/// en: 'Import machines'
	String get importTitle => 'Import machines';

	/// en: 'Paste an export from another device, or choose its file.'
	String get importHint => 'Paste an export from another device, or choose its file.';

	/// en: 'Import'
	String get importAction => 'Import';

	/// en: 'Imported $added, skipped $skipped already present.'
	String imported({required Object added, required Object skipped}) => 'Imported ${added}, skipped ${skipped} already present.';

	/// en: 'Not a machine export: $error'
	String invalid({required Object error}) => 'Not a machine export: ${error}';
}

// Path: settings
class Translations$settings$en {
	Translations$settings$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Theme'
	String get theme => 'Theme';

	/// en: 'System'
	String get themeSystem => 'System';

	/// en: 'Light'
	String get themeLight => 'Light';

	/// en: 'Dark'
	String get themeDark => 'Dark';

	/// en: 'Build channel'
	String get buildChannel => 'Build channel';

	/// en: 'Keyboard shortcuts'
	String get shortcuts => 'Keyboard shortcuts';

	/// en: 'Toggle sidebar'
	String get shortcutToggleSidebar => 'Toggle sidebar';

	/// en: 'Toggle panels'
	String get shortcutTogglePanels => 'Toggle panels';

	/// en: 'Show a panel tab'
	String get shortcutPanelTab => 'Show a panel tab';

	/// en: 'Add machine'
	String get shortcutAddMachine => 'Add machine';

	/// en: 'Settings'
	String get shortcutSettings => 'Settings';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'omp-app',
			'common.cancel' => 'Cancel',
			'common.close' => 'Close',
			'common.save' => 'Save',
			'common.delete' => 'Delete',
			'common.edit' => 'Edit',
			'common.retry' => 'Retry',
			'common.copy' => 'Copy',
			'common.copied' => 'Copied',
			'common.continueAction' => 'Continue',
			'common.required' => 'Required',
			'common.chooseFile' => 'Choose file…',
			'common.cancelled' => 'Cancelled.',
			'shell.showSidebar' => 'Show sidebar',
			'shell.hideSidebar' => 'Hide sidebar',
			'shell.showPanels' => 'Show panels',
			'shell.hidePanels' => 'Hide panels',
			'shell.panels' => 'Panels',
			'shell.homeTitle' => 'No machine selected',
			'shell.homeBody' => 'Select a machine in the sidebar, or add one.',
			'shell.keysTitle' => 'SSH keys',
			'shell.settingsTitle' => 'Settings',
			'dock.agents' => 'Agents',
			'dock.todos' => 'Todos',
			'dock.tree' => 'Tree',
			'dock.files' => 'Files',
			'dock.terminal' => 'Terminal',
			'dock.noSession' => 'Open a session to use this panel.',
			'sidebar.machines' => 'Machines',
			'sidebar.addMachine' => 'Add machine',
			'sidebar.more' => 'More',
			'sidebar.importMachines' => 'Import machines…',
			'sidebar.exportMachines' => 'Export machines…',
			'sidebar.keys' => 'SSH keys',
			'sidebar.settings' => 'Settings',
			'sidebar.noMachines' => 'No machines yet.',
			'machines.thisComputer' => 'This computer',
			'machines.tailscale' => 'Tailscale',
			'machines.route' => 'Route',
			'machines.target' => 'Machine',
			'machines.sshConfigAlias' => ({required Object alias}) => 'From SSH config alias ${alias}',
			'machines.deleteTitle' => ({required Object name}) => 'Delete ${name}?',
			'machines.deleteBody' => 'Saved passwords of this machine are deleted too. Keys and trusted host keys stay.',
			'machines.testConnection' => 'Test connection',
			'machines.connecting' => 'Connecting…',
			'machines.connectedIn' => ({required Object ms}) => 'Connected in ${ms} ms.',
			'machines.failed' => ({required Object error}) => 'Failed: ${error}',
			'machines.hostKeys' => 'Trusted host keys',
			'machines.noHostKeys' => 'No host key trusted yet. The first connection asks.',
			'machines.forgetHostKey' => 'Forget this host key',
			'machines.noKeySelected' => 'no key selected',
			'machines.keyNamed' => ({required Object name}) => 'key ${name}',
			'auth.key' => 'Key',
			'auth.password' => 'Password',
			'auth.agent' => 'SSH agent',
			'auth.none' => 'None (Tailscale SSH)',
			'auth.keyboardInteractive' => 'Keyboard-interactive',
			'editor.addTitle' => 'Add machine',
			'editor.editTitle' => 'Edit machine',
			'editor.kind' => 'Kind',
			'editor.kindSsh' => 'SSH',
			'editor.name' => 'Name',
			'editor.host' => 'Host',
			'editor.hostHelper' => 'Host name, IP address, MagicDNS name or 100.x address',
			'editor.port' => 'Port',
			'editor.invalidPort' => 'Between 1 and 65535',
			'editor.user' => 'User',
			'editor.auth' => 'Authentication',
			'editor.key' => 'Key',
			'editor.chooseKey' => 'Choose a key',
			'editor.noKeys' => 'No keys on this device yet.',
			'editor.importKey' => 'Import key…',
			'editor.generateKey' => 'Generate key…',
			'editor.password' => 'Password',
			'editor.passwordSavedHint' => 'Leave empty to keep the saved password',
			'editor.passwordAskHint' => 'Leave empty to be asked when connecting',
			'editor.savePassword' => 'Save password on this device',
			'editor.tailscale' => 'Reached over Tailscale',
			'editor.jumpHosts' => 'Jump hosts',
			'editor.jumpHostsHelp' => 'Dialed in order before the machine. For a host behind NAT with a reverse tunnel, add the relay host here and set the machine\'s host to localhost and the tunnel port.',
			'editor.jumpHostN' => ({required Object n}) => 'Jump host ${n}',
			'editor.addJumpHost' => 'Add jump host',
			'editor.moveUp' => 'Move up',
			'editor.moveDown' => 'Move down',
			'editor.remove' => 'Remove',
			'editor.fromSshConfig' => 'From SSH config',
			'editor.fromTailscale' => 'From Tailscale',
			'editor.proxyCommandIgnored' => ({required Object command}) => 'ProxyCommand is not supported and was ignored: ${command}',
			'editor.hostKeysPretrusted' => 'Host keys from Tailscale are trusted when you save.',
			'keys.empty' => 'No keys yet. Import an existing key or generate a new one.',
			'keys.import' => 'Import key',
			'keys.generate' => 'Generate key',
			'keys.copyPublicKey' => 'Copy public key',
			'keys.publicKeyCopied' => 'Public key copied.',
			'keys.deleteTitle' => ({required Object name}) => 'Delete ${name}?',
			'keys.deleteBody' => 'The private key is removed from this device.',
			'keys.deleteUsedBy' => ({required Object machines}) => 'Machines using it need another key: ${machines}.',
			'keys.name' => 'Name',
			'keys.privateKey' => 'Private key',
			'keys.privateKeyHint' => 'Paste an OpenSSH or PEM private key',
			'keys.passphrase' => 'Passphrase',
			'keys.passphraseHint' => 'Only for encrypted keys',
			'keys.importTitle' => 'Import SSH key',
			'keys.importAction' => 'Import',
			'keys.generateTitle' => 'Generate Ed25519 key',
			'keys.generateAction' => 'Generate',
			'keys.generatedBody' => 'Add this public key to ~/.ssh/authorized_keys on your machines.',
			'keys.malformed' => 'This is not a private key the app can read.',
			'keys.unsupported' => 'This key type is not supported.',
			'keys.passphraseRequired' => 'This key is encrypted. Enter its passphrase.',
			'keys.wrongPassphrase' => 'Wrong passphrase.',
			'keys.duplicate' => ({required Object name}) => 'This key is already stored as ${name}.',
			'keys.fileTooLarge' => 'This file is too large to be a private key.',
			'hostKey.unknownTitle' => 'Trust this host?',
			'hostKey.unknownBody' => ({required Object host}) => 'First connection to ${host}. Compare the fingerprint with the server\'s key before you trust it.',
			'hostKey.changedTitle' => 'Host key changed',
			'hostKey.changedBody' => ({required Object host}) => '${host} presented a different key than the one trusted before. The server may have been reinstalled, or someone may be intercepting the connection.',
			'hostKey.changedOpenSshBody' => ({required Object host}) => '${host} presented a key that differs from ~/.ssh/known_hosts. The server may have been reinstalled, or someone may be intercepting the connection.',
			'hostKey.previouslyTrusted' => 'Previously trusted',
			'hostKey.revokedTitle' => 'Host key revoked',
			'hostKey.revokedBody' => ({required Object host}) => '~/.ssh/known_hosts marks the key of ${host} as revoked. The connection is refused.',
			'hostKey.keyType' => 'Key type',
			'hostKey.fingerprint' => 'Fingerprint',
			'hostKey.trust' => 'Trust',
			'hostKey.replace' => 'Replace and connect',
			'prompt.passwordTitle' => ({required Object hop}) => 'Password for ${hop}',
			'connectError.noKeySelected' => ({required Object hop}) => '${hop} uses key authentication, but no key is selected. Edit the machine to choose one.',
			'connectError.keyMissing' => ({required Object hop}) => 'The private key for ${hop} is missing from this device.',
			'connectError.passwordMissing' => ({required Object hop}) => 'No password for ${hop}.',
			'connectError.unreachable' => ({required Object hop}) => 'Could not reach ${hop}.',
			'connectError.hostKeyRejected' => ({required Object hop}) => 'The host key of ${hop} was not trusted.',
			'connectError.authFailed' => ({required Object hop}) => '${hop} rejected the credentials.',
			'connectError.timeout' => ({required Object hop}) => '${hop} did not answer in time.',
			'connectError.keyUnavailable' => ({required Object hop}) => 'The key for ${hop} cannot be used on this device.',
			'connectError.protocol' => ({required Object hop}) => 'SSH handshake with ${hop} failed.',
			'tailscale.title' => 'Tailscale devices',
			'tailscale.notInstalled' => 'Tailscale is not installed on this computer.',
			'tailscale.failed' => ({required Object message}) => 'Tailscale did not answer: ${message}',
			'tailscale.notRunning' => ({required Object state}) => 'Tailscale is not connected (state: ${state}).',
			'tailscale.noPeers' => 'No other devices in this tailnet.',
			'tailscale.offline' => 'offline',
			'sshConfig.title' => 'SSH config hosts',
			'sshConfig.empty' => 'No hosts in ~/.ssh/config.',
			'sshConfig.failed' => ({required Object error}) => 'Could not read ~/.ssh/config: ${error}',
			'transfer.exportTitle' => 'Export machines',
			'transfer.exportBody' => ({required Object count}) => '${count} SSH machines with their jump hosts and trusted host keys. Private keys, passphrases and passwords are never exported.',
			'transfer.exportNone' => 'There are no SSH machines to export.',
			'transfer.saveFile' => 'Save to file…',
			'transfer.saved' => 'Saved.',
			'transfer.importTitle' => 'Import machines',
			'transfer.importHint' => 'Paste an export from another device, or choose its file.',
			'transfer.importAction' => 'Import',
			'transfer.imported' => ({required Object added, required Object skipped}) => 'Imported ${added}, skipped ${skipped} already present.',
			'transfer.invalid' => ({required Object error}) => 'Not a machine export: ${error}',
			'settings.theme' => 'Theme',
			'settings.themeSystem' => 'System',
			'settings.themeLight' => 'Light',
			'settings.themeDark' => 'Dark',
			'settings.buildChannel' => 'Build channel',
			'settings.shortcuts' => 'Keyboard shortcuts',
			'settings.shortcutToggleSidebar' => 'Toggle sidebar',
			'settings.shortcutTogglePanels' => 'Toggle panels',
			'settings.shortcutPanelTab' => 'Show a panel tab',
			'settings.shortcutAddMachine' => 'Add machine',
			'settings.shortcutSettings' => 'Settings',
			_ => null,
		};
	}
}
