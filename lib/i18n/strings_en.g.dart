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
	late final Translations$usage$en usage = Translations$usage$en.internal(_root);
	late final Translations$dock$en dock = Translations$dock$en.internal(_root);
	late final Translations$sidebar$en sidebar = Translations$sidebar$en.internal(_root);
	late final Translations$machines$en machines = Translations$machines$en.internal(_root);
	late final Translations$auth$en auth = Translations$auth$en.internal(_root);
	late final Translations$editor$en editor = Translations$editor$en.internal(_root);
	late final Translations$keys$en keys = Translations$keys$en.internal(_root);
	late final Translations$hostKey$en hostKey = Translations$hostKey$en.internal(_root);
	late final Translations$links$en links = Translations$links$en.internal(_root);
	late final Translations$prompt$en prompt = Translations$prompt$en.internal(_root);
	late final Translations$connectError$en connectError = Translations$connectError$en.internal(_root);
	late final Translations$tailscale$en tailscale = Translations$tailscale$en.internal(_root);
	late final Translations$sshConfig$en sshConfig = Translations$sshConfig$en.internal(_root);
	late final Translations$transfer$en transfer = Translations$transfer$en.internal(_root);
	late final Translations$settings$en settings = Translations$settings$en.internal(_root);
	late final Translations$time$en time = Translations$time$en.internal(_root);
	late final Translations$sessions$en sessions = Translations$sessions$en.internal(_root);
	late final Translations$install$en install = Translations$install$en.internal(_root);
	late final Translations$chat$en chat = Translations$chat$en.internal(_root);
	late final Translations$attachments$en attachments = Translations$attachments$en.internal(_root);
	late final Translations$composer$en composer = Translations$composer$en.internal(_root);
	late final Translations$queue$en queue = Translations$queue$en.internal(_root);
	late final Translations$exec$en exec = Translations$exec$en.internal(_root);
	late final Translations$requests$en requests = Translations$requests$en.internal(_root);
	late final Translations$ask$en ask = Translations$ask$en.internal(_root);
	late final Translations$transcript$en transcript = Translations$transcript$en.internal(_root);
	late final Translations$config$en config = Translations$config$en.internal(_root);
}

// Path: app
class Translations$app$en {
	Translations$app$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'ompanion'
	String get title => 'ompanion';
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

	/// en: 'Usage'
	String get usageTitle => 'Usage';

	/// en: 'Settings'
	String get settingsTitle => 'Settings';
}

// Path: usage
class Translations$usage$en {
	Translations$usage$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Ask providers again'
	String get fetchAgain => 'Ask providers again';

	/// en: 'Fetched $ago ago'
	String fetched({required Object ago}) => 'Fetched ${ago} ago';

	/// en: 'Not fetched yet'
	String get notFetched => 'Not fetched yet';

	/// en: 'No usage data. Accounts of providers with a usage endpoint (for example Claude and ChatGPT subscriptions) show their limits here.'
	String get none => 'No usage data. Accounts of providers with a usage endpoint (for example Claude and ChatGPT subscriptions) show their limits here.';

	/// en: 'No machines yet. Add one in the sidebar.'
	String get noMachines => 'No machines yet. Add one in the sidebar.';

	/// en: 'Machines'
	String get machines => 'Machines';

	/// en: 'Asking omp…'
	String get asking => 'Asking omp…';

	/// en: '(one) {omp $version · $n account} (other) {omp $version · $n accounts}'
	String machineAccounts({required num n, required Object version}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: 'omp ${version} · ${n} account',
		other: 'omp ${version} · ${n} accounts',
	);

	/// en: '(one) {$n account} (other) {$n accounts}'
	String providerAccounts({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} account',
		other: '${n} accounts',
	);

	/// en: 'account $n'
	String accountN({required Object n}) => 'account ${n}';

	/// en: 'API key'
	String get apiKey => 'API key';

	/// en: 'OAuth account'
	String get oauthAccount => 'OAuth account';

	/// en: 'plan: $plan'
	String plan({required Object plan}) => 'plan: ${plan}';

	/// en: 'daybreak'
	String get daybreak => 'daybreak';

	/// en: '(one) {$n saved reset} (other) {$n saved resets}'
	String savedResets({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} saved reset',
		other: '${n} saved resets',
	);

	/// en: '$n usable now'
	String usableNow({required Object n}) => '${n} usable now';

	/// en: 'soonest expires in $duration ($date)'
	String resetExpiresIn({required Object duration, required Object date}) => 'soonest expires in ${duration} (${date})';

	/// en: 'expired ($date)'
	String resetExpired({required Object date}) => 'expired (${date})';

	/// en: 'unavailable: $reason'
	String resetUnavailable({required Object reason}) => 'unavailable: ${reason}';

	/// en: 'cooldown until $time'
	String resetCooldown({required Object time}) => 'cooldown until ${time}';

	/// en: 'blocked by $windows'
	String resetBlocked({required Object windows}) => 'blocked by ${windows}';

	/// en: 'not eligible'
	String get resetNotEligible => 'not eligible';

	/// en: 'not usable right now'
	String get resetNotUsable => 'not usable right now';

	/// en: 'fetched $ago ago'
	String fetchedAgo({required Object ago}) => 'fetched ${ago} ago';

	/// en: 'policy: priority $priority · reserve $reserve'
	String policy({required Object priority, required Object reserve}) => 'policy: priority ${priority} · reserve ${reserve}';

	/// en: '$percent% (global)'
	String reserveGlobal({required Object percent}) => '${percent}% (global)';

	/// en: '$percent% (override)'
	String reserveOverride({required Object percent}) => '${percent}% (override)';

	/// en: 'reserve unknown'
	String get reserveUnknown => 'reserve unknown';

	/// en: 'eligible · $percent% left'
	String eligible({required Object percent}) => 'eligible · ${percent}% left';

	/// en: 'inside reserve · $percent% left'
	String insideReserve({required Object percent}) => 'inside reserve · ${percent}% left';

	/// en: '$line ($machine)'
	String policyOn({required Object line, required Object machine}) => '${line} (${machine})';

	/// en: 'no limits reported'
	String get noLimits => 'no limits reported';

	/// en: 'not reported'
	String get notReported => 'not reported';

	/// en: 'no data'
	String get noData => 'no data';

	/// en: '$used / $limit'
	String amountOf({required Object used, required Object limit}) => '${used} / ${limit}';

	/// en: '$amount left'
	String amountLeft({required Object amount}) => '${amount} left';

	/// en: '$amount used'
	String amountUsed({required Object amount}) => '${amount} used';

	/// en: '$percent% used'
	String percentUsed({required Object percent}) => '${percent}% used';

	/// en: '$percent% left'
	String percentLeft({required Object percent}) => '${percent}% left';

	/// en: 'resets'
	String get resets => 'resets';

	/// en: '$verb in $duration'
	String resetsIn({required Object verb, required Object duration}) => '${verb} in ${duration}';

	late final Translations$usage$units$en units = Translations$usage$units$en.internal(_root);

	/// en: 'no usage data'
	String get withoutUsage => 'no usage data';

	/// en: 'disabled $ago ago: $cause'
	String disabledAgo({required Object ago, required Object cause}) => 'disabled ${ago} ago: ${cause}';

	/// en: 'disabled: $cause'
	String disabled({required Object cause}) => 'disabled: ${cause}';

	/// en: '(re-login to restore)'
	String get reloginToRestore => '(re-login to restore)';

	/// en: 're-login within $duration (Anthropic expires OAuth grants ~30d after login)'
	String reloginWithin({required Object duration}) => 're-login within ${duration} (Anthropic expires OAuth grants ~30d after login)';

	/// en: 'grant is past Anthropic's ~30d lifetime; re-login now'
	String get reloginNow => 'grant is past Anthropic\'s ~30d lifetime; re-login now';

	/// en: 'Capacity'
	String get capacity => 'Capacity';

	/// en: '(one) {$used/$n account used · $left× quota left} (other) {$used/$n accounts used · $left× quota left}'
	String capacityWindow({required num n, required Object used, required Object left}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${used}/${n} account used · ${left}× quota left',
		other: '${used}/${n} accounts used · ${left}× quota left',
	);
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

	/// en: 'Open a session or select a machine to use this panel.'
	String get noMachine => 'Open a session or select a machine to use this panel.';

	late final Translations$dock$todo$en todo = Translations$dock$todo$en.internal(_root);
	late final Translations$dock$hub$en hub = Translations$dock$hub$en.internal(_root);
	late final Translations$dock$sessionTree$en sessionTree = Translations$dock$sessionTree$en.internal(_root);
	late final Translations$dock$fileBrowser$en fileBrowser = Translations$dock$fileBrowser$en.internal(_root);
	late final Translations$dock$terminals$en terminals = Translations$dock$terminals$en.internal(_root);
}

// Path: sidebar
class Translations$sidebar$en {
	Translations$sidebar$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

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

	/// en: 'Usage'
	String get usage => 'Usage';

	/// en: 'Settings'
	String get settings => 'Settings';

	/// en: 'No machines yet.'
	String get noMachines => 'No machines yet.';

	/// en: 'Search sessions'
	String get search => 'Search sessions';

	/// en: 'Search'
	String get searchHint => 'Search';

	/// en: 'No matching sessions.'
	String get noMatches => 'No matching sessions.';
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

	/// en: 'System'
	String get facts => 'System';

	/// en: 'Status'
	String get status => 'Status';

	/// en: 'OS'
	String get os => 'OS';

	/// en: 'Architecture'
	String get arch => 'Architecture';

	/// en: 'Shell'
	String get shell => 'Shell';

	/// en: 'Login PATH'
	String get loginPath => 'Login PATH';

	/// en: 'Home'
	String get home => 'Home';

	/// en: 'omp'
	String get omp => 'omp';

	/// en: 'omp version'
	String get ompVersion => 'omp version';

	/// en: 'Companion'
	String get companion => 'Companion';

	/// en: 'Uploaded'
	String get companionReady => 'Uploaded';

	/// en: 'Not uploaded'
	String get companionMissing => 'Not uploaded';

	/// en: 'Not found'
	String get notFound => 'Not found';

	/// en: 'Connect to read the machine's OS, shell and omp.'
	String get notProbed => 'Connect to read the machine\'s OS, shell and omp.';
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

	/// en: 'SSH config and agent (like ssh)'
	String get agent => 'SSH config and agent (like ssh)';

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

	/// en: 'Like the ssh command: the ssh-agent's keys (IdentityAgent, else SSH_AUTH_SOCK), then the IdentityFile keys ~/.ssh/config sets for this host, else ~/.ssh/id_ed25519, id_ecdsa and id_rsa. Encrypted keys ask for their passphrase. If the host refuses every key, its password prompt follows.'
	String get agentHelp => 'Like the ssh command: the ssh-agent\'s keys (IdentityAgent, else SSH_AUTH_SOCK), then the IdentityFile keys ~/.ssh/config sets for this host, else ~/.ssh/id_ed25519, id_ecdsa and id_rsa. Encrypted keys ask for their passphrase. If the host refuses every key, its password prompt follows.';
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

	/// en: 'Unexpected key type'
	String get otherTypesTitle => 'Unexpected key type';

	/// en: '~/.ssh/known_hosts knows $host only with keys of other types. The server may have added a key type, or someone may be intercepting the connection. Compare the fingerprint with the server's key before you trust it.'
	String otherTypesBody({required Object host}) => '~/.ssh/known_hosts knows ${host} only with keys of other types. The server may have added a key type, or someone may be intercepting the connection. Compare the fingerprint with the server\'s key before you trust it.';

	/// en: 'Known in ~/.ssh/known_hosts'
	String get knownToOpenSsh => 'Known in ~/.ssh/known_hosts';
}

// Path: links
class Translations$links$en {
	Translations$links$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Open this link?'
	String get confirmTitle => 'Open this link?';

	/// en: 'This is a $scheme: link, not a web page. It opens whichever app handles $scheme: links on this device.'
	String confirmBody({required Object scheme}) => 'This is a ${scheme}: link, not a web page. It opens whichever app handles ${scheme}: links on this device.';

	/// en: 'Open'
	String get open => 'Open';
}

// Path: prompt
class Translations$prompt$en {
	Translations$prompt$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Password for $hop'
	String passwordTitle({required Object hop}) => 'Password for ${hop}';

	/// en: 'Sign in to $hop'
	String signInTitle({required Object hop}) => 'Sign in to ${hop}';

	/// en: 'Passphrase for $path'
	String passphraseTitle({required Object path}) => 'Passphrase for ${path}';

	/// en: '$hop accepts this key. Enter its passphrase to use it.'
	String passphraseAccepted({required Object hop}) => '${hop} accepts this key. Enter its passphrase to use it.';

	/// en: 'Enter the passphrase to offer this key to $hop.'
	String passphraseUnknownKey({required Object hop}) => 'Enter the passphrase to offer this key to ${hop}.';

	/// en: 'Wrong passphrase.'
	String get passphraseWrong => 'Wrong passphrase.';

	/// en: 'Passphrase'
	String get passphrase => 'Passphrase';

	/// en: 'Remember on this device'
	String get rememberPassphrase => 'Remember on this device';
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

	/// en: '$host did not accept the key $key.'
	String keyRefused({required Object host, required Object key}) => '${host} did not accept the key ${key}.';

	/// en: '(one) {$host did not accept the $n key in the ssh-agent.} (other) {$host did not accept any of the $n keys in the ssh-agent.}'
	String agentKeysRefused({required num n, required Object host}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${host} did not accept the ${n} key in the ssh-agent.',
		other: '${host} did not accept any of the ${n} keys in the ssh-agent.',
	);

	/// en: '$host did not accept any of these keys:'
	String keysRefused({required Object host}) => '${host} did not accept any of these keys:';

	/// en: '$comment from the ssh-agent'
	String agentKey({required Object comment}) => '${comment} from the ssh-agent';

	/// en: 'a key from the ssh-agent'
	String get agentKeyUnnamed => 'a key from the ssh-agent';

	/// en: 'Add the public key to ~/.ssh/authorized_keys of $user on $host.'
	String authorizedKeysHint({required Object user, required Object host}) => 'Add the public key to ~/.ssh/authorized_keys of ${user} on ${host}.';

	/// en: 'No key to offer $host. Add one to the ssh-agent with ssh-add, or name it with IdentityFile in ~/.ssh/config.'
	String noKeys({required Object host}) => 'No key to offer ${host}. Add one to the ssh-agent with ssh-add, or name it with IdentityFile in ~/.ssh/config.';
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

	/// en: 'Search devices'
	String get search => 'Search devices';
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

	/// en: 'Host keys to confirm'
	String get hostKeysTitle => 'Host keys to confirm';

	/// en: 'The import holds host keys that would change which servers this device trusts. Trust a host's keys only if you know they are right; the others are not imported.'
	String get hostKeysBody => 'The import holds host keys that would change which servers this device trusts. Trust a host\'s keys only if you know they are right; the others are not imported.';

	/// en: 'Trusted on this device'
	String get trustedHere => 'Trusted on this device';

	/// en: 'Nothing yet'
	String get nothingTrusted => 'Nothing yet';

	/// en: 'In the import'
	String get inImport => 'In the import';

	/// en: 'Trust these keys'
	String get trustKeys => 'Trust these keys';

	/// en: 'Trusted'
	String get keysTrusted => 'Trusted';
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

	/// en: 'New session'
	String get shortcutNewSession => 'New session';

	/// en: 'Pause or resume the session'
	String get shortcutTogglePause => 'Pause or resume the session';

	/// en: 'Command palette'
	String get shortcutPalette => 'Command palette';

	/// en: 'Search sessions'
	String get shortcutSearchSessions => 'Search sessions';

	/// en: 'Stop the running turn'
	String get shortcutAbort => 'Stop the running turn';

	/// en: 'About'
	String get about => 'About';

	/// en: 'Version $version (build $build)'
	String aboutVersion({required Object version, required Object build}) => 'Version ${version} (build ${build})';

	/// en: 'A client for omp, the oh-my-pi coding agent'
	String get aboutClient => 'A client for omp, the oh-my-pi coding agent';

	/// en: 'Privacy policy'
	String get aboutPrivacy => 'Privacy policy';

	/// en: 'Source code'
	String get aboutSource => 'Source code';

	/// en: 'Report an issue'
	String get aboutIssues => 'Report an issue';

	/// en: 'License'
	String get aboutLicense => 'License';

	/// en: 'GPL-3.0'
	String get aboutLicenseValue => 'GPL-3.0';

	/// en: 'Open-source licenses'
	String get aboutLicenses => 'Open-source licenses';
}

// Path: time
class Translations$time$en {
	Translations$time$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'now'
	String get now => 'now';

	/// en: '${n}m'
	String minutes({required Object n}) => '${n}m';

	/// en: '${n}h'
	String hours({required Object n}) => '${n}h';

	/// en: '${n}d'
	String days({required Object n}) => '${n}d';
}

// Path: sessions
class Translations$sessions$en {
	Translations$sessions$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Offline'
	String get offline => 'Offline';

	/// en: 'Connecting…'
	String get connecting => 'Connecting…';

	/// en: 'omp $version'
	String online({required Object version}) => 'omp ${version}';

	/// en: 'omp needed: $reason'
	String needsOmp({required Object reason}) => 'omp needed: ${reason}';

	/// en: 'Connect'
	String get connect => 'Connect';

	/// en: 'Install omp'
	String get install => 'Install omp';

	/// en: 'Refresh'
	String get refresh => 'Refresh';

	/// en: 'Collapse'
	String get collapse => 'Collapse';

	/// en: 'Expand'
	String get expand => 'Expand';

	/// en: 'Configure'
	String get configure => 'Configure';

	/// en: 'New session'
	String get newSession => 'New session';

	/// en: 'New session in this directory'
	String get newSessionHere => 'New session in this directory';

	/// en: 'New session on $machine'
	String newSessionOn({required Object machine}) => 'New session on ${machine}';

	/// en: 'No sessions yet.'
	String get none => 'No sessions yet.';

	/// en: 'New session'
	String get untitled => 'New session';

	/// en: 'Unknown directory'
	String get unknownDirectory => 'Unknown directory';

	/// en: 'Show $n more'
	String showMore({required Object n}) => 'Show ${n} more';

	/// en: 'Working'
	String get working => 'Working';

	/// en: 'Needs your input'
	String get needsInput => 'Needs your input';

	/// en: 'The last run failed'
	String get failed => 'The last run failed';

	/// en: 'Disconnected'
	String get disconnected => 'Disconnected';

	/// en: 'Open in omp on the machine'
	String get runningOnMachine => 'Open in omp on the machine';

	/// en: 'Opening…'
	String get opening => 'Opening…';

	/// en: 'Unread'
	String get unread => 'Unread';

	/// en: 'Could not open the session: $error'
	String openFailed({required Object error}) => 'Could not open the session: ${error}';

	/// en: 'Could not list sessions: $error'
	String listFailed({required Object error}) => 'Could not list sessions: ${error}';

	/// en: 'Working directory'
	String get directory => 'Working directory';

	/// en: 'A path on the machine, e.g. ~/code/project'
	String get directoryHint => 'A path on the machine, e.g. ~/code/project';

	/// en: 'Choose a working directory.'
	String get directoryRequired => 'Choose a working directory.';

	/// en: '$path is not a directory on $machine.'
	String notADirectory({required Object path, required Object machine}) => '${path} is not a directory on ${machine}.';

	/// en: 'Recent projects'
	String get recentDirectories => 'Recent projects';

	/// en: 'Model (optional)'
	String get model => 'Model (optional)';

	/// en: 'Default (from omp's settings)'
	String get modelDefault => 'Default (from omp\'s settings)';

	/// en: 'Choose a model'
	String get modelPick => 'Choose a model';

	/// en: 'Use the model from omp's settings'
	String get modelUseDefault => 'Use the model from omp\'s settings';

	/// en: 'Start'
	String get create => 'Start';

	/// en: 'Browse the machine'
	String get browse => 'Browse the machine';

	/// en: 'Choose a directory'
	String get browseTitle => 'Choose a directory';

	/// en: 'Parent directory'
	String get up => 'Parent directory';

	/// en: 'Show hidden directories'
	String get showHidden => 'Show hidden directories';

	/// en: 'Use this directory'
	String get chooseDirectory => 'Use this directory';

	/// en: 'In omp on the machine'
	String get external => 'In omp on the machine';
}

// Path: install
class Translations$install$en {
	Translations$install$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Install omp on $machine'
	String title({required Object machine}) => 'Install omp on ${machine}';

	/// en: 'Connect to the machine first.'
	String get notConnected => 'Connect to the machine first.';

	/// en: 'The machine downloads this release from GitHub and checks its SHA-256 before installing it.'
	String get viaDownload => 'The machine downloads this release from GitHub and checks its SHA-256 before installing it.';

	/// en: 'The machine has neither curl nor wget: the app downloads the release here and uploads it, checking its SHA-256 on the machine.'
	String get viaUpload => 'The machine has neither curl nor wget: the app downloads the release here and uploads it, checking its SHA-256 on the machine.';

	/// en: 'Run the script yourself'
	String get manual => 'Run the script yourself';

	/// en: 'Install'
	String get install => 'Install';

	/// en: 'Downloading and installing on the machine…'
	String get installing => 'Downloading and installing on the machine…';

	/// en: 'Installing on the machine failed'
	String get installFailed => 'Installing on the machine failed';

	/// en: 'Downloading $asset…'
	String downloading({required Object asset}) => 'Downloading ${asset}…';

	/// en: 'Download failed with HTTP $status: $url'
	String downloadFailed({required Object status, required Object url}) => 'Download failed with HTTP ${status}: ${url}';

	/// en: 'Transferring $asset: $done of $total MB'
	String transferring({required Object asset, required Object done, required Object total}) => 'Transferring ${asset}: ${done} of ${total} MB';

	/// en: 'Checking the installation…'
	String get checking => 'Checking the installation…';

	/// en: 'omp is still not usable: $reason'
	String stillMissing({required Object reason}) => 'omp is still not usable: ${reason}';

	/// en: 'omp publishes no build for $os $arch.'
	String noAsset({required Object os, required Object arch}) => 'omp publishes no build for ${os} ${arch}.';

	/// en: 'Installed omp $version.'
	String done({required Object version}) => 'Installed omp ${version}.';

	/// en: 'OS'
	String get os => 'OS';

	/// en: 'Architecture'
	String get arch => 'Architecture';

	/// en: 'Release'
	String get release => 'Release';

	/// en: 'Installs into'
	String get directory => 'Installs into';
}

// Path: chat
class Translations$chat$en {
	Translations$chat$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No model'
	String get noModel => 'No model';

	/// en: 'Search models'
	String get searchModels => 'Search models';

	/// en: 'Reload the model list'
	String get refreshModels => 'Reload the model list';

	/// en: 'No models match.'
	String get noModels => 'No models match.';

	/// en: 'Could not load models: $error'
	String modelsFailed({required Object error}) => 'Could not load models: ${error}';

	/// en: 'Could not switch the model: $error'
	String modelFailed({required Object error}) => 'Could not switch the model: ${error}';

	/// en: 'Subagent $agent'
	String modelAgent({required Object agent}) => 'Subagent ${agent}';

	/// en: '$tokens context'
	String contextWindow({required Object tokens}) => '${tokens} context';

	/// en: 'reasoning'
	String get reasoning => 'reasoning';

	/// en: 'Thinking: $level'
	String thinking({required Object level}) => 'Thinking: ${level}';

	/// en: 'This model has no thinking levels.'
	String get noThinking => 'This model has no thinking levels.';

	/// en: 'Could not change the thinking level: $error'
	String thinkingFailed({required Object error}) => 'Could not change the thinking level: ${error}';

	/// en: 'Context: $tokens of $window tokens ($percent%) · cost $cost'
	String contextTooltip({required Object tokens, required Object window, required Object percent, required Object cost}) => 'Context: ${tokens} of ${window} tokens (${percent}%) · cost ${cost}';

	/// en: 'Context usage not known yet · cost $cost'
	String contextUnknown({required Object cost}) => 'Context usage not known yet · cost ${cost}';

	/// en: 'Pause'
	String get pause => 'Pause';

	/// en: 'Resume'
	String get resume => 'Resume';

	/// en: 'Could not pause or resume: $error'
	String pauseFailed({required Object error}) => 'Could not pause or resume: ${error}';

	/// en: 'Stop'
	String get stop => 'Stop';

	/// en: 'Could not stop the run: $error'
	String abortFailed({required Object error}) => 'Could not stop the run: ${error}';

	/// en: 'The companion is not loaded in this session, so pause, queue editing and shell or Python runs are unavailable.'
	String get noCompanion => 'The companion is not loaded in this session, so pause, queue editing and shell or Python runs are unavailable.';

	/// en: 'More'
	String get more => 'More';

	/// en: 'Copy session file path'
	String get copyPath => 'Copy session file path';

	/// en: 'Close on this device'
	String get detach => 'Close on this device';

	/// en: 'Stop the omp process'
	String get stopSession => 'Stop the omp process';

	/// en: 'Could not stop the omp process: $error'
	String stopSessionFailed({required Object error}) => 'Could not stop the omp process: ${error}';

	/// en: 'Connection lost. Reconnecting (attempt $attempt) in $seconds s.'
	String reconnecting({required Object attempt, required Object seconds}) => 'Connection lost. Reconnecting (attempt ${attempt}) in ${seconds} s.';

	/// en: 'Retry now'
	String get retryNow => 'Retry now';

	/// en: 'This session is closed.'
	String get closed => 'This session is closed.';

	/// en: 'omp exited with code $code.'
	String exited({required Object code}) => 'omp exited with code ${code}.';

	/// en: 'Reopen'
	String get reopen => 'Reopen';

	/// en: 'Could not reopen the session: $error'
	String reopenFailed({required Object error}) => 'Could not reopen the session: ${error}';

	/// en: 'Paused: the run waits before its next step'
	String get parked => 'Paused: the run waits before its next step';

	/// en: 'Compacting the context…'
	String get compacting => 'Compacting the context…';

	/// en: 'Retrying ($attempt of $max): $error'
	String retrying({required Object attempt, required Object max, required Object error}) => 'Retrying (${attempt} of ${max}): ${error}';

	/// en: 'The last run failed: $error'
	String failed({required Object error}) => 'The last run failed: ${error}';

	/// en: 'unknown error'
	String get failedUnknown => 'unknown error';

	/// en: 'Stopped'
	String get aborted => 'Stopped';

	/// en: 'Closed'
	String get closedState => 'Closed';

	/// en: 'Command output'
	String get commandOutput => 'Command output';

	/// en: 'Extension error in $path ($event): $error'
	String extensionError({required Object path, required Object event, required Object error}) => 'Extension error in ${path} (${event}): ${error}';

	/// en: 'Served by the fallback model $model.'
	String fallbackServed({required Object model}) => 'Served by the fallback model ${model}.';

	/// en: 'Switched from $from to the fallback model $to. $reason'
	String fallbackApplied({required Object from, required Object to, required Object reason}) => 'Switched from ${from} to the fallback model ${to}. ${reason}';

	/// en: 'Compaction was cancelled.'
	String get compactionCancelled => 'Compaction was cancelled.';

	/// en: 'Compaction failed: $error'
	String compactionFailed({required Object error}) => 'Compaction failed: ${error}';

	/// en: 'Stream rules interrupted the response: $rules'
	String rulesInterrupted({required Object rules}) => 'Stream rules interrupted the response: ${rules}';

	/// en: 'Branching is only possible from your own messages.'
	String get cannotBranch => 'Branching is only possible from your own messages.';

	/// en: 'Branch'
	String get branch => 'Branch';

	/// en: 'Branch from this message?'
	String get branchTitle => 'Branch from this message?';

	/// en: 'A new session file starts before this message, and the message goes back into the composer: $text'
	String branchBody({required Object text}) => 'A new session file starts before this message, and the message goes back into the composer:\n\n${text}';

	/// en: 'Could not branch: $error'
	String branchFailed({required Object error}) => 'Could not branch: ${error}';

	/// en: 'Earlier replies are kept in the session tree.'
	String get resetKept => 'Earlier replies are kept in the session tree.';

	/// en: 'Open the tree'
	String get openTree => 'Open the tree';

	/// en: 'Could not reset: $error'
	String resetFailed({required Object error}) => 'Could not reset: ${error}';
}

// Path: attachments
class Translations$attachments$en {
	Translations$attachments$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'The large paste'
	String get paste => 'The large paste';

	/// en: '$name is no longer on this device. Nothing was sent.'
	String missing({required Object name}) => '${name} is no longer on this device. Nothing was sent.';

	/// en: '$name is $size; attachments can be at most $limit. Nothing was sent.'
	String tooLarge({required Object name, required Object size, required Object limit}) => '${name} is ${size}; attachments can be at most ${limit}. Nothing was sent.';

	/// en: '$name is a folder. Folders can be attached only to sessions on this computer. Nothing was sent.'
	String folder({required Object name}) => '${name} is a folder. Folders can be attached only to sessions on this computer. Nothing was sent.';

	/// en: '$name needs the companion to reach the session's machine, and this session has none. Nothing was sent.'
	String needsCompanion({required Object name}) => '${name} needs the companion to reach the session\'s machine, and this session has none. Nothing was sent.';

	/// en: '$name could not be copied to the session's machine: $error. Nothing was sent.'
	String uploadFailed({required Object name, required Object error}) => '${name} could not be copied to the session\'s machine: ${error}. Nothing was sent.';
}

// Path: composer
class Translations$composer$en {
	Translations$composer$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Message omp'
	String get hint => 'Message omp';

	/// en: 'Steer the running turn'
	String get hintRunning => 'Steer the running turn';

	/// en: 'Send'
	String get send => 'Send';

	/// en: 'Steer'
	String get steer => 'Steer';

	/// en: 'Follow-up'
	String get followUp => 'Follow-up';

	/// en: 'Attach files'
	String get attach => 'Attach files';

	/// en: 'Remove'
	String get remove => 'Remove';

	/// en: 'Pasted image'
	String get pastedImage => 'Pasted image';

	/// en: '(one) {Pasted text · $n line} (other) {Pasted text · $n lines}'
	String pastedText({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: 'Pasted text · ${n} line',
		other: 'Pasted text · ${n} lines',
	);

	/// en: 'Paste inline'
	String get pasteInline => 'Paste inline';

	/// en: 'Showing the first $shown of $total characters.'
	String previewTruncated({required Object shown, required Object total}) => 'Showing the first ${shown} of ${total} characters.';

	/// en: 'Drop to attach'
	String get dropToAttach => 'Drop to attach';

	/// en: 'Only files and folders can be attached.'
	String get dropNothing => 'Only files and folders can be attached.';

	/// en: 'Could not paste: $error'
	String pasteFailed({required Object error}) => 'Could not paste: ${error}';

	/// en: 'Could not attach: $error'
	String attachFailed({required Object error}) => 'Could not attach: ${error}';

	/// en: 'Uploading $sent of $total'
	String uploading({required Object sent, required Object total}) => 'Uploading ${sent} of ${total}';

	/// en: '/$name is not a command of this session. Nothing was sent.'
	String unknownCommand({required Object name}) => '/${name} is not a command of this session. Nothing was sent.';

	/// en: 'Not sent: $error'
	String sendFailed({required Object error}) => 'Not sent: ${error}';

	/// en: 'Running in omp on $machine'
	String externalRunning({required Object machine}) => 'Running in omp on ${machine}';

	/// en: 'Open in omp on $machine'
	String externalIdle({required Object machine}) => 'Open in omp on ${machine}';

	/// en: 'terminal $terminal'
	String externalTerminal({required Object terminal}) => 'terminal ${terminal}';

	/// en: 'Another omp process is writing this session file. ompanion reads its transcript live, but sending is off: two writers would overwrite each other. Messages queued in that process are not visible here.'
	String get externalBody => 'Another omp process is writing this session file. ompanion reads its transcript live, but sending is off: two writers would overwrite each other. Messages queued in that process are not visible here.';

	/// en: 'The other omp process still owns this session. Take it over once it has exited.'
	String get externalWait => 'The other omp process still owns this session. Take it over once it has exited.';

	/// en: 'Take over'
	String get takeOver => 'Take over';

	/// en: 'Running in omp'
	String get externalRunningNoMachine => 'Running in omp';

	/// en: 'Open in omp'
	String get externalIdleNoMachine => 'Open in omp';

	/// en: 'The other omp process has stopped'
	String get externalGone => 'The other omp process has stopped';

	/// en: 'The other omp process is gone. Take the session over to send messages from here.'
	String get externalBodyGone => 'The other omp process is gone. Take the session over to send messages from here.';
}

// Path: queue
class Translations$queue$en {
	Translations$queue$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Steering'
	String get steer => 'Steering';

	/// en: 'Follow-up'
	String get followUp => 'Follow-up';

	/// en: '+$n more'
	String more({required Object n}) => '+${n} more';

	/// en: 'Edit in the composer'
	String get edit => 'Edit in the composer';

	/// en: 'Remove from the queue'
	String get remove => 'Remove from the queue';

	/// en: 'Could not change the queue: $error'
	String takeFailed({required Object error}) => 'Could not change the queue: ${error}';
}

// Path: exec
class Translations$exec$en {
	Translations$exec$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'running'
	String get running => 'running';

	/// en: 'exit $code'
	String exited({required Object code}) => 'exit ${code}';

	/// en: 'cancelled'
	String get cancelled => 'cancelled';

	/// en: 'failed: $error'
	String failed({required Object error}) => 'failed: ${error}';

	/// en: 'Stop'
	String get abort => 'Stop';

	/// en: 'Output truncated'
	String get truncated => 'Output truncated';
}

// Path: requests
class Translations$requests$en {
	Translations$requests$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Allow $tool?'
	String approvalTitle({required Object tool}) => 'Allow ${tool}?';

	/// en: '$index of $count'
	String position({required Object index, required Object count}) => '${index} of ${count}';

	/// en: 'Previous request'
	String get previous => 'Previous request';

	/// en: 'Next request'
	String get next => 'Next request';

	/// en: 'Submit'
	String get submit => 'Submit';

	/// en: 'Yes'
	String get yes => 'Yes';

	/// en: 'No'
	String get no => 'No';

	/// en: 'Composer text'
	String get editorText => 'Composer text';

	/// en: 'Open in your browser'
	String get openUrlTitle => 'Open in your browser';

	/// en: 'Open'
	String get openInBrowser => 'Open';

	/// en: 'Forwarding localhost:$port on this device to the machine for the login callback.'
	String forwarding({required Object port}) => 'Forwarding localhost:${port} on this device to the machine for the login callback.';

	/// en: 'Could not forward the login callback port: $error'
	String forwardFailed({required Object error}) => 'Could not forward the login callback port: ${error}';

	/// en: 'Could not send the answer: $error'
	String answerFailed({required Object error}) => 'Could not send the answer: ${error}';

	/// en: 'Unsupported request'
	String get unsupportedTitle => 'Unsupported request';

	/// en: 'The companion asked for "$method", which this app version cannot show.'
	String unsupportedBody({required Object method}) => 'The companion asked for "${method}", which this app version cannot show.';

	/// en: '$n s left'
	String secondsLeft({required Object n}) => '${n} s left';

	/// en: 'Not an http or https link, so it does not open from here.'
	String get notWebLink => 'Not an http or https link, so it does not open from here.';
}

// Path: ask
class Translations$ask$en {
	Translations$ask$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Question'
	String get title => 'Question';

	/// en: '$n questions'
	String titleMany({required Object n}) => '${n} questions';

	/// en: 'The question could not be read: $error'
	String invalid({required Object error}) => 'The question could not be read: ${error}';

	/// en: 'Recommended'
	String get recommended => 'Recommended';

	/// en: 'Choose any number.'
	String get multi => 'Choose any number.';

	/// en: 'Other: type your own answer'
	String get otherHint => 'Other: type your own answer';

	/// en: 'Note (optional)'
	String get note => 'Note (optional)';

	/// en: 'Chat about this'
	String get chat => 'Chat about this';
}

// Path: transcript
class Translations$transcript$en {
	Translations$transcript$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Jump to latest'
	String get jumpToLatest => 'Jump to latest';

	/// en: 'Load earlier messages'
	String get loadEarlier => 'Load earlier messages';

	/// en: 'Message actions'
	String get messageActions => 'Message actions';

	/// en: 'Branch from here'
	String get branchFromHere => 'Branch from here';

	/// en: 'Reset to here'
	String get resetHere => 'Reset to here';

	/// en: 'Wait for the turn to finish, or stop it, before resetting'
	String get resetRunning => 'Wait for the turn to finish, or stop it, before resetting';

	/// en: 'Copy message'
	String get copyMessage => 'Copy message';

	/// en: 'Copy code'
	String get copyCode => 'Copy code';

	/// en: 'Copy output'
	String get copyOutput => 'Copy output';

	/// en: 'Sent by the agent'
	String get fromAgent => 'Sent by the agent';

	/// en: 'Automatic message'
	String get automatic => 'Automatic message';

	/// en: 'Waiting for a reply'
	String get waiting => 'Waiting for a reply';

	/// en: 'Waiting for a reply · ${seconds}s'
	String waitingElapsed({required Object seconds}) => 'Waiting for a reply · ${seconds}s';

	/// en: 'Thinking…'
	String get thinking => 'Thinking…';

	/// en: 'Thought'
	String get thought => 'Thought';

	/// en: 'Thought for $duration'
	String thoughtFor({required Object duration}) => 'Thought for ${duration}';

	/// en: '(one) {$n reasoning token} (other) {$n reasoning tokens}'
	String reasoningTokens({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} reasoning token',
		other: '${n} reasoning tokens',
	);

	/// en: 'Reasoning hidden by the provider'
	String get redactedThinking => 'Reasoning hidden by the provider';

	/// en: 'Interrupted'
	String get interrupted => 'Interrupted';

	/// en: 'The response failed.'
	String get failed => 'The response failed.';

	/// en: 'Stopped at the output token limit.'
	String get lengthLimit => 'Stopped at the output token limit.';

	/// en: 'This attempt failed; retry $attempt succeeded.'
	String retryRecovered({required Object attempt}) => 'This attempt failed; retry ${attempt} succeeded.';

	/// en: 'This attempt failed; retrying gave up after attempt $attempt.'
	String retrySuperseded({required Object attempt}) => 'This attempt failed; retrying gave up after attempt ${attempt}.';

	/// en: 'This attempt failed; retry $attempt failed too.'
	String retryFailed({required Object attempt}) => 'This attempt failed; retry ${attempt} failed too.';

	/// en: '$count in'
	String tokensIn({required Object count}) => '${count} in';

	/// en: '$count out'
	String tokensOut({required Object count}) => '${count} out';

	/// en: '$count cached'
	String tokensCached({required Object count}) => '${count} cached';

	/// en: '$value s'
	String seconds({required Object value}) => '${value} s';

	/// en: 'Image'
	String get image => 'Image';

	/// en: 'Load image'
	String get loadImage => 'Load image';

	/// en: 'Loading $name…'
	String imageLoading({required Object name}) => 'Loading ${name}…';

	/// en: 'Image not found: $path'
	String imageMissing({required Object path}) => 'Image not found: ${path}';

	/// en: 'Not a file: $path'
	String imageNotFile({required Object path}) => 'Not a file: ${path}';

	/// en: 'No permission to read $path'
	String imageDenied({required Object path}) => 'No permission to read ${path}';

	/// en: 'Not an image: $path'
	String imageNotImage({required Object path}) => 'Not an image: ${path}';

	/// en: '$path ($size) is in a format this app cannot show'
	String imageUnsupported({required Object path, required Object size}) => '${path} (${size}) is in a format this app cannot show';

	/// en: '$path ($size) is too large to load on its own'
	String imageTooLarge({required Object path, required Object size}) => '${path} (${size}) is too large to load on its own';

	/// en: 'Could not load $path: $error'
	String imageFailed({required Object path, required Object error}) => 'Could not load ${path}: ${error}';

	/// en: 'Load original ($size)'
	String loadOriginal({required Object size}) => 'Load original (${size})';

	/// en: 'Retry'
	String get retryImage => 'Retry';

	/// en: 'preview, $sent of $size'
	String imagePreview({required Object sent, required Object size}) => 'preview, ${sent} of ${size}';

	/// en: 'Open in Files'
	String get openInFiles => 'Open in Files';

	/// en: '(one) {Show $n more line} (other) {Show $n more lines}'
	String showMoreLines({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: 'Show ${n} more line',
		other: 'Show ${n} more lines',
	);

	/// en: 'Show less'
	String get showLess => 'Show less';

	late final Translations$transcript$tool$en tool = Translations$transcript$tool$en.internal(_root);
	late final Translations$transcript$execution$en execution = Translations$transcript$execution$en.internal(_root);

	/// en: 'Context compacted'
	String get compacted => 'Context compacted';

	/// en: '$before → $after tokens'
	String compactedTokens({required Object before, required Object after}) => '${before} → ${after} tokens';

	/// en: 'from $before tokens'
	String compactedFrom({required Object before}) => 'from ${before} tokens';

	/// en: 'Show summary'
	String get showSummary => 'Show summary';

	/// en: 'Hide summary'
	String get hideSummary => 'Hide summary';

	/// en: '(one) {Show all ($n line)} (other) {Show all ($n lines)}'
	String showAll({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: 'Show all (${n} line)',
		other: 'Show all (${n} lines)',
	);

	/// en: 'Summary of the branch you left'
	String get branchSummary => 'Summary of the branch you left';

	/// en: 'Files'
	String get summaryFiles => 'Files';

	/// en: 'read'
	String get fileRead => 'read';

	/// en: 'written'
	String get fileWritten => 'written';

	/// en: 'read and written'
	String get fileReadWritten => 'read and written';

	/// en: '(one) {$n more file} (other) {$n more files}'
	String filesElided({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} more file',
		other: '${n} more files',
	);

	/// en: 'Model: $model'
	String modelChange({required Object model}) => 'Model: ${model}';

	/// en: 'Model ($role): $model'
	String modelRoleChange({required Object role, required Object model}) => 'Model (${role}): ${model}';

	/// en: 'Thinking: $level'
	String thinkingLevel({required Object level}) => 'Thinking: ${level}';

	/// en: 'Thinking: off'
	String get thinkingOff => 'Thinking: off';

	/// en: '(one) {Attached $n file} (other) {Attached $n files}'
	String mentionedFiles({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: 'Attached ${n} file',
		other: 'Attached ${n} files',
	);

	/// en: 'too large'
	String get skippedTooLarge => 'too large';

	/// en: 'binary'
	String get skippedBinary => 'binary';

	/// en: 'Background result'
	String get backgroundResult => 'Background result';

	/// en: 'Delegated request'
	String get delegated => 'Delegated request';

	late final Translations$transcript$turn$en turn = Translations$transcript$turn$en.internal(_root);
}

// Path: config
class Translations$config$en {
	Translations$config$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Configure $machine'
	String title({required Object machine}) => 'Configure ${machine}';

	/// en: 'Connect'
	String get connect => 'Connect';

	/// en: 'Connecting…'
	String get connecting => 'Connecting…';

	/// en: 'omp needs an install or an upgrade on this machine: $reason'
	String needsOmp({required Object reason}) => 'omp needs an install or an upgrade on this machine: ${reason}';

	/// en: 'Refresh'
	String get refresh => 'Refresh';

	/// en: '(no output)'
	String get noOutput => '(no output)';

	late final Translations$config$sections$en sections = Translations$config$sections$en.internal(_root);
	late final Translations$config$scope$en scope = Translations$config$scope$en.internal(_root);
	late final Translations$config$provenance$en provenance = Translations$config$provenance$en.internal(_root);
	late final Translations$config$settings$en settings = Translations$config$settings$en.internal(_root);
	late final Translations$config$roles$en roles = Translations$config$roles$en.internal(_root);
	late final Translations$config$accounts$en accounts = Translations$config$accounts$en.internal(_root);
	late final Translations$config$mcp$en mcp = Translations$config$mcp$en.internal(_root);
	late final Translations$config$plugins$en plugins = Translations$config$plugins$en.internal(_root);
	late final Translations$config$skills$en skills = Translations$config$skills$en.internal(_root);
	late final Translations$config$stats$en stats = Translations$config$stats$en.internal(_root);
}

// Path: usage.units
class Translations$usage$units$en {
	Translations$usage$units$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '$value tokens'
	String tokens({required Object value}) => '${value} tokens';

	/// en: '$value requests'
	String requests({required Object value}) => '${value} requests';

	/// en: '$value credits'
	String credits({required Object value}) => '${value} credits';

	/// en: '$value min'
	String minutes({required Object value}) => '${value} min';

	/// en: '$value bytes'
	String bytes({required Object value}) => '${value} bytes';
}

// Path: dock.todo
class Translations$dock$todo$en {
	Translations$dock$todo$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No todos yet. The agent's todo list shows up here.'
	String get empty => 'No todos yet. The agent\'s todo list shows up here.';

	/// en: '$done/$total'
	String progress({required Object done, required Object total}) => '${done}/${total}';

	/// en: 'Pending'
	String get pending => 'Pending';

	/// en: 'In progress'
	String get inProgress => 'In progress';

	/// en: 'Completed'
	String get completed => 'Completed';

	/// en: 'Abandoned'
	String get abandoned => 'Abandoned';

	/// en: 'Blocked'
	String get blocked => 'Blocked';

	/// en: 'Blocked: $reason'
	String blockedBy({required Object reason}) => 'Blocked: ${reason}';
}

// Path: dock.hub
class Translations$dock$hub$en {
	Translations$dock$hub$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'No subagents yet. Agents the session starts show up here.'
	String get empty => 'No subagents yet. Agents the session starts show up here.';

	/// en: 'Agents: $count · running: $running'
	String summary({required Object count, required Object running}) => 'Agents: ${count} · running: ${running}';

	/// en: 'Show as list'
	String get showList => 'Show as list';

	/// en: 'Show as tree'
	String get showTree => 'Show as tree';

	/// en: 'advisor'
	String get advisor => 'advisor';

	/// en: '$count tok'
	String tokens({required Object count}) => '${count} tok';

	/// en: '(one) {$n tool} (other) {$n tools}'
	String tools({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} tool',
		other: '${n} tools',
	);

	/// en: 'context $percent%'
	String context({required Object percent}) => 'context ${percent}%';

	late final Translations$dock$hub$status$en status = Translations$dock$hub$status$en.internal(_root);

	/// en: 'Back to agents'
	String get back => 'Back to agents';

	/// en: 'Agent actions'
	String get actions => 'Agent actions';

	/// en: 'Revive'
	String get revive => 'Revive';

	/// en: 'Agent revived.'
	String get revived => 'Agent revived.';

	/// en: 'Kill'
	String get kill => 'Kill';

	/// en: 'Agent killed.'
	String get killed => 'Agent killed.';

	/// en: 'Kill $name?'
	String killTitle({required Object name}) => 'Kill ${name}?';

	/// en: 'Its running turn is aborted and the agent is released for good. It cannot be revived.'
	String get killBody => 'Its running turn is aborted and the agent is released for good. It cannot be revived.';

	/// en: 'Copy agent id'
	String get copyId => 'Copy agent id';

	/// en: 'Send'
	String get steer => 'Send';

	/// en: 'Sent to the agent.'
	String get steered => 'Sent to the agent.';

	/// en: 'Message this agent…'
	String get steerHint => 'Message this agent…';

	/// en: 'Message wakes this parked agent…'
	String get steerParkedHint => 'Message wakes this parked agent…';

	/// en: 'Advisors are read-only.'
	String get advisorReadOnly => 'Advisors are read-only.';

	/// en: 'No transcript yet.'
	String get noTranscript => 'No transcript yet.';

	/// en: 'Transcript unavailable: $error'
	String transcriptFailed({required Object error}) => 'Transcript unavailable: ${error}';

	/// en: 'Failed: $error'
	String failed({required Object error}) => 'Failed: ${error}';

	/// en: 'The companion is not loaded in this session, so messaging, killing and reviving agents are unavailable.'
	String get noCompanion => 'The companion is not loaded in this session, so messaging, killing and reviving agents are unavailable.';

	/// en: '${hours}h ${minutes}m'
	String durationHours({required Object hours, required Object minutes}) => '${hours}h ${minutes}m';

	/// en: '${minutes}m ${seconds}s'
	String durationMinutes({required Object minutes, required Object seconds}) => '${minutes}m ${seconds}s';

	/// en: '${seconds}s'
	String durationSeconds({required Object seconds}) => '${seconds}s';
}

// Path: dock.sessionTree
class Translations$dock$sessionTree$en {
	Translations$dock$sessionTree$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Search entries'
	String get search => 'Search entries';

	/// en: 'Filter'
	String get filter => 'Filter';

	/// en: 'Conversation'
	String get filterStandard => 'Conversation';

	/// en: 'Without tool results'
	String get filterNoTools => 'Without tool results';

	/// en: 'Your messages'
	String get filterUserOnly => 'Your messages';

	/// en: 'Labeled'
	String get filterLabeled => 'Labeled';

	/// en: 'Everything'
	String get filterAll => 'Everything';

	/// en: 'Refresh'
	String get refresh => 'Refresh';

	/// en: 'Could not load the tree: $error'
	String loadFailed({required Object error}) => 'Could not load the tree: ${error}';

	/// en: 'No entries yet.'
	String get empty => 'No entries yet.';

	/// en: 'No entries match.'
	String get noMatches => 'No entries match.';

	/// en: 'Current position'
	String get currentLeaf => 'Current position';

	/// en: 'Go here'
	String get navigate => 'Go here';

	/// en: 'Go here with summary…'
	String get navigateWithSummary => 'Go here with summary…';

	/// en: 'Label…'
	String get label => 'Label…';

	/// en: 'Branch into new session'
	String get branch => 'Branch into new session';

	/// en: 'Copy text'
	String get copyText => 'Copy text';

	/// en: 'Summarizing the branch you are leaving…'
	String get summarizing => 'Summarizing the branch you are leaving…';

	/// en: 'Abort'
	String get abort => 'Abort';

	/// en: 'Summary aborted. Nothing moved.'
	String get summaryAborted => 'Summary aborted. Nothing moved.';

	/// en: 'Navigation cancelled.'
	String get navigationCancelled => 'Navigation cancelled.';

	/// en: 'Branch cancelled.'
	String get branchCancelled => 'Branch cancelled.';

	/// en: 'Branched into a new session. The message is back in the composer.'
	String get branched => 'Branched into a new session. The message is back in the composer.';

	/// en: 'Failed: $error'
	String failed({required Object error}) => 'Failed: ${error}';

	/// en: '(aborted)'
	String get aborted => '(aborted)';

	/// en: '(no content)'
	String get noContent => '(no content)';

	/// en: 'Compaction ($tokens tokens)'
	String compaction({required Object tokens}) => 'Compaction (${tokens} tokens)';

	/// en: 'Branch summary: $summary'
	String branchSummary({required Object summary}) => 'Branch summary: ${summary}';

	/// en: 'Model: $model'
	String model({required Object model}) => 'Model: ${model}';

	/// en: 'Thinking: $level'
	String thinking({required Object level}) => 'Thinking: ${level}';

	/// en: 'Label: $label'
	String labelSet({required Object label}) => 'Label: ${label}';

	/// en: 'Label cleared'
	String get labelCleared => 'Label cleared';

	/// en: 'advisor: $notes'
	String advisor({required Object notes}) => 'advisor: ${notes}';

	/// en: 'advisor ($tags): $notes'
	String advisorTagged({required Object tags, required Object notes}) => 'advisor (${tags}): ${notes}';

	/// en: 'Summarize the branch you leave'
	String get summaryTitle => 'Summarize the branch you leave';

	/// en: 'omp writes a summary of the abandoned branch at the new position. This makes a model call.'
	String get summaryBody => 'omp writes a summary of the abandoned branch at the new position. This makes a model call.';

	/// en: 'Custom instructions (optional)'
	String get summaryInstructions => 'Custom instructions (optional)';

	/// en: 'Summarize and go'
	String get summarize => 'Summarize and go';

	/// en: 'Label entry'
	String get labelTitle => 'Label entry';

	/// en: 'Label'
	String get labelField => 'Label';

	/// en: 'Clear label'
	String get clearLabel => 'Clear label';

	/// en: 'The companion is not loaded in this session, so going to an entry and labels are unavailable.'
	String get noCompanion => 'The companion is not loaded in this session, so going to an entry and labels are unavailable.';
}

// Path: dock.fileBrowser
class Translations$dock$fileBrowser$en {
	Translations$dock$fileBrowser$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Parent folder'
	String get up => 'Parent folder';

	/// en: 'Refresh'
	String get refresh => 'Refresh';

	/// en: 'New file'
	String get newFile => 'New file';

	/// en: 'New folder'
	String get newFolder => 'New folder';

	/// en: 'Create'
	String get create => 'Create';

	/// en: 'Rename'
	String get rename => 'Rename';

	/// en: 'Open'
	String get open => 'Open';

	/// en: 'Browse'
	String get browseHere => 'Browse';

	/// en: 'Copy path'
	String get copyPath => 'Copy path';

	/// en: 'Name'
	String get name => 'Name';

	/// en: 'This name is reserved.'
	String get nameReserved => 'This name is reserved.';

	/// en: 'Names cannot contain / or \.'
	String get nameSeparator => 'Names cannot contain / or \.';

	/// en: '$name already exists.'
	String exists({required Object name}) => '${name} already exists.';

	/// en: 'Failed: $error'
	String failed({required Object error}) => 'Failed: ${error}';

	/// en: 'Delete $name?'
	String deleteTitle({required Object name}) => 'Delete ${name}?';

	/// en: 'The file is deleted from the machine.'
	String get deleteFileBody => 'The file is deleted from the machine.';

	/// en: 'The folder and everything in it are deleted from the machine.'
	String get deleteFolderBody => 'The folder and everything in it are deleted from the machine.';

	/// en: 'The symbolic link is deleted from the machine. What it points to stays.'
	String get deleteLinkBody => 'The symbolic link is deleted from the machine. What it points to stays.';

	/// en: 'Symbolic link'
	String get link => 'Symbolic link';

	/// en: 'Empty folder'
	String get emptyFolder => 'Empty folder';

	/// en: 'Could not list: $error'
	String listFailed({required Object error}) => 'Could not list: ${error}';

	/// en: '(one) {$n open file} (other) {$n open files}'
	String openDocuments({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} open file',
		other: '${n} open files',
	);

	/// en: 'Could not open: $error'
	String openFailed({required Object error}) => 'Could not open: ${error}';

	/// en: 'Back to files'
	String get backToFiles => 'Back to files';

	/// en: 'Save'
	String get save => 'Save';

	/// en: 'Saved $name.'
	String saved({required Object name}) => 'Saved ${name}.';

	/// en: 'Save failed: $error'
	String saveFailed({required Object error}) => 'Save failed: ${error}';

	/// en: 'More'
	String get more => 'More';

	/// en: 'Find'
	String get find => 'Find';

	/// en: 'Reload from disk'
	String get reload => 'Reload from disk';

	/// en: 'Show git diff'
	String get showDiff => 'Show git diff';

	/// en: 'Show file'
	String get showFile => 'Show file';

	/// en: 'File changed on the machine'
	String get conflictTitle => 'File changed on the machine';

	/// en: 'The file changed on the machine since you opened it. Overwrite it with your version, or discard your edits and reload it?'
	String get conflictChanged => 'The file changed on the machine since you opened it. Overwrite it with your version, or discard your edits and reload it?';

	/// en: 'The file was deleted on the machine since you opened it. Overwrite recreates it.'
	String get conflictDeleted => 'The file was deleted on the machine since you opened it. Overwrite recreates it.';

	/// en: 'Overwrite'
	String get overwrite => 'Overwrite';

	/// en: 'Discard and reload'
	String get discardAndReload => 'Discard and reload';

	/// en: 'Discard changes to $name?'
	String discardTitle({required Object name}) => 'Discard changes to ${name}?';

	/// en: 'Your unsaved edits are lost.'
	String get discardBody => 'Your unsaved edits are lost.';

	/// en: 'Discard'
	String get discard => 'Discard';

	/// en: 'Larger than $mb MB: showing the beginning, read-only.'
	String tooLarge({required Object mb}) => 'Larger than ${mb} MB: showing the beginning, read-only.';

	/// en: 'Binary file. Not shown.'
	String get binary => 'Binary file. Not shown.';

	/// en: 'Not UTF-8 text: read-only, so saving cannot damage it.'
	String get notUtf8 => 'Not UTF-8 text: read-only, so saving cannot damage it.';

	/// en: 'No results'
	String get noMatches => 'No results';

	/// en: 'Replace'
	String get replace => 'Replace';

	/// en: 'Replace all'
	String get replaceAll => 'Replace all';

	/// en: 'Match case'
	String get caseSensitive => 'Match case';

	/// en: 'Previous match'
	String get previousMatch => 'Previous match';

	/// en: 'Next match'
	String get nextMatch => 'Next match';

	/// en: 'No changes against HEAD.'
	String get noChanges => 'No changes against HEAD.';

	/// en: 'git diff failed: $error'
	String diffFailed({required Object error}) => 'git diff failed: ${error}';

	/// en: 'Showing $shown of $total diff lines.'
	String diffTruncated({required Object shown, required Object total}) => 'Showing ${shown} of ${total} diff lines.';

	late final Translations$dock$fileBrowser$git$en git = Translations$dock$fileBrowser$git$en.internal(_root);
}

// Path: dock.terminals
class Translations$dock$terminals$en {
	Translations$dock$terminals$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'New terminal'
	String get newTerminal => 'New terminal';

	/// en: 'No terminal open on $machine.'
	String empty({required Object machine}) => 'No terminal open on ${machine}.';

	/// en: 'Close'
	String get close => 'Close';

	/// en: 'Restart'
	String get restart => 'Restart';

	/// en: 'Smaller text'
	String get smaller => 'Smaller text';

	/// en: 'Larger text'
	String get larger => 'Larger text';

	/// en: 'Paste'
	String get paste => 'Paste';

	/// en: 'Select all'
	String get selectAll => 'Select all';

	/// en: 'Clear'
	String get clear => 'Clear';

	/// en: 'Terminal failed: $error'
	String failed({required Object error}) => 'Terminal failed: ${error}';

	/// en: 'The shell exited with code $code.'
	String exited({required Object code}) => 'The shell exited with code ${code}.';

	/// en: 'The shell ended.'
	String get exitedBySignal => 'The shell ended.';
}

// Path: transcript.tool
class Translations$transcript$tool$en {
	Translations$transcript$tool$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Running…'
	String get running => 'Running…';

	/// en: 'Running in the background'
	String get background => 'Running in the background';

	/// en: 'Did not finish'
	String get interrupted => 'Did not finish';

	/// en: 'Error'
	String get error => 'Error';

	/// en: 'Arguments'
	String get arguments => 'Arguments';

	/// en: 'No output'
	String get noOutput => 'No output';

	/// en: 'Exit $code'
	String exitCode({required Object code}) => 'Exit ${code}';

	/// en: 'Timed out'
	String get timedOut => 'Timed out';

	/// en: '(one) {$n line} (other) {$n lines}'
	String lines({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} line',
		other: '${n} lines',
	);

	/// en: 'lines $from–$to'
	String lineRange({required Object from, required Object to}) => 'lines ${from}–${to}';

	/// en: 'Open file'
	String get openFile => 'Open file';

	/// en: 'Created'
	String get created => 'Created';

	/// en: 'Deleted'
	String get deleted => 'Deleted';

	/// en: 'Moved to $path'
	String movedTo({required Object path}) => 'Moved to ${path}';

	/// en: 'No changes'
	String get noChanges => 'No changes';

	/// en: '$done of $total done'
	String todoProgress({required Object done, required Object total}) => '${done} of ${total} done';

	/// en: '(one) {$n agent} (other) {$n agents}'
	String agents({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} agent',
		other: '${n} agents',
	);

	/// en: 'Open agent'
	String get openAgent => 'Open agent';

	/// en: 'Pending'
	String get agentPending => 'Pending';

	/// en: 'Running'
	String get agentRunning => 'Running';

	/// en: 'Done'
	String get agentCompleted => 'Done';

	/// en: 'Failed'
	String get agentFailed => 'Failed';

	/// en: 'Aborted'
	String get agentAborted => 'Aborted';

	/// en: 'Waiting for your answer below'
	String get askWaiting => 'Waiting for your answer below';

	/// en: 'Recommended'
	String get recommended => 'Recommended';

	/// en: 'Cancelled'
	String get cancelled => 'Cancelled';

	/// en: 'Note: $note'
	String note({required Object note}) => 'Note: ${note}';

	/// en: 'Chosen automatically after the timeout'
	String get autoSelected => 'Chosen automatically after the timeout';

	/// en: '(one) {$n source} (other) {$n sources}'
	String sources({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} source',
		other: '${n} sources',
	);

	/// en: 'Output'
	String get output => 'Output';

	/// en: 'Context'
	String get context => 'Context';

	/// en: 'Diagnostics'
	String get diagnostics => 'Diagnostics';

	/// en: 'Redirected to $url'
	String redirectedTo({required Object url}) => 'Redirected to ${url}';

	/// en: '$count tokens'
	String tokens({required Object count}) => '${count} tokens';
}

// Path: transcript.execution
class Translations$transcript$execution$en {
	Translations$transcript$execution$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Not sent to the model'
	String get notSent => 'Not sent to the model';

	/// en: 'Cancelled'
	String get cancelled => 'Cancelled';

	/// en: 'Output truncated'
	String get truncated => 'Output truncated';
}

// Path: transcript.turn
class Translations$transcript$turn$en {
	Translations$transcript$turn$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Worked for $duration'
	String workedFor({required Object duration}) => 'Worked for ${duration}';

	/// en: 'Worked'
	String get worked => 'Worked';

	/// en: '(one) {$n tool call} (other) {$n tool calls}'
	String toolCalls({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} tool call',
		other: '${n} tool calls',
	);

	/// en: '(one) {$n file edited} (other) {$n files edited}'
	String filesEdited({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n,
		one: '${n} file edited',
		other: '${n} files edited',
	);

	/// en: '${hours}h ${minutes}m'
	String durationHours({required Object hours, required Object minutes}) => '${hours}h ${minutes}m';

	/// en: '${minutes}m ${seconds}s'
	String durationMinutes({required Object minutes, required Object seconds}) => '${minutes}m ${seconds}s';

	/// en: '${seconds}s'
	String durationSeconds({required Object seconds}) => '${seconds}s';
}

// Path: config.sections
class Translations$config$sections$en {
	Translations$config$sections$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Settings'
	String get settings => 'Settings';

	/// en: 'Model roles'
	String get roles => 'Model roles';

	/// en: 'Providers'
	String get accounts => 'Providers';

	/// en: 'MCP servers'
	String get mcp => 'MCP servers';

	/// en: 'Plugins'
	String get plugins => 'Plugins';

	/// en: 'Skills'
	String get skills => 'Skills';

	/// en: 'Stats'
	String get stats => 'Stats';
}

// Path: config.scope
class Translations$config$scope$en {
	Translations$config$scope$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Global'
	String get global => 'Global';

	/// en: 'Project'
	String get project => 'Project';

	/// en: 'Open a session on this machine to edit its project settings.'
	String get projectNone => 'Open a session on this machine to edit its project settings.';
}

// Path: config.provenance
class Translations$config$provenance$en {
	Translations$config$provenance$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'env $name'
	String env({required Object name}) => 'env ${name}';

	/// en: 'The environment variable $name overrides the files.'
	String envHint({required Object name}) => 'The environment variable ${name} overrides the files.';

	/// en: 'override'
	String get runtime => 'override';

	/// en: 'Set for this omp process only (RPC mode or a runtime override); the app's sessions use it.'
	String get runtimeHint => 'Set for this omp process only (RPC mode or a runtime override); the app\'s sessions use it.';

	/// en: 'app overlay'
	String get overlay => 'app overlay';

	/// en: 'Forced by the app's per-session config overlay.'
	String get overlayHint => 'Forced by the app\'s per-session config overlay.';

	/// en: 'project'
	String get project => 'project';

	/// en: 'From the project's .omp/config.yml.'
	String get projectHint => 'From the project\'s .omp/config.yml.';

	/// en: 'global'
	String get global => 'global';

	/// en: 'From the profile's config.yml.'
	String get globalHint => 'From the profile\'s config.yml.';

	/// en: 'default'
	String get defaults => 'default';

	/// en: 'omp's default; no file sets it.'
	String get defaultsHint => 'omp\'s default; no file sets it.';
}

// Path: config.settings
class Translations$config$settings$en {
	Translations$config$settings$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Search settings'
	String get search => 'Search settings';

	/// en: 'Editing $path'
	String editing({required Object path}) => 'Editing ${path}';

	/// en: 'Config file only'
	String get advancedTab => 'Config file only';

	/// en: 'Settings without a row in omp's settings panel, grouped by their first key.'
	String get advancedNote => 'Settings without a row in omp\'s settings panel, grouped by their first key.';

	/// en: 'These are omp's terminal UI settings. The app's own look follows the app settings.'
	String get themeNote => 'These are omp\'s terminal UI settings. The app\'s own look follows the app settings.';

	/// en: 'No setting matches.'
	String get noMatches => 'No setting matches.';

	/// en: 'Reset to the inherited value'
	String get reset => 'Reset to the inherited value';

	/// en: 'unset'
	String get unset => 'unset';

	/// en: 'Suggested values'
	String get presets => 'Suggested values';

	/// en: 'Not a number'
	String get notANumber => 'Not a number';

	/// en: 'Not JSON: $error'
	String notJson({required Object error}) => 'Not JSON: ${error}';

	/// en: 'Expected a JSON object'
	String get expectedObject => 'Expected a JSON object';

	/// en: 'Expected a JSON array'
	String get expectedArray => 'Expected a JSON array';

	/// en: 'Configured'
	String get secretSet => 'Configured';

	/// en: 'Not set'
	String get secretUnset => 'Not set';

	/// en: 'Set…'
	String get secretEdit => 'Set…';

	/// en: 'Sent to the machine as a private file that omp reads and deletes; never shown or logged.'
	String get secretHelp => 'Sent to the machine as a private file that omp reads and deletes; never shown or logged.';

	/// en: 'Credentials are saved in the global config only.'
	String get secretGlobalOnly => 'Credentials are saved in the global config only.';

	/// en: 'Add'
	String get addItem => 'Add';

	/// en: 'In effect: $value (a higher layer wins)'
	String overriddenLine({required Object value}) => 'In effect: ${value} (a higher layer wins)';

	/// en: 'Could not read $path: $error'
	String fileError({required Object path, required Object error}) => 'Could not read ${path}: ${error}';
}

// Path: config.roles
class Translations$config$roles$en {
	Translations$config$roles$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'omp's model picker saves roles to: $storage'
	String storage({required Object storage}) => 'omp\'s model picker saves roles to: ${storage}';

	/// en: 'Project: $path'
	String projectIs({required Object path}) => 'Project: ${path}';

	/// en: 'Open a session on this machine to assign project roles.'
	String get noProject => 'Open a session on this machine to assign project roles.';

	/// en: 'Refresh models'
	String get refreshModels => 'Refresh models';

	/// en: 'Model list refreshed.'
	String get modelsRefreshed => 'Model list refreshed.';

	/// en: 'Chat roles'
	String get chatRoles => 'Chat roles';

	/// en: 'Task kinds'
	String get kindRoles => 'Task kinds';

	/// en: 'In effect'
	String get effective => 'In effect';

	/// en: 'Project'
	String get projectLayer => 'Project';

	/// en: 'auto'
	String get auto => 'auto';

	/// en: 'Set'
	String get assign => 'Set';

	/// en: 'Clear'
	String get clear => 'Clear';

	/// en: 'Model for $role'
	String pickTitle({required Object role}) => 'Model for ${role}';

	/// en: 'Search models'
	String get searchModels => 'Search models';

	/// en: 'Thinking level'
	String get thinking => 'Thinking level';

	/// en: 'model default'
	String get thinkingDefault => 'model default';

	/// en: 'Use $selector'
	String useTyped({required Object selector}) => 'Use ${selector}';

	/// en: 'A model omp does not list as available here'
	String get useTypedHint => 'A model omp does not list as available here';

	/// en: '$tokens context'
	String context({required Object tokens}) => '${tokens} context';

	/// en: 'images'
	String get vision => 'images';

	/// en: 'No model matches.'
	String get noModels => 'No model matches.';
}

// Path: config.accounts
class Translations$config$accounts$en {
	Translations$config$accounts$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Credentials are stored per machine.'
	String get machineWide => 'Credentials are stored per machine.';

	/// en: 'In use and pinned marks refer to the session in $path.'
	String sessionView({required Object path}) => 'In use and pinned marks refer to the session in ${path}.';

	/// en: 'in use'
	String get active => 'in use';

	/// en: 'pinned'
	String get sticky => 'pinned';

	/// en: 'expires $date'
	String expires({required Object date}) => 'expires ${date}';

	/// en: 'Pin to session'
	String get pin => 'Pin to session';

	/// en: 'Account pinned to the session.'
	String get pinned => 'Account pinned to the session.';

	/// en: 'Log out'
	String get logout => 'Log out';

	/// en: 'Log out $account?'
	String logoutTitle({required Object account}) => 'Log out ${account}?';

	/// en: 'The stored credential for $provider is removed from this machine.'
	String logoutBody({required Object provider}) => 'The stored credential for ${provider} is removed from this machine.';

	/// en: 'The browser opens on this computer.'
	String get oauthLocal => 'The browser opens on this computer.';

	/// en: 'The browser opens on this device; the app forwards omp's callback port to the machine.'
	String get oauthRemote => 'The browser opens on this device; the app forwards omp\'s callback port to the machine.';

	/// en: 'Save key'
	String get saveKey => 'Save key';

	/// en: 'Key stored for $provider.'
	String keyStored({required Object provider}) => 'Key stored for ${provider}.';

	/// en: 'Log in to $provider'
	String loginTitle({required Object provider}) => 'Log in to ${provider}';

	/// en: 'Waiting for omp's authorization link…'
	String get waitingForLink => 'Waiting for omp\'s authorization link…';

	/// en: 'Open this link and sign in:'
	String get openLink => 'Open this link and sign in:';

	/// en: 'Open browser'
	String get openBrowser => 'Open browser';

	/// en: 'Copy link'
	String get copyLink => 'Copy link';

	/// en: 'Forwarding local port $ports to the machine for the callback.'
	String forwarding({required Object ports}) => 'Forwarding local port ${ports} to the machine for the callback.';

	/// en: 'Could not forward port $port ($error). Paste the redirect URL when omp asks for it.'
	String forwardFailed({required Object port, required Object error}) => 'Could not forward port ${port} (${error}). Paste the redirect URL when omp asks for it.';

	/// en: 'Submit'
	String get submit => 'Submit';

	/// en: 'Yes'
	String get yes => 'Yes';

	/// en: 'No'
	String get no => 'No';

	/// en: 'Logged in.'
	String get loggedIn => 'Logged in.';

	/// en: 'No model works on this machine yet. Sign in with an account or add an API key; settings and roles work meanwhile.'
	String get bootstrap => 'No model works on this machine yet. Sign in with an account or add an API key; settings and roles work meanwhile.';

	/// en: 'Search providers'
	String get search => 'Search providers';

	/// en: 'No provider matches.'
	String get noMatches => 'No provider matches.';

	/// en: 'signed in'
	String get signedIn => 'signed in';

	/// en: 'Sign in'
	String get signIn => 'Sign in';

	/// en: 'Paste an API key'
	String get keyHint => 'Paste an API key';

	/// en: 'Other provider…'
	String get other => 'Other provider…';

	/// en: 'Provider id'
	String get otherId => 'Provider id';

	/// en: 'Stores a key under a provider id this list does not show, as models.yml or an extension names it.'
	String get otherNote => 'Stores a key under a provider id this list does not show, as models.yml or an extension names it.';

	late final Translations$config$accounts$kind$en kind = Translations$config$accounts$kind$en.internal(_root);
	late final Translations$config$accounts$source$en source = Translations$config$accounts$source$en.internal(_root);
	late final Translations$config$accounts$overridden$en overridden = Translations$config$accounts$overridden$en.internal(_root);
}

// Path: config.mcp
class Translations$config$mcp$en {
	Translations$config$mcp$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'User: $path'
	String userFile({required Object path}) => 'User: ${path}';

	/// en: 'Project: $path'
	String projectFile({required Object path}) => 'Project: ${path}';

	/// en: 'Add server'
	String get add => 'Add server';

	/// en: 'Add MCP server'
	String get addTitle => 'Add MCP server';

	/// en: 'Reload'
	String get reload => 'Reload';

	/// en: 'Resources'
	String get resources => 'Resources';

	/// en: 'Prompts'
	String get prompts => 'Prompts';

	/// en: 'Search Smithery'
	String get smithery => 'Search Smithery';

	/// en: 'No MCP servers configured.'
	String get none => 'No MCP servers configured.';

	/// en: 'user'
	String get userScope => 'user';

	/// en: 'project'
	String get projectScope => 'project';

	/// en: 'Test'
	String get test => 'Test';

	/// en: 'Remove $name?'
	String removeTitle({required Object name}) => 'Remove ${name}?';

	/// en: 'The server is removed from the $scope mcp.json.'
	String removeBody({required Object scope}) => 'The server is removed from the ${scope} mcp.json.';

	/// en: 'Name'
	String get name => 'Name';

	/// en: 'At most 100 characters'
	String get nameTooLong => 'At most 100 characters';

	/// en: 'Only letters, digits, - _ . : and single spaces'
	String get nameInvalid => 'Only letters, digits, - _ . : and single spaces';

	/// en: 'Command'
	String get command => 'Command';

	/// en: 'URL'
	String get url => 'URL';

	/// en: 'Bearer token (optional)'
	String get token => 'Bearer token (optional)';

	/// en: 'Written into the user mcp.json as an Authorization header.'
	String get tokenHint => 'Written into the user mcp.json as an Authorization header.';

	/// en: 'Only user-scope servers take a token here: a project session would keep it in its run log.'
	String get tokenUserOnly => 'Only user-scope servers take a token here: a project session would keep it in its run log.';

	/// en: 'omp 18.3.1 offers reauth, unauth, reconnect and Smithery login only in its terminal UI.'
	String get tuiOnly => 'omp 18.3.1 offers reauth, unauth, reconnect and Smithery login only in its terminal UI.';

	/// en: 'Enable the server to test it; omp loads only enabled servers.'
	String get testDisabled => 'Enable the server to test it; omp loads only enabled servers.';

	/// en: 'Smithery registry'
	String get smitheryTitle => 'Smithery registry';
}

// Path: config.plugins
class Translations$config$plugins$en {
	Translations$config$plugins$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Commands run in $path'
	String inProject({required Object path}) => 'Commands run in ${path}';

	/// en: 'Installed'
	String get installed => 'Installed';

	/// en: 'No plugins installed.'
	String get none => 'No plugins installed.';

	/// en: 'npm'
	String get npm => 'npm';

	/// en: 'Uninstall'
	String get uninstall => 'Uninstall';

	/// en: 'Upgrade'
	String get upgrade => 'Upgrade';

	/// en: 'Update'
	String get update => 'Update';

	/// en: 'marketplace · $scope'
	String marketplaceScope({required Object scope}) => 'marketplace · ${scope}';

	/// en: 'shadowed'
	String get shadowed => 'shadowed';

	/// en: 'Install'
	String get install => 'Install';

	/// en: 'An npm package, name@marketplace, github:user/repo, a git URL or a local path. npm installs need bun on the machine.'
	String get installHint => 'An npm package, name@marketplace, github:user/repo, a git URL or a local path. npm installs need bun on the machine.';

	/// en: '@oh-my-pi/exa'
	String get installPlaceholder => '@oh-my-pi/exa';

	/// en: 'Install'
	String get installAction => 'Install';

	/// en: 'Marketplaces'
	String get marketplaces => 'Marketplaces';

	/// en: 'Update all'
	String get updateAll => 'Update all';

	/// en: 'No marketplaces configured.'
	String get noMarketplaces => 'No marketplaces configured.';

	/// en: 'installed'
	String get isInstalled => 'installed';

	/// en: 'owner/repo, git URL or local path'
	String get sourcePlaceholder => 'owner/repo, git URL or local path';

	/// en: 'Add marketplace'
	String get addMarketplace => 'Add marketplace';
}

// Path: config.skills
class Translations$config$skills$en {
	Translations$config$skills$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Registry skills from skills.omp.sh'
	String get registry => 'Registry skills from skills.omp.sh';

	/// en: 'Installed'
	String get installed => 'Installed';

	/// en: 'No registry skills installed.'
	String get none => 'No registry skills installed.';

	/// en: 'not installed'
	String get notInstalled => 'not installed';

	/// en: 'range $range'
	String range({required Object range}) => 'range ${range}';

	/// en: 'Info'
	String get info => 'Info';

	/// en: 'Search the registry'
	String get search => 'Search the registry';

	/// en: 'pdf, git, review…'
	String get searchHint => 'pdf, git, review…';

	/// en: '$shown of $total'
	String results({required Object shown, required Object total}) => '${shown} of ${total}';

	/// en: '$number weekly downloads'
	String downloads({required Object number}) => '${number} weekly downloads';

	/// en: 'by $name'
	String by({required Object name}) => 'by ${name}';

	/// en: 'Deprecated: $reason'
	String deprecated({required Object reason}) => 'Deprecated: ${reason}';

	/// en: 'Install $id for'
	String installWhere({required Object id}) => 'Install ${id} for';

	/// en: 'Every project (user)'
	String get forUser => 'Every project (user)';

	/// en: 'This project ($path)'
	String forProject({required Object path}) => 'This project (${path})';

	/// en: 'This skill ships scripts'
	String get scriptsTitle => 'This skill ships scripts';

	/// en: 'Installing it runs its scripts on the machine. Install anyway?'
	String get scriptsBody => 'Installing it runs its scripts on the machine. Install anyway?';

	/// en: 'Install anyway'
	String get installAnyway => 'Install anyway';

	/// en: 'License: $license'
	String license({required Object license}) => 'License: ${license}';

	/// en: 'Latest: $version'
	String latest({required Object version}) => 'Latest: ${version}';

	/// en: 'Versions: $versions'
	String versions({required Object versions}) => 'Versions: ${versions}';

	/// en: 'Owners: $owners'
	String owners({required Object owners}) => 'Owners: ${owners}';

	/// en: 'Downloads: $weekly weekly, $total total'
	String downloadsTotal({required Object weekly, required Object total}) => 'Downloads: ${weekly} weekly, ${total} total';

	/// en: 'Ships scripts.'
	String get shipsScripts => 'Ships scripts.';

	/// en: 'Nothing on skills.omp.sh matches "$query".'
	String noHits({required Object query}) => 'Nothing on skills.omp.sh matches "${query}".';
}

// Path: config.stats
class Translations$config$stats$en {
	Translations$config$stats$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '$from – $to'
	String span({required Object from, required Object to}) => '${from} – ${to}';

	/// en: 'No requests recorded yet.'
	String get none => 'No requests recorded yet.';

	/// en: 'Requests'
	String get requests => 'Requests';

	/// en: 'Errors'
	String get errors => 'Errors';

	/// en: 'Input tokens'
	String get inputTokens => 'Input tokens';

	/// en: 'Output tokens'
	String get outputTokens => 'Output tokens';

	/// en: 'Cache read'
	String get cacheRead => 'Cache read';

	/// en: 'Cost'
	String get cost => 'Cost';

	/// en: 'Avg. first token'
	String get ttft => 'Avg. first token';

	/// en: 'Avg. speed'
	String get speed => 'Avg. speed';

	/// en: 'Requests per hour'
	String get perHour => 'Requests per hour';

	/// en: 'By model'
	String get byModel => 'By model';

	/// en: 'By project'
	String get byFolder => 'By project';

	/// en: 'By agent'
	String get byAgent => 'By agent';

	/// en: 'Model'
	String get model => 'Model';

	/// en: 'Project'
	String get folder => 'Project';

	/// en: 'Agent'
	String get agent => 'Agent';
}

// Path: dock.hub.status
class Translations$dock$hub$status$en {
	Translations$dock$hub$status$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Running'
	String get running => 'Running';

	/// en: 'Pending'
	String get pending => 'Pending';

	/// en: 'Idle'
	String get idle => 'Idle';

	/// en: 'Parked'
	String get parked => 'Parked';

	/// en: 'Completed'
	String get completed => 'Completed';

	/// en: 'Failed'
	String get failed => 'Failed';

	/// en: 'Killed'
	String get aborted => 'Killed';
}

// Path: dock.fileBrowser.git
class Translations$dock$fileBrowser$git$en {
	Translations$dock$fileBrowser$git$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Modified'
	String get modified => 'Modified';

	/// en: 'Added'
	String get added => 'Added';

	/// en: 'Deleted'
	String get deleted => 'Deleted';

	/// en: 'Renamed'
	String get renamed => 'Renamed';

	/// en: 'Copied'
	String get copied => 'Copied';

	/// en: 'Type changed'
	String get typeChanged => 'Type changed';

	/// en: 'Untracked'
	String get untracked => 'Untracked';

	/// en: 'Ignored'
	String get ignored => 'Ignored';

	/// en: 'Conflicted'
	String get conflicted => 'Conflicted';
}

// Path: config.accounts.kind
class Translations$config$accounts$kind$en {
	Translations$config$accounts$kind$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'account'
	String get account => 'account';

	/// en: 'API key'
	String get apiKey => 'API key';

	/// en: 'local'
	String get local => 'local';
}

// Path: config.accounts.source
class Translations$config$accounts$source$en {
	Translations$config$accounts$source$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'omp uses a key set for this omp process only.'
	String get runtime => 'omp uses a key set for this omp process only.';

	/// en: 'omp uses the key that models.yml sets.'
	String get config => 'omp uses the key that models.yml sets.';

	/// en: 'omp uses a signed-in account.'
	String get oauth => 'omp uses a signed-in account.';

	/// en: 'omp uses a stored API key.'
	String get apiKey => 'omp uses a stored API key.';

	/// en: 'omp uses the key in the environment variable $name.'
	String env({required Object name}) => 'omp uses the key in the environment variable ${name}.';

	/// en: 'omp has a working credential for this provider.'
	String get working => 'omp has a working credential for this provider.';

	/// en: 'Not signed in.'
	String get none => 'Not signed in.';

	/// en: 'No key stored.'
	String get noKey => 'No key stored.';
}

// Path: config.accounts.overridden
class Translations$config$accounts$overridden$en {
	Translations$config$accounts$overridden$en.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'models.yml sets a key for this provider, so omp uses that key and not the stored one.'
	String get config => 'models.yml sets a key for this provider, so omp uses that key and not the stored one.';

	/// en: 'The environment variable $name sets a key, so omp uses it and not the stored one.'
	String env({required Object name}) => 'The environment variable ${name} sets a key, so omp uses it and not the stored one.';

	/// en: 'A key set for this omp process wins over the stored one.'
	String get runtime => 'A key set for this omp process wins over the stored one.';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'ompanion',
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
			'shell.usageTitle' => 'Usage',
			'shell.settingsTitle' => 'Settings',
			'usage.fetchAgain' => 'Ask providers again',
			'usage.fetched' => ({required Object ago}) => 'Fetched ${ago} ago',
			'usage.notFetched' => 'Not fetched yet',
			'usage.none' => 'No usage data. Accounts of providers with a usage endpoint (for example Claude and ChatGPT subscriptions) show their limits here.',
			'usage.noMachines' => 'No machines yet. Add one in the sidebar.',
			'usage.machines' => 'Machines',
			'usage.asking' => 'Asking omp…',
			'usage.machineAccounts' => ({required num n, required Object version}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: 'omp ${version} · ${n} account', other: 'omp ${version} · ${n} accounts', ), 
			'usage.providerAccounts' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} account', other: '${n} accounts', ), 
			'usage.accountN' => ({required Object n}) => 'account ${n}',
			'usage.apiKey' => 'API key',
			'usage.oauthAccount' => 'OAuth account',
			'usage.plan' => ({required Object plan}) => 'plan: ${plan}',
			'usage.daybreak' => 'daybreak',
			'usage.savedResets' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} saved reset', other: '${n} saved resets', ), 
			'usage.usableNow' => ({required Object n}) => '${n} usable now',
			'usage.resetExpiresIn' => ({required Object duration, required Object date}) => 'soonest expires in ${duration} (${date})',
			'usage.resetExpired' => ({required Object date}) => 'expired (${date})',
			'usage.resetUnavailable' => ({required Object reason}) => 'unavailable: ${reason}',
			'usage.resetCooldown' => ({required Object time}) => 'cooldown until ${time}',
			'usage.resetBlocked' => ({required Object windows}) => 'blocked by ${windows}',
			'usage.resetNotEligible' => 'not eligible',
			'usage.resetNotUsable' => 'not usable right now',
			'usage.fetchedAgo' => ({required Object ago}) => 'fetched ${ago} ago',
			'usage.policy' => ({required Object priority, required Object reserve}) => 'policy: priority ${priority} · reserve ${reserve}',
			'usage.reserveGlobal' => ({required Object percent}) => '${percent}% (global)',
			'usage.reserveOverride' => ({required Object percent}) => '${percent}% (override)',
			'usage.reserveUnknown' => 'reserve unknown',
			'usage.eligible' => ({required Object percent}) => 'eligible · ${percent}% left',
			'usage.insideReserve' => ({required Object percent}) => 'inside reserve · ${percent}% left',
			'usage.policyOn' => ({required Object line, required Object machine}) => '${line} (${machine})',
			'usage.noLimits' => 'no limits reported',
			'usage.notReported' => 'not reported',
			'usage.noData' => 'no data',
			'usage.amountOf' => ({required Object used, required Object limit}) => '${used} / ${limit}',
			'usage.amountLeft' => ({required Object amount}) => '${amount} left',
			'usage.amountUsed' => ({required Object amount}) => '${amount} used',
			'usage.percentUsed' => ({required Object percent}) => '${percent}% used',
			'usage.percentLeft' => ({required Object percent}) => '${percent}% left',
			'usage.resets' => 'resets',
			'usage.resetsIn' => ({required Object verb, required Object duration}) => '${verb} in ${duration}',
			'usage.units.tokens' => ({required Object value}) => '${value} tokens',
			'usage.units.requests' => ({required Object value}) => '${value} requests',
			'usage.units.credits' => ({required Object value}) => '${value} credits',
			'usage.units.minutes' => ({required Object value}) => '${value} min',
			'usage.units.bytes' => ({required Object value}) => '${value} bytes',
			'usage.withoutUsage' => 'no usage data',
			'usage.disabledAgo' => ({required Object ago, required Object cause}) => 'disabled ${ago} ago: ${cause}',
			'usage.disabled' => ({required Object cause}) => 'disabled: ${cause}',
			'usage.reloginToRestore' => '(re-login to restore)',
			'usage.reloginWithin' => ({required Object duration}) => 're-login within ${duration} (Anthropic expires OAuth grants ~30d after login)',
			'usage.reloginNow' => 'grant is past Anthropic\'s ~30d lifetime; re-login now',
			'usage.capacity' => 'Capacity',
			'usage.capacityWindow' => ({required num n, required Object used, required Object left}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${used}/${n} account used · ${left}× quota left', other: '${used}/${n} accounts used · ${left}× quota left', ), 
			'dock.agents' => 'Agents',
			'dock.todos' => 'Todos',
			'dock.tree' => 'Tree',
			'dock.files' => 'Files',
			'dock.terminal' => 'Terminal',
			'dock.noSession' => 'Open a session to use this panel.',
			'dock.noMachine' => 'Open a session or select a machine to use this panel.',
			'dock.todo.empty' => 'No todos yet. The agent\'s todo list shows up here.',
			'dock.todo.progress' => ({required Object done, required Object total}) => '${done}/${total}',
			'dock.todo.pending' => 'Pending',
			'dock.todo.inProgress' => 'In progress',
			'dock.todo.completed' => 'Completed',
			'dock.todo.abandoned' => 'Abandoned',
			'dock.todo.blocked' => 'Blocked',
			'dock.todo.blockedBy' => ({required Object reason}) => 'Blocked: ${reason}',
			'dock.hub.empty' => 'No subagents yet. Agents the session starts show up here.',
			'dock.hub.summary' => ({required Object count, required Object running}) => 'Agents: ${count} · running: ${running}',
			'dock.hub.showList' => 'Show as list',
			'dock.hub.showTree' => 'Show as tree',
			'dock.hub.advisor' => 'advisor',
			'dock.hub.tokens' => ({required Object count}) => '${count} tok',
			'dock.hub.tools' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} tool', other: '${n} tools', ), 
			'dock.hub.context' => ({required Object percent}) => 'context ${percent}%',
			'dock.hub.status.running' => 'Running',
			'dock.hub.status.pending' => 'Pending',
			'dock.hub.status.idle' => 'Idle',
			'dock.hub.status.parked' => 'Parked',
			'dock.hub.status.completed' => 'Completed',
			'dock.hub.status.failed' => 'Failed',
			'dock.hub.status.aborted' => 'Killed',
			'dock.hub.back' => 'Back to agents',
			'dock.hub.actions' => 'Agent actions',
			'dock.hub.revive' => 'Revive',
			'dock.hub.revived' => 'Agent revived.',
			'dock.hub.kill' => 'Kill',
			'dock.hub.killed' => 'Agent killed.',
			'dock.hub.killTitle' => ({required Object name}) => 'Kill ${name}?',
			'dock.hub.killBody' => 'Its running turn is aborted and the agent is released for good. It cannot be revived.',
			'dock.hub.copyId' => 'Copy agent id',
			'dock.hub.steer' => 'Send',
			'dock.hub.steered' => 'Sent to the agent.',
			'dock.hub.steerHint' => 'Message this agent…',
			'dock.hub.steerParkedHint' => 'Message wakes this parked agent…',
			'dock.hub.advisorReadOnly' => 'Advisors are read-only.',
			'dock.hub.noTranscript' => 'No transcript yet.',
			'dock.hub.transcriptFailed' => ({required Object error}) => 'Transcript unavailable: ${error}',
			'dock.hub.failed' => ({required Object error}) => 'Failed: ${error}',
			'dock.hub.noCompanion' => 'The companion is not loaded in this session, so messaging, killing and reviving agents are unavailable.',
			'dock.hub.durationHours' => ({required Object hours, required Object minutes}) => '${hours}h ${minutes}m',
			'dock.hub.durationMinutes' => ({required Object minutes, required Object seconds}) => '${minutes}m ${seconds}s',
			'dock.hub.durationSeconds' => ({required Object seconds}) => '${seconds}s',
			'dock.sessionTree.search' => 'Search entries',
			'dock.sessionTree.filter' => 'Filter',
			'dock.sessionTree.filterStandard' => 'Conversation',
			'dock.sessionTree.filterNoTools' => 'Without tool results',
			'dock.sessionTree.filterUserOnly' => 'Your messages',
			'dock.sessionTree.filterLabeled' => 'Labeled',
			'dock.sessionTree.filterAll' => 'Everything',
			'dock.sessionTree.refresh' => 'Refresh',
			'dock.sessionTree.loadFailed' => ({required Object error}) => 'Could not load the tree: ${error}',
			'dock.sessionTree.empty' => 'No entries yet.',
			'dock.sessionTree.noMatches' => 'No entries match.',
			'dock.sessionTree.currentLeaf' => 'Current position',
			'dock.sessionTree.navigate' => 'Go here',
			'dock.sessionTree.navigateWithSummary' => 'Go here with summary…',
			'dock.sessionTree.label' => 'Label…',
			'dock.sessionTree.branch' => 'Branch into new session',
			'dock.sessionTree.copyText' => 'Copy text',
			'dock.sessionTree.summarizing' => 'Summarizing the branch you are leaving…',
			'dock.sessionTree.abort' => 'Abort',
			'dock.sessionTree.summaryAborted' => 'Summary aborted. Nothing moved.',
			'dock.sessionTree.navigationCancelled' => 'Navigation cancelled.',
			'dock.sessionTree.branchCancelled' => 'Branch cancelled.',
			'dock.sessionTree.branched' => 'Branched into a new session. The message is back in the composer.',
			'dock.sessionTree.failed' => ({required Object error}) => 'Failed: ${error}',
			'dock.sessionTree.aborted' => '(aborted)',
			'dock.sessionTree.noContent' => '(no content)',
			'dock.sessionTree.compaction' => ({required Object tokens}) => 'Compaction (${tokens} tokens)',
			'dock.sessionTree.branchSummary' => ({required Object summary}) => 'Branch summary: ${summary}',
			'dock.sessionTree.model' => ({required Object model}) => 'Model: ${model}',
			'dock.sessionTree.thinking' => ({required Object level}) => 'Thinking: ${level}',
			'dock.sessionTree.labelSet' => ({required Object label}) => 'Label: ${label}',
			'dock.sessionTree.labelCleared' => 'Label cleared',
			'dock.sessionTree.advisor' => ({required Object notes}) => 'advisor: ${notes}',
			'dock.sessionTree.advisorTagged' => ({required Object tags, required Object notes}) => 'advisor (${tags}): ${notes}',
			'dock.sessionTree.summaryTitle' => 'Summarize the branch you leave',
			'dock.sessionTree.summaryBody' => 'omp writes a summary of the abandoned branch at the new position. This makes a model call.',
			'dock.sessionTree.summaryInstructions' => 'Custom instructions (optional)',
			'dock.sessionTree.summarize' => 'Summarize and go',
			'dock.sessionTree.labelTitle' => 'Label entry',
			'dock.sessionTree.labelField' => 'Label',
			'dock.sessionTree.clearLabel' => 'Clear label',
			'dock.sessionTree.noCompanion' => 'The companion is not loaded in this session, so going to an entry and labels are unavailable.',
			'dock.fileBrowser.up' => 'Parent folder',
			'dock.fileBrowser.refresh' => 'Refresh',
			'dock.fileBrowser.newFile' => 'New file',
			'dock.fileBrowser.newFolder' => 'New folder',
			'dock.fileBrowser.create' => 'Create',
			'dock.fileBrowser.rename' => 'Rename',
			'dock.fileBrowser.open' => 'Open',
			'dock.fileBrowser.browseHere' => 'Browse',
			'dock.fileBrowser.copyPath' => 'Copy path',
			'dock.fileBrowser.name' => 'Name',
			'dock.fileBrowser.nameReserved' => 'This name is reserved.',
			'dock.fileBrowser.nameSeparator' => 'Names cannot contain / or \.',
			'dock.fileBrowser.exists' => ({required Object name}) => '${name} already exists.',
			'dock.fileBrowser.failed' => ({required Object error}) => 'Failed: ${error}',
			'dock.fileBrowser.deleteTitle' => ({required Object name}) => 'Delete ${name}?',
			'dock.fileBrowser.deleteFileBody' => 'The file is deleted from the machine.',
			'dock.fileBrowser.deleteFolderBody' => 'The folder and everything in it are deleted from the machine.',
			'dock.fileBrowser.deleteLinkBody' => 'The symbolic link is deleted from the machine. What it points to stays.',
			'dock.fileBrowser.link' => 'Symbolic link',
			'dock.fileBrowser.emptyFolder' => 'Empty folder',
			'dock.fileBrowser.listFailed' => ({required Object error}) => 'Could not list: ${error}',
			'dock.fileBrowser.openDocuments' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} open file', other: '${n} open files', ), 
			'dock.fileBrowser.openFailed' => ({required Object error}) => 'Could not open: ${error}',
			'dock.fileBrowser.backToFiles' => 'Back to files',
			'dock.fileBrowser.save' => 'Save',
			'dock.fileBrowser.saved' => ({required Object name}) => 'Saved ${name}.',
			'dock.fileBrowser.saveFailed' => ({required Object error}) => 'Save failed: ${error}',
			'dock.fileBrowser.more' => 'More',
			'dock.fileBrowser.find' => 'Find',
			'dock.fileBrowser.reload' => 'Reload from disk',
			'dock.fileBrowser.showDiff' => 'Show git diff',
			'dock.fileBrowser.showFile' => 'Show file',
			'dock.fileBrowser.conflictTitle' => 'File changed on the machine',
			'dock.fileBrowser.conflictChanged' => 'The file changed on the machine since you opened it. Overwrite it with your version, or discard your edits and reload it?',
			'dock.fileBrowser.conflictDeleted' => 'The file was deleted on the machine since you opened it. Overwrite recreates it.',
			'dock.fileBrowser.overwrite' => 'Overwrite',
			'dock.fileBrowser.discardAndReload' => 'Discard and reload',
			'dock.fileBrowser.discardTitle' => ({required Object name}) => 'Discard changes to ${name}?',
			'dock.fileBrowser.discardBody' => 'Your unsaved edits are lost.',
			'dock.fileBrowser.discard' => 'Discard',
			'dock.fileBrowser.tooLarge' => ({required Object mb}) => 'Larger than ${mb} MB: showing the beginning, read-only.',
			'dock.fileBrowser.binary' => 'Binary file. Not shown.',
			'dock.fileBrowser.notUtf8' => 'Not UTF-8 text: read-only, so saving cannot damage it.',
			'dock.fileBrowser.noMatches' => 'No results',
			'dock.fileBrowser.replace' => 'Replace',
			'dock.fileBrowser.replaceAll' => 'Replace all',
			'dock.fileBrowser.caseSensitive' => 'Match case',
			'dock.fileBrowser.previousMatch' => 'Previous match',
			'dock.fileBrowser.nextMatch' => 'Next match',
			'dock.fileBrowser.noChanges' => 'No changes against HEAD.',
			'dock.fileBrowser.diffFailed' => ({required Object error}) => 'git diff failed: ${error}',
			'dock.fileBrowser.diffTruncated' => ({required Object shown, required Object total}) => 'Showing ${shown} of ${total} diff lines.',
			'dock.fileBrowser.git.modified' => 'Modified',
			'dock.fileBrowser.git.added' => 'Added',
			'dock.fileBrowser.git.deleted' => 'Deleted',
			'dock.fileBrowser.git.renamed' => 'Renamed',
			'dock.fileBrowser.git.copied' => 'Copied',
			'dock.fileBrowser.git.typeChanged' => 'Type changed',
			'dock.fileBrowser.git.untracked' => 'Untracked',
			'dock.fileBrowser.git.ignored' => 'Ignored',
			'dock.fileBrowser.git.conflicted' => 'Conflicted',
			'dock.terminals.newTerminal' => 'New terminal',
			'dock.terminals.empty' => ({required Object machine}) => 'No terminal open on ${machine}.',
			'dock.terminals.close' => 'Close',
			'dock.terminals.restart' => 'Restart',
			'dock.terminals.smaller' => 'Smaller text',
			'dock.terminals.larger' => 'Larger text',
			'dock.terminals.paste' => 'Paste',
			'dock.terminals.selectAll' => 'Select all',
			'dock.terminals.clear' => 'Clear',
			'dock.terminals.failed' => ({required Object error}) => 'Terminal failed: ${error}',
			'dock.terminals.exited' => ({required Object code}) => 'The shell exited with code ${code}.',
			'dock.terminals.exitedBySignal' => 'The shell ended.',
			'sidebar.addMachine' => 'Add machine',
			'sidebar.more' => 'More',
			'sidebar.importMachines' => 'Import machines…',
			'sidebar.exportMachines' => 'Export machines…',
			'sidebar.keys' => 'SSH keys',
			'sidebar.usage' => 'Usage',
			'sidebar.settings' => 'Settings',
			'sidebar.noMachines' => 'No machines yet.',
			'sidebar.search' => 'Search sessions',
			'sidebar.searchHint' => 'Search',
			'sidebar.noMatches' => 'No matching sessions.',
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
			'machines.facts' => 'System',
			'machines.status' => 'Status',
			'machines.os' => 'OS',
			'machines.arch' => 'Architecture',
			'machines.shell' => 'Shell',
			'machines.loginPath' => 'Login PATH',
			'machines.home' => 'Home',
			'machines.omp' => 'omp',
			'machines.ompVersion' => 'omp version',
			'machines.companion' => 'Companion',
			'machines.companionReady' => 'Uploaded',
			'machines.companionMissing' => 'Not uploaded',
			'machines.notFound' => 'Not found',
			'machines.notProbed' => 'Connect to read the machine\'s OS, shell and omp.',
			'auth.key' => 'Key',
			'auth.password' => 'Password',
			'auth.agent' => 'SSH config and agent (like ssh)',
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
			'editor.agentHelp' => 'Like the ssh command: the ssh-agent\'s keys (IdentityAgent, else SSH_AUTH_SOCK), then the IdentityFile keys ~/.ssh/config sets for this host, else ~/.ssh/id_ed25519, id_ecdsa and id_rsa. Encrypted keys ask for their passphrase. If the host refuses every key, its password prompt follows.',
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
			'hostKey.otherTypesTitle' => 'Unexpected key type',
			'hostKey.otherTypesBody' => ({required Object host}) => '~/.ssh/known_hosts knows ${host} only with keys of other types. The server may have added a key type, or someone may be intercepting the connection. Compare the fingerprint with the server\'s key before you trust it.',
			'hostKey.knownToOpenSsh' => 'Known in ~/.ssh/known_hosts',
			'links.confirmTitle' => 'Open this link?',
			'links.confirmBody' => ({required Object scheme}) => 'This is a ${scheme}: link, not a web page. It opens whichever app handles ${scheme}: links on this device.',
			'links.open' => 'Open',
			'prompt.passwordTitle' => ({required Object hop}) => 'Password for ${hop}',
			'prompt.signInTitle' => ({required Object hop}) => 'Sign in to ${hop}',
			'prompt.passphraseTitle' => ({required Object path}) => 'Passphrase for ${path}',
			'prompt.passphraseAccepted' => ({required Object hop}) => '${hop} accepts this key. Enter its passphrase to use it.',
			'prompt.passphraseUnknownKey' => ({required Object hop}) => 'Enter the passphrase to offer this key to ${hop}.',
			'prompt.passphraseWrong' => 'Wrong passphrase.',
			'prompt.passphrase' => 'Passphrase',
			'prompt.rememberPassphrase' => 'Remember on this device',
			'connectError.noKeySelected' => ({required Object hop}) => '${hop} uses key authentication, but no key is selected. Edit the machine to choose one.',
			'connectError.keyMissing' => ({required Object hop}) => 'The private key for ${hop} is missing from this device.',
			'connectError.passwordMissing' => ({required Object hop}) => 'No password for ${hop}.',
			'connectError.unreachable' => ({required Object hop}) => 'Could not reach ${hop}.',
			'connectError.hostKeyRejected' => ({required Object hop}) => 'The host key of ${hop} was not trusted.',
			'connectError.authFailed' => ({required Object hop}) => '${hop} rejected the credentials.',
			'connectError.timeout' => ({required Object hop}) => '${hop} did not answer in time.',
			'connectError.keyUnavailable' => ({required Object hop}) => 'The key for ${hop} cannot be used on this device.',
			'connectError.protocol' => ({required Object hop}) => 'SSH handshake with ${hop} failed.',
			'connectError.keyRefused' => ({required Object host, required Object key}) => '${host} did not accept the key ${key}.',
			'connectError.agentKeysRefused' => ({required num n, required Object host}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${host} did not accept the ${n} key in the ssh-agent.', other: '${host} did not accept any of the ${n} keys in the ssh-agent.', ), 
			'connectError.keysRefused' => ({required Object host}) => '${host} did not accept any of these keys:',
			'connectError.agentKey' => ({required Object comment}) => '${comment} from the ssh-agent',
			'connectError.agentKeyUnnamed' => 'a key from the ssh-agent',
			'connectError.authorizedKeysHint' => ({required Object user, required Object host}) => 'Add the public key to ~/.ssh/authorized_keys of ${user} on ${host}.',
			'connectError.noKeys' => ({required Object host}) => 'No key to offer ${host}. Add one to the ssh-agent with ssh-add, or name it with IdentityFile in ~/.ssh/config.',
			'tailscale.title' => 'Tailscale devices',
			'tailscale.notInstalled' => 'Tailscale is not installed on this computer.',
			'tailscale.failed' => ({required Object message}) => 'Tailscale did not answer: ${message}',
			'tailscale.notRunning' => ({required Object state}) => 'Tailscale is not connected (state: ${state}).',
			'tailscale.noPeers' => 'No other devices in this tailnet.',
			'tailscale.offline' => 'offline',
			'tailscale.search' => 'Search devices',
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
			'transfer.hostKeysTitle' => 'Host keys to confirm',
			'transfer.hostKeysBody' => 'The import holds host keys that would change which servers this device trusts. Trust a host\'s keys only if you know they are right; the others are not imported.',
			'transfer.trustedHere' => 'Trusted on this device',
			'transfer.nothingTrusted' => 'Nothing yet',
			'transfer.inImport' => 'In the import',
			'transfer.trustKeys' => 'Trust these keys',
			'transfer.keysTrusted' => 'Trusted',
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
			'settings.shortcutNewSession' => 'New session',
			'settings.shortcutTogglePause' => 'Pause or resume the session',
			'settings.shortcutPalette' => 'Command palette',
			'settings.shortcutSearchSessions' => 'Search sessions',
			'settings.shortcutAbort' => 'Stop the running turn',
			'settings.about' => 'About',
			'settings.aboutVersion' => ({required Object version, required Object build}) => 'Version ${version} (build ${build})',
			'settings.aboutClient' => 'A client for omp, the oh-my-pi coding agent',
			'settings.aboutPrivacy' => 'Privacy policy',
			'settings.aboutSource' => 'Source code',
			'settings.aboutIssues' => 'Report an issue',
			'settings.aboutLicense' => 'License',
			'settings.aboutLicenseValue' => 'GPL-3.0',
			'settings.aboutLicenses' => 'Open-source licenses',
			'time.now' => 'now',
			'time.minutes' => ({required Object n}) => '${n}m',
			'time.hours' => ({required Object n}) => '${n}h',
			'time.days' => ({required Object n}) => '${n}d',
			'sessions.offline' => 'Offline',
			'sessions.connecting' => 'Connecting…',
			'sessions.online' => ({required Object version}) => 'omp ${version}',
			'sessions.needsOmp' => ({required Object reason}) => 'omp needed: ${reason}',
			'sessions.connect' => 'Connect',
			'sessions.install' => 'Install omp',
			'sessions.refresh' => 'Refresh',
			'sessions.collapse' => 'Collapse',
			'sessions.expand' => 'Expand',
			'sessions.configure' => 'Configure',
			'sessions.newSession' => 'New session',
			'sessions.newSessionHere' => 'New session in this directory',
			'sessions.newSessionOn' => ({required Object machine}) => 'New session on ${machine}',
			'sessions.none' => 'No sessions yet.',
			'sessions.untitled' => 'New session',
			'sessions.unknownDirectory' => 'Unknown directory',
			'sessions.showMore' => ({required Object n}) => 'Show ${n} more',
			'sessions.working' => 'Working',
			'sessions.needsInput' => 'Needs your input',
			'sessions.failed' => 'The last run failed',
			'sessions.disconnected' => 'Disconnected',
			'sessions.runningOnMachine' => 'Open in omp on the machine',
			'sessions.opening' => 'Opening…',
			'sessions.unread' => 'Unread',
			'sessions.openFailed' => ({required Object error}) => 'Could not open the session: ${error}',
			'sessions.listFailed' => ({required Object error}) => 'Could not list sessions: ${error}',
			'sessions.directory' => 'Working directory',
			'sessions.directoryHint' => 'A path on the machine, e.g. ~/code/project',
			'sessions.directoryRequired' => 'Choose a working directory.',
			'sessions.notADirectory' => ({required Object path, required Object machine}) => '${path} is not a directory on ${machine}.',
			'sessions.recentDirectories' => 'Recent projects',
			'sessions.model' => 'Model (optional)',
			'sessions.modelDefault' => 'Default (from omp\'s settings)',
			'sessions.modelPick' => 'Choose a model',
			'sessions.modelUseDefault' => 'Use the model from omp\'s settings',
			'sessions.create' => 'Start',
			'sessions.browse' => 'Browse the machine',
			'sessions.browseTitle' => 'Choose a directory',
			'sessions.up' => 'Parent directory',
			'sessions.showHidden' => 'Show hidden directories',
			'sessions.chooseDirectory' => 'Use this directory',
			'sessions.external' => 'In omp on the machine',
			'install.title' => ({required Object machine}) => 'Install omp on ${machine}',
			'install.notConnected' => 'Connect to the machine first.',
			'install.viaDownload' => 'The machine downloads this release from GitHub and checks its SHA-256 before installing it.',
			'install.viaUpload' => 'The machine has neither curl nor wget: the app downloads the release here and uploads it, checking its SHA-256 on the machine.',
			'install.manual' => 'Run the script yourself',
			'install.install' => 'Install',
			'install.installing' => 'Downloading and installing on the machine…',
			'install.installFailed' => 'Installing on the machine failed',
			'install.downloading' => ({required Object asset}) => 'Downloading ${asset}…',
			'install.downloadFailed' => ({required Object status, required Object url}) => 'Download failed with HTTP ${status}: ${url}',
			'install.transferring' => ({required Object asset, required Object done, required Object total}) => 'Transferring ${asset}: ${done} of ${total} MB',
			'install.checking' => 'Checking the installation…',
			'install.stillMissing' => ({required Object reason}) => 'omp is still not usable: ${reason}',
			'install.noAsset' => ({required Object os, required Object arch}) => 'omp publishes no build for ${os} ${arch}.',
			'install.done' => ({required Object version}) => 'Installed omp ${version}.',
			'install.os' => 'OS',
			'install.arch' => 'Architecture',
			'install.release' => 'Release',
			'install.directory' => 'Installs into',
			'chat.noModel' => 'No model',
			'chat.searchModels' => 'Search models',
			'chat.refreshModels' => 'Reload the model list',
			'chat.noModels' => 'No models match.',
			'chat.modelsFailed' => ({required Object error}) => 'Could not load models: ${error}',
			'chat.modelFailed' => ({required Object error}) => 'Could not switch the model: ${error}',
			'chat.modelAgent' => ({required Object agent}) => 'Subagent ${agent}',
			'chat.contextWindow' => ({required Object tokens}) => '${tokens} context',
			_ => null,
		} ?? switch (path) {
			'chat.reasoning' => 'reasoning',
			'chat.thinking' => ({required Object level}) => 'Thinking: ${level}',
			'chat.noThinking' => 'This model has no thinking levels.',
			'chat.thinkingFailed' => ({required Object error}) => 'Could not change the thinking level: ${error}',
			'chat.contextTooltip' => ({required Object tokens, required Object window, required Object percent, required Object cost}) => 'Context: ${tokens} of ${window} tokens (${percent}%) · cost ${cost}',
			'chat.contextUnknown' => ({required Object cost}) => 'Context usage not known yet · cost ${cost}',
			'chat.pause' => 'Pause',
			'chat.resume' => 'Resume',
			'chat.pauseFailed' => ({required Object error}) => 'Could not pause or resume: ${error}',
			'chat.stop' => 'Stop',
			'chat.abortFailed' => ({required Object error}) => 'Could not stop the run: ${error}',
			'chat.noCompanion' => 'The companion is not loaded in this session, so pause, queue editing and shell or Python runs are unavailable.',
			'chat.more' => 'More',
			'chat.copyPath' => 'Copy session file path',
			'chat.detach' => 'Close on this device',
			'chat.stopSession' => 'Stop the omp process',
			'chat.stopSessionFailed' => ({required Object error}) => 'Could not stop the omp process: ${error}',
			'chat.reconnecting' => ({required Object attempt, required Object seconds}) => 'Connection lost. Reconnecting (attempt ${attempt}) in ${seconds} s.',
			'chat.retryNow' => 'Retry now',
			'chat.closed' => 'This session is closed.',
			'chat.exited' => ({required Object code}) => 'omp exited with code ${code}.',
			'chat.reopen' => 'Reopen',
			'chat.reopenFailed' => ({required Object error}) => 'Could not reopen the session: ${error}',
			'chat.parked' => 'Paused: the run waits before its next step',
			'chat.compacting' => 'Compacting the context…',
			'chat.retrying' => ({required Object attempt, required Object max, required Object error}) => 'Retrying (${attempt} of ${max}): ${error}',
			'chat.failed' => ({required Object error}) => 'The last run failed: ${error}',
			'chat.failedUnknown' => 'unknown error',
			'chat.aborted' => 'Stopped',
			'chat.closedState' => 'Closed',
			'chat.commandOutput' => 'Command output',
			'chat.extensionError' => ({required Object path, required Object event, required Object error}) => 'Extension error in ${path} (${event}): ${error}',
			'chat.fallbackServed' => ({required Object model}) => 'Served by the fallback model ${model}.',
			'chat.fallbackApplied' => ({required Object from, required Object to, required Object reason}) => 'Switched from ${from} to the fallback model ${to}. ${reason}',
			'chat.compactionCancelled' => 'Compaction was cancelled.',
			'chat.compactionFailed' => ({required Object error}) => 'Compaction failed: ${error}',
			'chat.rulesInterrupted' => ({required Object rules}) => 'Stream rules interrupted the response: ${rules}',
			'chat.cannotBranch' => 'Branching is only possible from your own messages.',
			'chat.branch' => 'Branch',
			'chat.branchTitle' => 'Branch from this message?',
			'chat.branchBody' => ({required Object text}) => 'A new session file starts before this message, and the message goes back into the composer:\n\n${text}',
			'chat.branchFailed' => ({required Object error}) => 'Could not branch: ${error}',
			'chat.resetKept' => 'Earlier replies are kept in the session tree.',
			'chat.openTree' => 'Open the tree',
			'chat.resetFailed' => ({required Object error}) => 'Could not reset: ${error}',
			'attachments.paste' => 'The large paste',
			'attachments.missing' => ({required Object name}) => '${name} is no longer on this device. Nothing was sent.',
			'attachments.tooLarge' => ({required Object name, required Object size, required Object limit}) => '${name} is ${size}; attachments can be at most ${limit}. Nothing was sent.',
			'attachments.folder' => ({required Object name}) => '${name} is a folder. Folders can be attached only to sessions on this computer. Nothing was sent.',
			'attachments.needsCompanion' => ({required Object name}) => '${name} needs the companion to reach the session\'s machine, and this session has none. Nothing was sent.',
			'attachments.uploadFailed' => ({required Object name, required Object error}) => '${name} could not be copied to the session\'s machine: ${error}. Nothing was sent.',
			'composer.hint' => 'Message omp',
			'composer.hintRunning' => 'Steer the running turn',
			'composer.send' => 'Send',
			'composer.steer' => 'Steer',
			'composer.followUp' => 'Follow-up',
			'composer.attach' => 'Attach files',
			'composer.remove' => 'Remove',
			'composer.pastedImage' => 'Pasted image',
			'composer.pastedText' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: 'Pasted text · ${n} line', other: 'Pasted text · ${n} lines', ), 
			'composer.pasteInline' => 'Paste inline',
			'composer.previewTruncated' => ({required Object shown, required Object total}) => 'Showing the first ${shown} of ${total} characters.',
			'composer.dropToAttach' => 'Drop to attach',
			'composer.dropNothing' => 'Only files and folders can be attached.',
			'composer.pasteFailed' => ({required Object error}) => 'Could not paste: ${error}',
			'composer.attachFailed' => ({required Object error}) => 'Could not attach: ${error}',
			'composer.uploading' => ({required Object sent, required Object total}) => 'Uploading ${sent} of ${total}',
			'composer.unknownCommand' => ({required Object name}) => '/${name} is not a command of this session. Nothing was sent.',
			'composer.sendFailed' => ({required Object error}) => 'Not sent: ${error}',
			'composer.externalRunning' => ({required Object machine}) => 'Running in omp on ${machine}',
			'composer.externalIdle' => ({required Object machine}) => 'Open in omp on ${machine}',
			'composer.externalTerminal' => ({required Object terminal}) => 'terminal ${terminal}',
			'composer.externalBody' => 'Another omp process is writing this session file. ompanion reads its transcript live, but sending is off: two writers would overwrite each other. Messages queued in that process are not visible here.',
			'composer.externalWait' => 'The other omp process still owns this session. Take it over once it has exited.',
			'composer.takeOver' => 'Take over',
			'composer.externalRunningNoMachine' => 'Running in omp',
			'composer.externalIdleNoMachine' => 'Open in omp',
			'composer.externalGone' => 'The other omp process has stopped',
			'composer.externalBodyGone' => 'The other omp process is gone. Take the session over to send messages from here.',
			'queue.steer' => 'Steering',
			'queue.followUp' => 'Follow-up',
			'queue.more' => ({required Object n}) => '+${n} more',
			'queue.edit' => 'Edit in the composer',
			'queue.remove' => 'Remove from the queue',
			'queue.takeFailed' => ({required Object error}) => 'Could not change the queue: ${error}',
			'exec.running' => 'running',
			'exec.exited' => ({required Object code}) => 'exit ${code}',
			'exec.cancelled' => 'cancelled',
			'exec.failed' => ({required Object error}) => 'failed: ${error}',
			'exec.abort' => 'Stop',
			'exec.truncated' => 'Output truncated',
			'requests.approvalTitle' => ({required Object tool}) => 'Allow ${tool}?',
			'requests.position' => ({required Object index, required Object count}) => '${index} of ${count}',
			'requests.previous' => 'Previous request',
			'requests.next' => 'Next request',
			'requests.submit' => 'Submit',
			'requests.yes' => 'Yes',
			'requests.no' => 'No',
			'requests.editorText' => 'Composer text',
			'requests.openUrlTitle' => 'Open in your browser',
			'requests.openInBrowser' => 'Open',
			'requests.forwarding' => ({required Object port}) => 'Forwarding localhost:${port} on this device to the machine for the login callback.',
			'requests.forwardFailed' => ({required Object error}) => 'Could not forward the login callback port: ${error}',
			'requests.answerFailed' => ({required Object error}) => 'Could not send the answer: ${error}',
			'requests.unsupportedTitle' => 'Unsupported request',
			'requests.unsupportedBody' => ({required Object method}) => 'The companion asked for "${method}", which this app version cannot show.',
			'requests.secondsLeft' => ({required Object n}) => '${n} s left',
			'requests.notWebLink' => 'Not an http or https link, so it does not open from here.',
			'ask.title' => 'Question',
			'ask.titleMany' => ({required Object n}) => '${n} questions',
			'ask.invalid' => ({required Object error}) => 'The question could not be read: ${error}',
			'ask.recommended' => 'Recommended',
			'ask.multi' => 'Choose any number.',
			'ask.otherHint' => 'Other: type your own answer',
			'ask.note' => 'Note (optional)',
			'ask.chat' => 'Chat about this',
			'transcript.jumpToLatest' => 'Jump to latest',
			'transcript.loadEarlier' => 'Load earlier messages',
			'transcript.messageActions' => 'Message actions',
			'transcript.branchFromHere' => 'Branch from here',
			'transcript.resetHere' => 'Reset to here',
			'transcript.resetRunning' => 'Wait for the turn to finish, or stop it, before resetting',
			'transcript.copyMessage' => 'Copy message',
			'transcript.copyCode' => 'Copy code',
			'transcript.copyOutput' => 'Copy output',
			'transcript.fromAgent' => 'Sent by the agent',
			'transcript.automatic' => 'Automatic message',
			'transcript.waiting' => 'Waiting for a reply',
			'transcript.waitingElapsed' => ({required Object seconds}) => 'Waiting for a reply · ${seconds}s',
			'transcript.thinking' => 'Thinking…',
			'transcript.thought' => 'Thought',
			'transcript.thoughtFor' => ({required Object duration}) => 'Thought for ${duration}',
			'transcript.reasoningTokens' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} reasoning token', other: '${n} reasoning tokens', ), 
			'transcript.redactedThinking' => 'Reasoning hidden by the provider',
			'transcript.interrupted' => 'Interrupted',
			'transcript.failed' => 'The response failed.',
			'transcript.lengthLimit' => 'Stopped at the output token limit.',
			'transcript.retryRecovered' => ({required Object attempt}) => 'This attempt failed; retry ${attempt} succeeded.',
			'transcript.retrySuperseded' => ({required Object attempt}) => 'This attempt failed; retrying gave up after attempt ${attempt}.',
			'transcript.retryFailed' => ({required Object attempt}) => 'This attempt failed; retry ${attempt} failed too.',
			'transcript.tokensIn' => ({required Object count}) => '${count} in',
			'transcript.tokensOut' => ({required Object count}) => '${count} out',
			'transcript.tokensCached' => ({required Object count}) => '${count} cached',
			'transcript.seconds' => ({required Object value}) => '${value} s',
			'transcript.image' => 'Image',
			'transcript.loadImage' => 'Load image',
			'transcript.imageLoading' => ({required Object name}) => 'Loading ${name}…',
			'transcript.imageMissing' => ({required Object path}) => 'Image not found: ${path}',
			'transcript.imageNotFile' => ({required Object path}) => 'Not a file: ${path}',
			'transcript.imageDenied' => ({required Object path}) => 'No permission to read ${path}',
			'transcript.imageNotImage' => ({required Object path}) => 'Not an image: ${path}',
			'transcript.imageUnsupported' => ({required Object path, required Object size}) => '${path} (${size}) is in a format this app cannot show',
			'transcript.imageTooLarge' => ({required Object path, required Object size}) => '${path} (${size}) is too large to load on its own',
			'transcript.imageFailed' => ({required Object path, required Object error}) => 'Could not load ${path}: ${error}',
			'transcript.loadOriginal' => ({required Object size}) => 'Load original (${size})',
			'transcript.retryImage' => 'Retry',
			'transcript.imagePreview' => ({required Object sent, required Object size}) => 'preview, ${sent} of ${size}',
			'transcript.openInFiles' => 'Open in Files',
			'transcript.showMoreLines' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: 'Show ${n} more line', other: 'Show ${n} more lines', ), 
			'transcript.showLess' => 'Show less',
			'transcript.tool.running' => 'Running…',
			'transcript.tool.background' => 'Running in the background',
			'transcript.tool.interrupted' => 'Did not finish',
			'transcript.tool.error' => 'Error',
			'transcript.tool.arguments' => 'Arguments',
			'transcript.tool.noOutput' => 'No output',
			'transcript.tool.exitCode' => ({required Object code}) => 'Exit ${code}',
			'transcript.tool.timedOut' => 'Timed out',
			'transcript.tool.lines' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} line', other: '${n} lines', ), 
			'transcript.tool.lineRange' => ({required Object from, required Object to}) => 'lines ${from}–${to}',
			'transcript.tool.openFile' => 'Open file',
			'transcript.tool.created' => 'Created',
			'transcript.tool.deleted' => 'Deleted',
			'transcript.tool.movedTo' => ({required Object path}) => 'Moved to ${path}',
			'transcript.tool.noChanges' => 'No changes',
			'transcript.tool.todoProgress' => ({required Object done, required Object total}) => '${done} of ${total} done',
			'transcript.tool.agents' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} agent', other: '${n} agents', ), 
			'transcript.tool.openAgent' => 'Open agent',
			'transcript.tool.agentPending' => 'Pending',
			'transcript.tool.agentRunning' => 'Running',
			'transcript.tool.agentCompleted' => 'Done',
			'transcript.tool.agentFailed' => 'Failed',
			'transcript.tool.agentAborted' => 'Aborted',
			'transcript.tool.askWaiting' => 'Waiting for your answer below',
			'transcript.tool.recommended' => 'Recommended',
			'transcript.tool.cancelled' => 'Cancelled',
			'transcript.tool.note' => ({required Object note}) => 'Note: ${note}',
			'transcript.tool.autoSelected' => 'Chosen automatically after the timeout',
			'transcript.tool.sources' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} source', other: '${n} sources', ), 
			'transcript.tool.output' => 'Output',
			'transcript.tool.context' => 'Context',
			'transcript.tool.diagnostics' => 'Diagnostics',
			'transcript.tool.redirectedTo' => ({required Object url}) => 'Redirected to ${url}',
			'transcript.tool.tokens' => ({required Object count}) => '${count} tokens',
			'transcript.execution.notSent' => 'Not sent to the model',
			'transcript.execution.cancelled' => 'Cancelled',
			'transcript.execution.truncated' => 'Output truncated',
			'transcript.compacted' => 'Context compacted',
			'transcript.compactedTokens' => ({required Object before, required Object after}) => '${before} → ${after} tokens',
			'transcript.compactedFrom' => ({required Object before}) => 'from ${before} tokens',
			'transcript.showSummary' => 'Show summary',
			'transcript.hideSummary' => 'Hide summary',
			'transcript.showAll' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: 'Show all (${n} line)', other: 'Show all (${n} lines)', ), 
			'transcript.branchSummary' => 'Summary of the branch you left',
			'transcript.summaryFiles' => 'Files',
			'transcript.fileRead' => 'read',
			'transcript.fileWritten' => 'written',
			'transcript.fileReadWritten' => 'read and written',
			'transcript.filesElided' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} more file', other: '${n} more files', ), 
			'transcript.modelChange' => ({required Object model}) => 'Model: ${model}',
			'transcript.modelRoleChange' => ({required Object role, required Object model}) => 'Model (${role}): ${model}',
			'transcript.thinkingLevel' => ({required Object level}) => 'Thinking: ${level}',
			'transcript.thinkingOff' => 'Thinking: off',
			'transcript.mentionedFiles' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: 'Attached ${n} file', other: 'Attached ${n} files', ), 
			'transcript.skippedTooLarge' => 'too large',
			'transcript.skippedBinary' => 'binary',
			'transcript.backgroundResult' => 'Background result',
			'transcript.delegated' => 'Delegated request',
			'transcript.turn.workedFor' => ({required Object duration}) => 'Worked for ${duration}',
			'transcript.turn.worked' => 'Worked',
			'transcript.turn.toolCalls' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} tool call', other: '${n} tool calls', ), 
			'transcript.turn.filesEdited' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(n, one: '${n} file edited', other: '${n} files edited', ), 
			'transcript.turn.durationHours' => ({required Object hours, required Object minutes}) => '${hours}h ${minutes}m',
			'transcript.turn.durationMinutes' => ({required Object minutes, required Object seconds}) => '${minutes}m ${seconds}s',
			'transcript.turn.durationSeconds' => ({required Object seconds}) => '${seconds}s',
			'config.title' => ({required Object machine}) => 'Configure ${machine}',
			'config.connect' => 'Connect',
			'config.connecting' => 'Connecting…',
			'config.needsOmp' => ({required Object reason}) => 'omp needs an install or an upgrade on this machine: ${reason}',
			'config.refresh' => 'Refresh',
			'config.noOutput' => '(no output)',
			'config.sections.settings' => 'Settings',
			'config.sections.roles' => 'Model roles',
			'config.sections.accounts' => 'Providers',
			'config.sections.mcp' => 'MCP servers',
			'config.sections.plugins' => 'Plugins',
			'config.sections.skills' => 'Skills',
			'config.sections.stats' => 'Stats',
			'config.scope.global' => 'Global',
			'config.scope.project' => 'Project',
			'config.scope.projectNone' => 'Open a session on this machine to edit its project settings.',
			'config.provenance.env' => ({required Object name}) => 'env ${name}',
			'config.provenance.envHint' => ({required Object name}) => 'The environment variable ${name} overrides the files.',
			'config.provenance.runtime' => 'override',
			'config.provenance.runtimeHint' => 'Set for this omp process only (RPC mode or a runtime override); the app\'s sessions use it.',
			'config.provenance.overlay' => 'app overlay',
			'config.provenance.overlayHint' => 'Forced by the app\'s per-session config overlay.',
			'config.provenance.project' => 'project',
			'config.provenance.projectHint' => 'From the project\'s .omp/config.yml.',
			'config.provenance.global' => 'global',
			'config.provenance.globalHint' => 'From the profile\'s config.yml.',
			'config.provenance.defaults' => 'default',
			'config.provenance.defaultsHint' => 'omp\'s default; no file sets it.',
			'config.settings.search' => 'Search settings',
			'config.settings.editing' => ({required Object path}) => 'Editing ${path}',
			'config.settings.advancedTab' => 'Config file only',
			'config.settings.advancedNote' => 'Settings without a row in omp\'s settings panel, grouped by their first key.',
			'config.settings.themeNote' => 'These are omp\'s terminal UI settings. The app\'s own look follows the app settings.',
			'config.settings.noMatches' => 'No setting matches.',
			'config.settings.reset' => 'Reset to the inherited value',
			'config.settings.unset' => 'unset',
			'config.settings.presets' => 'Suggested values',
			'config.settings.notANumber' => 'Not a number',
			'config.settings.notJson' => ({required Object error}) => 'Not JSON: ${error}',
			'config.settings.expectedObject' => 'Expected a JSON object',
			'config.settings.expectedArray' => 'Expected a JSON array',
			'config.settings.secretSet' => 'Configured',
			'config.settings.secretUnset' => 'Not set',
			'config.settings.secretEdit' => 'Set…',
			'config.settings.secretHelp' => 'Sent to the machine as a private file that omp reads and deletes; never shown or logged.',
			'config.settings.secretGlobalOnly' => 'Credentials are saved in the global config only.',
			'config.settings.addItem' => 'Add',
			'config.settings.overriddenLine' => ({required Object value}) => 'In effect: ${value} (a higher layer wins)',
			'config.settings.fileError' => ({required Object path, required Object error}) => 'Could not read ${path}: ${error}',
			'config.roles.storage' => ({required Object storage}) => 'omp\'s model picker saves roles to: ${storage}',
			'config.roles.projectIs' => ({required Object path}) => 'Project: ${path}',
			'config.roles.noProject' => 'Open a session on this machine to assign project roles.',
			'config.roles.refreshModels' => 'Refresh models',
			'config.roles.modelsRefreshed' => 'Model list refreshed.',
			'config.roles.chatRoles' => 'Chat roles',
			'config.roles.kindRoles' => 'Task kinds',
			'config.roles.effective' => 'In effect',
			'config.roles.projectLayer' => 'Project',
			'config.roles.auto' => 'auto',
			'config.roles.assign' => 'Set',
			'config.roles.clear' => 'Clear',
			'config.roles.pickTitle' => ({required Object role}) => 'Model for ${role}',
			'config.roles.searchModels' => 'Search models',
			'config.roles.thinking' => 'Thinking level',
			'config.roles.thinkingDefault' => 'model default',
			'config.roles.useTyped' => ({required Object selector}) => 'Use ${selector}',
			'config.roles.useTypedHint' => 'A model omp does not list as available here',
			'config.roles.context' => ({required Object tokens}) => '${tokens} context',
			'config.roles.vision' => 'images',
			'config.roles.noModels' => 'No model matches.',
			'config.accounts.machineWide' => 'Credentials are stored per machine.',
			'config.accounts.sessionView' => ({required Object path}) => 'In use and pinned marks refer to the session in ${path}.',
			'config.accounts.active' => 'in use',
			'config.accounts.sticky' => 'pinned',
			'config.accounts.expires' => ({required Object date}) => 'expires ${date}',
			'config.accounts.pin' => 'Pin to session',
			'config.accounts.pinned' => 'Account pinned to the session.',
			'config.accounts.logout' => 'Log out',
			'config.accounts.logoutTitle' => ({required Object account}) => 'Log out ${account}?',
			'config.accounts.logoutBody' => ({required Object provider}) => 'The stored credential for ${provider} is removed from this machine.',
			'config.accounts.oauthLocal' => 'The browser opens on this computer.',
			'config.accounts.oauthRemote' => 'The browser opens on this device; the app forwards omp\'s callback port to the machine.',
			'config.accounts.saveKey' => 'Save key',
			'config.accounts.keyStored' => ({required Object provider}) => 'Key stored for ${provider}.',
			'config.accounts.loginTitle' => ({required Object provider}) => 'Log in to ${provider}',
			'config.accounts.waitingForLink' => 'Waiting for omp\'s authorization link…',
			'config.accounts.openLink' => 'Open this link and sign in:',
			'config.accounts.openBrowser' => 'Open browser',
			'config.accounts.copyLink' => 'Copy link',
			'config.accounts.forwarding' => ({required Object ports}) => 'Forwarding local port ${ports} to the machine for the callback.',
			'config.accounts.forwardFailed' => ({required Object port, required Object error}) => 'Could not forward port ${port} (${error}). Paste the redirect URL when omp asks for it.',
			'config.accounts.submit' => 'Submit',
			'config.accounts.yes' => 'Yes',
			'config.accounts.no' => 'No',
			'config.accounts.loggedIn' => 'Logged in.',
			'config.accounts.bootstrap' => 'No model works on this machine yet. Sign in with an account or add an API key; settings and roles work meanwhile.',
			'config.accounts.search' => 'Search providers',
			'config.accounts.noMatches' => 'No provider matches.',
			'config.accounts.signedIn' => 'signed in',
			'config.accounts.signIn' => 'Sign in',
			'config.accounts.keyHint' => 'Paste an API key',
			'config.accounts.other' => 'Other provider…',
			'config.accounts.otherId' => 'Provider id',
			'config.accounts.otherNote' => 'Stores a key under a provider id this list does not show, as models.yml or an extension names it.',
			'config.accounts.kind.account' => 'account',
			'config.accounts.kind.apiKey' => 'API key',
			'config.accounts.kind.local' => 'local',
			'config.accounts.source.runtime' => 'omp uses a key set for this omp process only.',
			'config.accounts.source.config' => 'omp uses the key that models.yml sets.',
			'config.accounts.source.oauth' => 'omp uses a signed-in account.',
			'config.accounts.source.apiKey' => 'omp uses a stored API key.',
			'config.accounts.source.env' => ({required Object name}) => 'omp uses the key in the environment variable ${name}.',
			'config.accounts.source.working' => 'omp has a working credential for this provider.',
			'config.accounts.source.none' => 'Not signed in.',
			'config.accounts.source.noKey' => 'No key stored.',
			'config.accounts.overridden.config' => 'models.yml sets a key for this provider, so omp uses that key and not the stored one.',
			'config.accounts.overridden.env' => ({required Object name}) => 'The environment variable ${name} sets a key, so omp uses it and not the stored one.',
			'config.accounts.overridden.runtime' => 'A key set for this omp process wins over the stored one.',
			'config.mcp.userFile' => ({required Object path}) => 'User: ${path}',
			'config.mcp.projectFile' => ({required Object path}) => 'Project: ${path}',
			'config.mcp.add' => 'Add server',
			'config.mcp.addTitle' => 'Add MCP server',
			'config.mcp.reload' => 'Reload',
			'config.mcp.resources' => 'Resources',
			'config.mcp.prompts' => 'Prompts',
			'config.mcp.smithery' => 'Search Smithery',
			'config.mcp.none' => 'No MCP servers configured.',
			'config.mcp.userScope' => 'user',
			'config.mcp.projectScope' => 'project',
			'config.mcp.test' => 'Test',
			'config.mcp.removeTitle' => ({required Object name}) => 'Remove ${name}?',
			'config.mcp.removeBody' => ({required Object scope}) => 'The server is removed from the ${scope} mcp.json.',
			'config.mcp.name' => 'Name',
			'config.mcp.nameTooLong' => 'At most 100 characters',
			'config.mcp.nameInvalid' => 'Only letters, digits, - _ . : and single spaces',
			'config.mcp.command' => 'Command',
			'config.mcp.url' => 'URL',
			'config.mcp.token' => 'Bearer token (optional)',
			'config.mcp.tokenHint' => 'Written into the user mcp.json as an Authorization header.',
			'config.mcp.tokenUserOnly' => 'Only user-scope servers take a token here: a project session would keep it in its run log.',
			'config.mcp.tuiOnly' => 'omp 18.3.1 offers reauth, unauth, reconnect and Smithery login only in its terminal UI.',
			'config.mcp.testDisabled' => 'Enable the server to test it; omp loads only enabled servers.',
			'config.mcp.smitheryTitle' => 'Smithery registry',
			'config.plugins.inProject' => ({required Object path}) => 'Commands run in ${path}',
			'config.plugins.installed' => 'Installed',
			'config.plugins.none' => 'No plugins installed.',
			'config.plugins.npm' => 'npm',
			'config.plugins.uninstall' => 'Uninstall',
			'config.plugins.upgrade' => 'Upgrade',
			'config.plugins.update' => 'Update',
			'config.plugins.marketplaceScope' => ({required Object scope}) => 'marketplace · ${scope}',
			'config.plugins.shadowed' => 'shadowed',
			'config.plugins.install' => 'Install',
			'config.plugins.installHint' => 'An npm package, name@marketplace, github:user/repo, a git URL or a local path. npm installs need bun on the machine.',
			'config.plugins.installPlaceholder' => '@oh-my-pi/exa',
			'config.plugins.installAction' => 'Install',
			'config.plugins.marketplaces' => 'Marketplaces',
			'config.plugins.updateAll' => 'Update all',
			'config.plugins.noMarketplaces' => 'No marketplaces configured.',
			'config.plugins.isInstalled' => 'installed',
			'config.plugins.sourcePlaceholder' => 'owner/repo, git URL or local path',
			'config.plugins.addMarketplace' => 'Add marketplace',
			'config.skills.registry' => 'Registry skills from skills.omp.sh',
			'config.skills.installed' => 'Installed',
			'config.skills.none' => 'No registry skills installed.',
			'config.skills.notInstalled' => 'not installed',
			'config.skills.range' => ({required Object range}) => 'range ${range}',
			'config.skills.info' => 'Info',
			'config.skills.search' => 'Search the registry',
			'config.skills.searchHint' => 'pdf, git, review…',
			'config.skills.results' => ({required Object shown, required Object total}) => '${shown} of ${total}',
			'config.skills.downloads' => ({required Object number}) => '${number} weekly downloads',
			'config.skills.by' => ({required Object name}) => 'by ${name}',
			'config.skills.deprecated' => ({required Object reason}) => 'Deprecated: ${reason}',
			'config.skills.installWhere' => ({required Object id}) => 'Install ${id} for',
			'config.skills.forUser' => 'Every project (user)',
			'config.skills.forProject' => ({required Object path}) => 'This project (${path})',
			'config.skills.scriptsTitle' => 'This skill ships scripts',
			'config.skills.scriptsBody' => 'Installing it runs its scripts on the machine. Install anyway?',
			'config.skills.installAnyway' => 'Install anyway',
			'config.skills.license' => ({required Object license}) => 'License: ${license}',
			'config.skills.latest' => ({required Object version}) => 'Latest: ${version}',
			'config.skills.versions' => ({required Object versions}) => 'Versions: ${versions}',
			'config.skills.owners' => ({required Object owners}) => 'Owners: ${owners}',
			'config.skills.downloadsTotal' => ({required Object weekly, required Object total}) => 'Downloads: ${weekly} weekly, ${total} total',
			'config.skills.shipsScripts' => 'Ships scripts.',
			'config.skills.noHits' => ({required Object query}) => 'Nothing on skills.omp.sh matches "${query}".',
			'config.stats.span' => ({required Object from, required Object to}) => '${from} – ${to}',
			'config.stats.none' => 'No requests recorded yet.',
			'config.stats.requests' => 'Requests',
			'config.stats.errors' => 'Errors',
			'config.stats.inputTokens' => 'Input tokens',
			'config.stats.outputTokens' => 'Output tokens',
			'config.stats.cacheRead' => 'Cache read',
			'config.stats.cost' => 'Cost',
			'config.stats.ttft' => 'Avg. first token',
			'config.stats.speed' => 'Avg. speed',
			'config.stats.perHour' => 'Requests per hour',
			'config.stats.byModel' => 'By model',
			'config.stats.byFolder' => 'By project',
			'config.stats.byAgent' => 'By agent',
			'config.stats.model' => 'Model',
			'config.stats.folder' => 'Project',
			'config.stats.agent' => 'Agent',
			_ => null,
		};
	}
}
