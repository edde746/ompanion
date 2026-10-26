///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:slang/generated.dart';
import 'strings.g.dart';

// Path: <root>
class TranslationsDe extends Translations with BaseTranslations<AppLocale, Translations> {
	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	TranslationsDe({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  _meta = meta ?? TranslationMetadata(
		    locale: AppLocale.de,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ),
		  super(cardinalResolver: cardinalResolver, ordinalResolver: ordinalResolver) {
		_meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <de>.
	final TranslationMetadata<AppLocale, Translations> _meta;
	@override TranslationMetadata<AppLocale, Translations> get $meta => _meta;

	/// Access flat map
	@override dynamic operator[](String key) => _meta.getTranslation(key) ?? super[key];

	late final TranslationsDe _root = this; // ignore: unused_field

	@override 
	TranslationsDe $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => TranslationsDe(meta: meta ?? this.$meta);

	// Translations
	@override late final _Translations$app$de app = _Translations$app$de._(_root);
	@override late final _Translations$common$de common = _Translations$common$de._(_root);
	@override late final _Translations$shell$de shell = _Translations$shell$de._(_root);
	@override late final _Translations$usage$de usage = _Translations$usage$de._(_root);
	@override late final _Translations$dock$de dock = _Translations$dock$de._(_root);
	@override late final _Translations$sidebar$de sidebar = _Translations$sidebar$de._(_root);
	@override late final _Translations$machines$de machines = _Translations$machines$de._(_root);
	@override late final _Translations$auth$de auth = _Translations$auth$de._(_root);
	@override late final _Translations$editor$de editor = _Translations$editor$de._(_root);
	@override late final _Translations$keys$de keys = _Translations$keys$de._(_root);
	@override late final _Translations$hostKey$de hostKey = _Translations$hostKey$de._(_root);
	@override late final _Translations$links$de links = _Translations$links$de._(_root);
	@override late final _Translations$prompt$de prompt = _Translations$prompt$de._(_root);
	@override late final _Translations$connectError$de connectError = _Translations$connectError$de._(_root);
	@override late final _Translations$tailscale$de tailscale = _Translations$tailscale$de._(_root);
	@override late final _Translations$sshConfig$de sshConfig = _Translations$sshConfig$de._(_root);
	@override late final _Translations$transfer$de transfer = _Translations$transfer$de._(_root);
	@override late final _Translations$settings$de settings = _Translations$settings$de._(_root);
	@override late final _Translations$themeEditor$de themeEditor = _Translations$themeEditor$de._(_root);
	@override late final _Translations$notifications$de notifications = _Translations$notifications$de._(_root);
	@override late final _Translations$time$de time = _Translations$time$de._(_root);
	@override late final _Translations$units$de units = _Translations$units$de._(_root);
	@override late final _Translations$sessions$de sessions = _Translations$sessions$de._(_root);
	@override late final _Translations$install$de install = _Translations$install$de._(_root);
	@override late final _Translations$chat$de chat = _Translations$chat$de._(_root);
	@override late final _Translations$attachments$de attachments = _Translations$attachments$de._(_root);
	@override late final _Translations$composer$de composer = _Translations$composer$de._(_root);
	@override late final _Translations$queue$de queue = _Translations$queue$de._(_root);
	@override late final _Translations$goal$de goal = _Translations$goal$de._(_root);
	@override late final _Translations$loop$de loop = _Translations$loop$de._(_root);
	@override late final _Translations$exec$de exec = _Translations$exec$de._(_root);
	@override late final _Translations$requests$de requests = _Translations$requests$de._(_root);
	@override late final _Translations$ask$de ask = _Translations$ask$de._(_root);
	@override late final _Translations$transcript$de transcript = _Translations$transcript$de._(_root);
	@override late final _Translations$config$de config = _Translations$config$de._(_root);
}

// Path: app
class _Translations$app$de extends Translations$app$en {
	_Translations$app$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'ompanion';
}

// Path: common
class _Translations$common$de extends Translations$common$en {
	_Translations$common$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get cancel => 'Abbrechen';
	@override String get close => 'Schließen';
	@override String get save => 'Speichern';
	@override String get delete => 'Löschen';
	@override String get edit => 'Bearbeiten';
	@override String get retry => 'Wiederholen';
	@override String get copy => 'Kopieren';
	@override String get copied => 'Kopiert';
	@override String get continueAction => 'Fortsetzen';
	@override String get required => 'Erforderlich';
	@override String get chooseFile => 'Datei wählen…';
	@override String get cancelled => 'Abgebrochen.';
}

// Path: shell
class _Translations$shell$de extends Translations$shell$en {
	_Translations$shell$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get showSidebar => 'Seitenleiste einblenden';
	@override String get hideSidebar => 'Seitenleiste ausblenden';
	@override String get showPanels => 'Panels einblenden';
	@override String get hidePanels => 'Panels ausblenden';
	@override String get panels => 'Panels';
	@override String get homeTitle => 'Kein Rechner ausgewählt';
	@override String get homeBody => 'Wähle in der Seitenleiste einen Rechner aus oder füge einen hinzu.';
	@override String get keysTitle => 'SSH-Schlüssel';
	@override String get usageTitle => 'Nutzung';
	@override String get settingsTitle => 'Einstellungen';
}

// Path: usage
class _Translations$usage$de extends Translations$usage$en {
	_Translations$usage$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get fetchAgain => 'Anbieter erneut abfragen';
	@override String fetched({required Object ago}) => 'Vor ${ago} abgerufen';
	@override String get notFetched => 'Noch nicht abgerufen';
	@override String get hideIdentities => 'E-Mails und Organisationen ausblenden';
	@override String get showIdentities => 'E-Mails und Organisationen anzeigen';
	@override String get none => 'Keine Nutzungsdaten. Konten von Anbietern mit Nutzungs-Endpunkt (zum Beispiel Claude- und ChatGPT-Abos) zeigen hier ihre Limits.';
	@override String get noMachines => 'Noch keine Rechner. Füge einen in der Seitenleiste hinzu.';
	@override String get machines => 'Rechner';
	@override String get asking => 'omp wird abgefragt…';
	@override String machineAccounts({required num n, required Object version}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'omp ${version} · ${n} Konto',
		other: 'omp ${version} · ${n} Konten',
	);
	@override String providerAccounts({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Konto',
		other: '${n} Konten',
	);
	@override String accountN({required Object n}) => 'Konto ${n}';
	@override String get apiKey => 'API-Schlüssel';
	@override String get oauthAccount => 'OAuth-Konto';
	@override String plan({required Object plan}) => 'Tarif: ${plan}';
	@override String get daybreak => 'Daybreak';
	@override String savedResets({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} gespeicherter Reset',
		other: '${n} gespeicherte Resets',
	);
	@override String usableNow({required Object n}) => '${n} jetzt nutzbar';
	@override String resetExpiresIn({required Object duration, required Object date}) => 'nächster Ablauf in ${duration} (${date})';
	@override String resetExpired({required Object date}) => 'abgelaufen (${date})';
	@override String resetUnavailable({required Object reason}) => 'nicht verfügbar: ${reason}';
	@override String resetCooldown({required Object time}) => 'Abklingzeit bis ${time}';
	@override String resetBlocked({required Object windows}) => 'blockiert durch ${windows}';
	@override String get resetNotEligible => 'nicht berechtigt';
	@override String get resetNotUsable => 'derzeit nicht nutzbar';
	@override String fetchedAgo({required Object ago}) => 'vor ${ago} abgerufen';
	@override String policy({required Object priority, required Object reserve}) => 'Richtlinie: Priorität ${priority} · Reserve ${reserve}';
	@override String reserveGlobal({required Object percent}) => '${percent} % (global)';
	@override String reserveOverride({required Object percent}) => '${percent} % (Override)';
	@override String get reserveUnknown => 'Reserve unbekannt';
	@override String get eligible => 'berechtigt';
	@override String get insideReserve => 'innerhalb der Reserve';
	@override String get exhausted => 'ausgeschöpft';
	@override String policyOn({required Object line, required Object machine}) => '${line} (${machine})';
	@override String get noLimits => 'keine Limits gemeldet';
	@override String get notReported => 'nicht gemeldet';
	@override String get noData => 'keine Daten';
	@override String amountOf({required Object used, required Object limit}) => '${used} / ${limit}';
	@override String amountLeft({required Object amount}) => '${amount} übrig';
	@override String amountUsed({required Object amount}) => '${amount} verbraucht';
	@override String percentUsed({required Object percent}) => '${percent} % verbraucht';
	@override String percentLeft({required Object percent}) => '${percent} % übrig';
	@override String get resets => 'Reset';
	@override String resetsIn({required Object verb, required Object duration}) => '${verb} in ${duration}';
	@override late final _Translations$usage$units$de units = _Translations$usage$units$de._(_root);
	@override String get withoutUsage => 'keine Nutzungsdaten';
	@override String disabledAgo({required Object ago, required Object cause}) => 'vor ${ago} deaktiviert: ${cause}';
	@override String disabled({required Object cause}) => 'deaktiviert: ${cause}';
	@override String get reloginToRestore => '(erneut anmelden, um wiederherzustellen)';
	@override String reloginWithin({required Object duration}) => 'innerhalb von ${duration} erneut anmelden (Anthropic lässt OAuth-Grants ~30 Tage nach der Anmeldung ablaufen)';
	@override String get reloginNow => 'Grant ist älter als die ~30 Tage von Anthropic; melde dich jetzt neu an';
	@override String get capacity => 'Kapazität';
	@override String capacityWindow({required num n, required Object used, required Object left}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${used}/${n} Konto genutzt · ${left}× Kontingent übrig',
		other: '${used}/${n} Konten genutzt · ${left}× Kontingent übrig',
	);
	@override late final _Translations$usage$tabs$de tabs = _Translations$usage$tabs$de._(_root);
	@override late final _Translations$usage$stats$de stats = _Translations$usage$stats$de._(_root);
}

// Path: dock
class _Translations$dock$de extends Translations$dock$en {
	_Translations$dock$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get agents => 'Agenten';
	@override String get todos => 'Aufgaben';
	@override String get tree => 'Baum';
	@override String get files => 'Dateien';
	@override String get terminal => 'Terminal';
	@override String get noSession => 'Öffne eine Sitzung, um dieses Panel zu nutzen.';
	@override String get noMachine => 'Öffne eine Sitzung oder wähle einen Rechner, um dieses Panel zu nutzen.';
	@override late final _Translations$dock$todo$de todo = _Translations$dock$todo$de._(_root);
	@override late final _Translations$dock$hub$de hub = _Translations$dock$hub$de._(_root);
	@override late final _Translations$dock$sessionTree$de sessionTree = _Translations$dock$sessionTree$de._(_root);
	@override late final _Translations$dock$fileBrowser$de fileBrowser = _Translations$dock$fileBrowser$de._(_root);
	@override late final _Translations$dock$terminals$de terminals = _Translations$dock$terminals$de._(_root);
}

// Path: sidebar
class _Translations$sidebar$de extends Translations$sidebar$en {
	_Translations$sidebar$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get addMachine => 'Rechner hinzufügen';
	@override String get more => 'Mehr';
	@override String get importMachines => 'Rechner importieren…';
	@override String get exportMachines => 'Rechner exportieren…';
	@override String get keys => 'SSH-Schlüssel';
	@override String get usage => 'Nutzung';
	@override String get settings => 'Einstellungen';
	@override String get noMachines => 'Noch keine Rechner.';
	@override String get search => 'Sitzungen durchsuchen';
	@override String get searchHint => 'Suchen';
	@override String get noMatches => 'Keine passenden Sitzungen.';
	@override String get pinned => 'Angeheftet';
}

// Path: machines
class _Translations$machines$de extends Translations$machines$en {
	_Translations$machines$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get thisComputer => 'Dieser Computer';
	@override String get tailscale => 'Tailscale';
	@override String get route => 'Route';
	@override String get target => 'Rechner';
	@override String sshConfigAlias({required Object alias}) => 'Aus SSH-Config-Alias ${alias}';
	@override String deleteTitle({required Object name}) => '${name} löschen?';
	@override String get deleteBody => 'Gespeicherte Passwörter dieses Rechners werden ebenfalls gelöscht. Schlüssel und vertrauenswürdige Hostschlüssel bleiben.';
	@override String get testConnection => 'Verbindung testen';
	@override String get connecting => 'Verbinden…';
	@override String connectedIn({required Object ms}) => 'Verbunden in ${ms} ms.';
	@override String failed({required Object error}) => 'Fehlgeschlagen: ${error}';
	@override String get updateOmp => 'omp aktualisieren';
	@override String get updatingOmp => 'omp update läuft auf dem Rechner…';
	@override String ompUpdated({required Object from, required Object to}) => 'omp von ${from} auf ${to} aktualisiert. Laufende Sitzungen behalten ${from}, bis ihr omp endet.';
	@override String get hostKeys => 'Vertrauenswürdige Hostschlüssel';
	@override String get noHostKeys => 'Noch kein Hostschlüssel als vertrauenswürdig markiert. Die erste Verbindung fragt nach.';
	@override String get forgetHostKey => 'Diesen Hostschlüssel vergessen';
	@override String get noKeySelected => 'kein Schlüssel ausgewählt';
	@override String get facts => 'System';
	@override String get status => 'Status';
	@override String get os => 'OS';
	@override String get arch => 'Architektur';
	@override String get shell => 'Shell';
	@override String get loginPath => 'Login-PATH';
	@override String get home => 'Home';
	@override String get omp => 'omp';
	@override String get ompVersion => 'omp-Version';
	@override String get companion => 'Companion';
	@override String get companionReady => 'Hochgeladen';
	@override String get companionMissing => 'Nicht hochgeladen';
	@override String get notFound => 'Nicht gefunden';
	@override String get notProbed => 'Verbinde dich, um OS, Shell und omp des Rechners zu lesen.';
	@override String get power => 'Energie';
	@override String get keepAwake => 'Diesen Mac wach halten, während omp arbeitet';
	@override String get keepAwakeDetail => 'Während omp in einer Sitzung aus ompanion arbeitet, schläft der Mac nicht – auch nicht direkt nach dem Aufwecken durch eine Anfrage. Nur am Strom; das Display schaltet sich weiterhin ab. Jedes Gerät sieht diesen Schalter.';
}

// Path: auth
class _Translations$auth$de extends Translations$auth$en {
	_Translations$auth$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get key => 'Schlüssel';
	@override String get password => 'Passwort';
	@override String get agent => 'SSH-Konfiguration und Agent (wie ssh)';
	@override String get none => 'Keine (Tailscale SSH)';
	@override String get keyboardInteractive => 'Tastatur-interaktiv';
}

// Path: editor
class _Translations$editor$de extends Translations$editor$en {
	_Translations$editor$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get addTitle => 'Rechner hinzufügen';
	@override String get editTitle => 'Rechner bearbeiten';
	@override String get kind => 'Art';
	@override String get kindSsh => 'SSH';
	@override String get name => 'Name';
	@override String get host => 'Host';
	@override String get hostHelper => 'Hostname, IP-Adresse, MagicDNS-Name oder 100.x-Adresse';
	@override String get port => 'Port';
	@override String get invalidPort => 'Zwischen 1 und 65535';
	@override String get user => 'Benutzer';
	@override String get auth => 'Authentifizierung';
	@override String get key => 'Schlüssel';
	@override String get chooseKey => 'Schlüssel wählen';
	@override String get noKeys => 'Noch keine Schlüssel auf diesem Gerät.';
	@override String get importKey => 'Schlüssel importieren…';
	@override String get generateKey => 'Schlüssel erzeugen…';
	@override String get password => 'Passwort';
	@override String get passwordSavedHint => 'Leer lassen, um das gespeicherte Passwort zu behalten';
	@override String get passwordAskHint => 'Leer lassen, um beim Verbinden gefragt zu werden';
	@override String get savePassword => 'Passwort auf diesem Gerät speichern';
	@override String get tailscale => 'Über Tailscale erreichbar';
	@override String get jumpHosts => 'Jump-Hosts';
	@override String get jumpHostsHelp => 'Die Verbindung zum Rechner läuft der Reihe nach über diese Hosts. Für einen Host hinter NAT mit Reverse-Tunnel den Relay-Host hier eintragen und beim Rechner localhost als Host sowie den Tunnel-Port angeben.';
	@override String jumpHostN({required Object n}) => 'Jump-Host ${n}';
	@override String get addJumpHost => 'Jump-Host hinzufügen';
	@override String get moveUp => 'Nach oben';
	@override String get moveDown => 'Nach unten';
	@override String get remove => 'Entfernen';
	@override String get fromSshConfig => 'Aus SSH-Konfiguration';
	@override String get fromTailscale => 'Aus Tailscale';
	@override String proxyCommandIgnored({required Object command}) => 'ProxyCommand wird nicht unterstützt und wurde ignoriert: ${command}';
	@override String get hostKeysPretrusted => 'Hostschlüssel von Tailscale gelten beim Speichern als vertrauenswürdig.';
	@override String get agentHelp => 'Wie der Befehl ssh: zuerst die Schlüssel des ssh-agent (IdentityAgent, sonst SSH_AUTH_SOCK), dann die IdentityFile-Schlüssel, die ~/.ssh/config für diesen Host setzt, sonst ~/.ssh/id_ed25519, id_ecdsa und id_rsa. Verschlüsselte Schlüssel fragen nach ihrer Passphrase. Lehnt der Host jeden Schlüssel ab, folgt seine Passwortabfrage.';
}

// Path: keys
class _Translations$keys$de extends Translations$keys$en {
	_Translations$keys$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get empty => 'Noch keine Schlüssel. Importiere einen vorhandenen Schlüssel oder erzeuge einen neuen.';
	@override String get import => 'Schlüssel importieren';
	@override String get generate => 'Schlüssel erzeugen';
	@override String get copyPublicKey => 'Öffentlichen Schlüssel kopieren';
	@override String get publicKeyCopied => 'Öffentlicher Schlüssel kopiert.';
	@override String deleteTitle({required Object name}) => '${name} löschen?';
	@override String get deleteBody => 'Der private Schlüssel wird von diesem Gerät entfernt.';
	@override String deleteUsedBy({required Object machines}) => 'Rechner, die ihn nutzen, brauchen einen anderen Schlüssel: ${machines}.';
	@override String get name => 'Name';
	@override String get privateKey => 'Privater Schlüssel';
	@override String get privateKeyHint => 'OpenSSH- oder PEM-Schlüssel einfügen';
	@override String get passphrase => 'Passphrase';
	@override String get passphraseHint => 'Nur für verschlüsselte Schlüssel';
	@override String get importTitle => 'SSH-Schlüssel importieren';
	@override String get importAction => 'Importieren';
	@override String get generateTitle => 'Ed25519-Schlüssel erzeugen';
	@override String get generateAction => 'Erzeugen';
	@override String get generatedBody => 'Füge diesen öffentlichen Schlüssel auf deinen Rechnern zu ~/.ssh/authorized_keys hinzu.';
	@override String get malformed => 'Das ist kein privater Schlüssel, den die App lesen kann.';
	@override String get unsupported => 'Dieser Schlüsseltyp wird nicht unterstützt.';
	@override String get passphraseRequired => 'Dieser Schlüssel ist verschlüsselt. Gib seine Passphrase ein.';
	@override String get wrongPassphrase => 'Falsche Passphrase.';
	@override String duplicate({required Object name}) => 'Dieser Schlüssel ist bereits als ${name} gespeichert.';
	@override String get fileTooLarge => 'Diese Datei ist zu groß für einen privaten Schlüssel.';
}

// Path: hostKey
class _Translations$hostKey$de extends Translations$hostKey$en {
	_Translations$hostKey$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get unknownTitle => 'Diesem Host vertrauen?';
	@override String unknownBody({required Object host}) => 'Erste Verbindung zu ${host}. Vergleiche den Fingerabdruck mit dem Schlüssel des Servers, bevor du vertraust.';
	@override String get changedTitle => 'Hostschlüssel geändert';
	@override String changedBody({required Object host}) => '${host} hat einen anderen Schlüssel vorgelegt als den zuvor vertrauten. Der Server wurde vielleicht neu installiert, oder jemand fängt die Verbindung ab.';
	@override String changedOpenSshBody({required Object host}) => '${host} hat einen Schlüssel vorgelegt, der von ~/.ssh/known_hosts abweicht. Der Server wurde vielleicht neu installiert, oder jemand fängt die Verbindung ab.';
	@override String get previouslyTrusted => 'Zuvor vertraut';
	@override String get revokedTitle => 'Hostschlüssel widerrufen';
	@override String revokedBody({required Object host}) => '~/.ssh/known_hosts markiert den Schlüssel von ${host} als widerrufen. Die Verbindung wird abgelehnt.';
	@override String get keyType => 'Schlüsseltyp';
	@override String get fingerprint => 'Fingerabdruck';
	@override String get trust => 'Vertrauen';
	@override String get replace => 'Ersetzen und verbinden';
	@override String get otherTypesTitle => 'Unerwarteter Schlüsseltyp';
	@override String otherTypesBody({required Object host}) => '~/.ssh/known_hosts kennt ${host} nur mit Schlüsseln anderer Typen. Der Server hat vielleicht einen Schlüsseltyp hinzugefügt, oder jemand fängt die Verbindung ab. Vergleiche den Fingerabdruck mit dem Schlüssel des Servers, bevor du vertraust.';
	@override String get knownToOpenSsh => 'Bekannt in ~/.ssh/known_hosts';
}

// Path: links
class _Translations$links$de extends Translations$links$en {
	_Translations$links$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get confirmTitle => 'Diesen Link öffnen?';
	@override String confirmBody({required Object scheme}) => 'Das ist ein ${scheme}:-Link, keine Webseite. Er wird in der App geöffnet, die ${scheme}:-Links auf diesem Gerät verarbeitet.';
	@override String get open => 'Öffnen';
}

// Path: prompt
class _Translations$prompt$de extends Translations$prompt$en {
	_Translations$prompt$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String passwordTitle({required Object hop}) => 'Passwort für ${hop}';
	@override String signInTitle({required Object hop}) => 'Bei ${hop} anmelden';
	@override String passphraseTitle({required Object path}) => 'Passphrase für ${path}';
	@override String passphraseAccepted({required Object hop}) => '${hop} akzeptiert diesen Schlüssel. Gib die Passphrase ein, um ihn zu verwenden.';
	@override String passphraseUnknownKey({required Object hop}) => 'Gib die Passphrase ein, um diesen Schlüssel ${hop} anzubieten.';
	@override String get passphraseWrong => 'Falsche Passphrase.';
	@override String get passphrase => 'Passphrase';
	@override String get rememberPassphrase => 'Auf diesem Gerät merken';
}

// Path: connectError
class _Translations$connectError$de extends Translations$connectError$en {
	_Translations$connectError$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String noKeySelected({required Object hop}) => '${hop} nutzt Schlüssel-Authentifizierung, aber es ist kein Schlüssel ausgewählt. Bearbeite den Rechner, um einen auszuwählen.';
	@override String keyMissing({required Object hop}) => 'Der private Schlüssel für ${hop} fehlt auf diesem Gerät.';
	@override String passwordMissing({required Object hop}) => 'Kein Passwort für ${hop}.';
	@override String unreachable({required Object hop}) => '${hop} ist nicht erreichbar.';
	@override String hostKeyRejected({required Object hop}) => 'Dem Hostschlüssel von ${hop} wurde nicht vertraut.';
	@override String authFailed({required Object hop}) => '${hop} hat die Zugangsdaten abgelehnt.';
	@override String timeout({required Object hop}) => '${hop} hat nicht rechtzeitig geantwortet.';
	@override String keyUnavailable({required Object hop}) => 'Der Schlüssel für ${hop} kann auf diesem Gerät nicht verwendet werden.';
	@override String protocol({required Object hop}) => 'SSH-Handshake mit ${hop} fehlgeschlagen.';
	@override String keyRefused({required Object host, required Object key}) => '${host} hat den Schlüssel ${key} nicht akzeptiert.';
	@override String agentKeysRefused({required num n, required Object host}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${host} hat den einzigen Schlüssel im ssh-agent nicht akzeptiert.',
		other: '${host} hat keinen der ${n} Schlüssel im ssh-agent akzeptiert.',
	);
	@override String keysRefused({required Object host}) => '${host} hat keinen dieser Schlüssel akzeptiert:';
	@override String agentKey({required Object comment}) => '${comment} aus dem ssh-agent';
	@override String get agentKeyUnnamed => 'ein Schlüssel aus dem ssh-agent';
	@override String authorizedKeysHint({required Object user, required Object host}) => 'Füge den öffentlichen Schlüssel in ~/.ssh/authorized_keys von ${user} auf ${host} ein.';
	@override String noKeys({required Object host}) => 'Kein Schlüssel für ${host} verfügbar. Füge einen mit ssh-add zum ssh-agent hinzu oder benenne ihn mit IdentityFile in ~/.ssh/config.';
}

// Path: tailscale
class _Translations$tailscale$de extends Translations$tailscale$en {
	_Translations$tailscale$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'Tailscale-Geräte';
	@override String get notInstalled => 'Tailscale ist auf diesem Computer nicht installiert.';
	@override String failed({required Object message}) => 'Tailscale hat nicht geantwortet: ${message}';
	@override String notRunning({required Object state}) => 'Tailscale ist nicht verbunden (Status: ${state}).';
	@override String get noPeers => 'Keine weiteren Geräte in diesem Tailnet.';
	@override String get offline => 'offline';
	@override String get search => 'Geräte durchsuchen';
}

// Path: sshConfig
class _Translations$sshConfig$de extends Translations$sshConfig$en {
	_Translations$sshConfig$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'Hosts aus der SSH-Konfiguration';
	@override String get empty => 'Keine Hosts in ~/.ssh/config.';
	@override String failed({required Object error}) => '~/.ssh/config konnte nicht gelesen werden: ${error}';
}

// Path: transfer
class _Translations$transfer$de extends Translations$transfer$en {
	_Translations$transfer$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get exportTitle => 'Rechner exportieren';
	@override String exportBody({required Object count}) => '${count} SSH-Rechner mit ihren Jump-Hosts und vertrauenswürdigen Hostschlüsseln. Private Schlüssel, Passphrasen und Passwörter werden nie exportiert.';
	@override String get exportNone => 'Es gibt keine SSH-Rechner zum Exportieren.';
	@override String get saveFile => 'In Datei speichern…';
	@override String get saved => 'Gespeichert.';
	@override String get importTitle => 'Rechner importieren';
	@override String get importHint => 'Füge einen Export von einem anderen Gerät ein oder wähle seine Datei.';
	@override String get importAction => 'Importieren';
	@override String imported({required Object added, required Object skipped}) => '${added} importiert, ${skipped} übersprungen (bereits vorhanden).';
	@override String invalid({required Object error}) => 'Kein Rechner-Export: ${error}';
	@override String get hostKeysTitle => 'Zu bestätigende Hostschlüssel';
	@override String get hostKeysBody => 'Der Import enthält Hostschlüssel, die ändern würden, welchen Servern dieses Gerät vertraut. Vertraue den Schlüsseln eines Hosts nur, wenn du weißt, dass sie stimmen; die anderen werden nicht importiert.';
	@override String get trustedHere => 'Auf diesem Gerät vertrauenswürdig';
	@override String get nothingTrusted => 'Noch nichts';
	@override String get inImport => 'Im Import';
	@override String get trustKeys => 'Diesen Schlüsseln vertrauen';
	@override String get keysTrusted => 'Vertraut';
}

// Path: settings
class _Translations$settings$de extends Translations$settings$en {
	_Translations$settings$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get theme => 'Design';
	@override String get themeSystem => 'System';
	@override String get themeLight => 'Hell';
	@override String get themeDark => 'Dunkel';
	@override String get themeCustom => 'Eigenes';
	@override String get editColors => 'Farben bearbeiten';
	@override String get language => 'Sprache';
	@override String get languageSystem => 'System';
	@override String customBase({required Object base}) => '${base} (Basis)';
	@override String customPicked({required Object base, required Object count}) => '${base} (Basis) · ${count} geändert';
	@override String get buildChannel => 'Build-Kanal';
	@override String get shortcuts => 'Tastenkürzel';
	@override String get shortcutToggleSidebar => 'Seitenleiste umschalten';
	@override String get shortcutTogglePanels => 'Panels umschalten';
	@override String get shortcutPanelTab => 'Einen Panel-Tab anzeigen';
	@override String get shortcutAddMachine => 'Rechner hinzufügen';
	@override String get shortcutSettings => 'Einstellungen';
	@override String get shortcutNewSession => 'Neue Sitzung';
	@override String get shortcutTogglePause => 'Sitzung pausieren oder fortsetzen';
	@override String get shortcutPalette => 'Befehlspalette';
	@override String get shortcutSearchSessions => 'Sitzungen durchsuchen';
	@override String get shortcutAbort => 'Laufenden Durchlauf stoppen';
	@override String get about => 'Über';
	@override String aboutVersion({required Object version, required Object build}) => 'Version ${version} (Build ${build})';
	@override String get aboutClient => 'Ein Client für omp, den Coding-Agenten oh-my-pi';
	@override String get aboutPrivacy => 'Datenschutzerklärung';
	@override String get aboutSource => 'Quellcode';
	@override String get aboutIssues => 'Problem melden';
	@override String get aboutLicense => 'Lizenz';
	@override String get aboutLicenseValue => 'GPL-3.0';
	@override String get aboutLicenses => 'Open-Source-Lizenzen';
}

// Path: themeEditor
class _Translations$themeEditor$de extends Translations$themeEditor$en {
	_Translations$themeEditor$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'Eigenes Design';
	@override String get resetAll => 'Alles zurücksetzen';
	@override String get startFrom => 'Ausgangspunkt';
	@override String get reset => 'Auf die Basisfarbe zurücksetzen';
	@override String get hex => 'Hex-Farbe';
	@override String get terminalNote => 'Das Terminal stellt diese unverändert dar; Befehlsausgaben im Chat behalten ihren Farbton bei eigenem Kontrast.';
	@override Map<String, String> get groups => {
		'surfaces': 'Flächen',
		'text': 'Text',
		'accent': 'Akzent',
		'status': 'Status',
		'diff': 'Diff',
		'syntax': 'Syntax-Hervorhebung',
		'terminal': 'Terminal',
	};
	@override Map<String, String> get names => {
		'background': 'Hintergrund',
		'pane': 'Bereiche',
		'card': 'Karten',
		'field': 'Eingabefelder',
		'selected': 'Auswahl',
		'popover': 'Pop-ups',
		'text': 'Text',
		'textMuted': 'Gedämpfter Text',
		'accent': 'Akzent',
		'onAccent': 'Auf Akzent',
		'error': 'Fehler',
		'errorSurface': 'Fehlerhintergrund',
		'warning': 'Warnung',
		'success': 'Erfolg',
		'running': 'Läuft',
		'diffAdd': 'Hinzugefügt',
		'diffAddSurface': 'Hintergrund für Hinzugefügtes',
		'diffRemove': 'Entfernt',
		'diffRemoveSurface': 'Hintergrund für Entferntes',
		'comment': 'Kommentare',
		'keyword': 'Schlüsselwörter',
		'tag': 'Tags',
		'literal': 'Literale',
		'string': 'Strings',
		'number': 'Zahlen',
		'title': 'Funktionen',
		'builtIn': 'Eingebaute',
		'ansiBlack': 'Schwarz',
		'ansiRed': 'Rot',
		'ansiGreen': 'Grün',
		'ansiYellow': 'Gelb',
		'ansiBlue': 'Blau',
		'ansiMagenta': 'Magenta',
		'ansiCyan': 'Cyan',
		'ansiWhite': 'Weiß',
		'ansiBrightBlack': 'Hellschwarz',
		'ansiBrightRed': 'Hellrot',
		'ansiBrightGreen': 'Hellgrün',
		'ansiBrightYellow': 'Hellgelb',
		'ansiBrightBlue': 'Hellblau',
		'ansiBrightMagenta': 'Hellmagenta',
		'ansiBrightCyan': 'Hellcyan',
		'ansiBrightWhite': 'Hellweiß',
	};
	@override Map<String, String> get uses => {
		'background': 'App-Hintergrund, Chat, Terminal',
		'pane': 'Seitenleiste, Dock, Konfigurationsnavigation',
		'card': 'Karten, Eingabefeld, Codeblöcke, Dialoge',
		'field': 'Textfelder, Chips, sekundäre Buttons',
		'selected': 'Hover, ausgewählte Zeilen, fokussierte Felder, Tab-Indikatoren',
		'popover': 'Menüs und Pop-up-Listen',
		'text': 'Primärer Text und Symbole',
		'textMuted': 'Sekundärer Text und Symbole',
		'accent': 'Primäre Buttons, aktive Schalter, Fortschritt',
		'onAccent': 'Text und Symbole auf dem Akzent',
		'error': 'Fehler und fehlgeschlagene Läufe',
		'errorSurface': 'Hinter Fehlermeldungen',
		'warning': 'Warnungen, pausierte Ziele und Schleifen',
		'success': 'Fertige Läufe, bestandene Prüfungen',
		'running': 'Laufende Arbeit',
		'diffAdd': 'Hinzugefügte Zeilen',
		'diffAddSurface': 'Hinter hinzugefügten Zeilen',
		'diffRemove': 'Entfernte Zeilen',
		'diffRemoveSurface': 'Hinter entfernten Zeilen',
		'comment': 'Kommentare und Zitate',
		'keyword': 'Schlüsselwörter und Doc-Tags',
		'tag': 'Tags, Namen, Abschnitte',
		'literal': 'true, false, null',
		'string': 'Strings, reguläre Ausdrücke, Attribute',
		'number': 'Zahlen, Typen, Variablen',
		'title': 'Funktionsnamen, Titel, Links',
		'builtIn': 'Eingebaute und Klassennamen',
		'ansiBlack': 'ANSI 0',
		'ansiRed': 'ANSI 1',
		'ansiGreen': 'ANSI 2',
		'ansiYellow': 'ANSI 3',
		'ansiBlue': 'ANSI 4',
		'ansiMagenta': 'ANSI 5',
		'ansiCyan': 'ANSI 6',
		'ansiWhite': 'ANSI 7',
		'ansiBrightBlack': 'ANSI 8',
		'ansiBrightRed': 'ANSI 9',
		'ansiBrightGreen': 'ANSI 10',
		'ansiBrightYellow': 'ANSI 11',
		'ansiBrightBlue': 'ANSI 12',
		'ansiBrightMagenta': 'ANSI 13',
		'ansiBrightCyan': 'ANSI 14',
		'ansiBrightWhite': 'ANSI 15',
	};
	@override late final _Translations$themeEditor$preview$de preview = _Translations$themeEditor$preview$de._(_root);
}

// Path: notifications
class _Translations$notifications$de extends Translations$notifications$en {
	_Translations$notifications$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'Benachrichtigungen';
	@override String get desktop => 'Benachrichtigungen';
	@override String get desktopDetail => 'Zu den hier offenen Sitzungen, während du in einem anderen Fenster oder einer anderen Sitzung bist';
	@override String get push => 'Push-Benachrichtigungen';
	@override String get pushDetail => 'Von deinen Rechnern, während dieses Telefon nicht in der Sitzung ist';
	@override String get pushLost => 'Deaktiviert: Dieses Telefon hat seinen Benachrichtigungsschlüssel nicht mehr, etwa nach einer Wiederherstellung aus einem Backup. Schalte sie wieder ein.';
	@override String pushUnavailable({required Object reason}) => 'Nicht verfügbar: ${reason}';
	@override String get kindInput => 'Eine Sitzung braucht eine Eingabe';
	@override String get kindDone => 'Ein Lauf endet';
	@override String get kindFailed => 'Ein Lauf schlägt fehl';
	@override String get test => 'Testbenachrichtigung senden';
	@override String get testNone => 'Verbinde dich mit einem Rechner, um eine Testbenachrichtigung zu senden.';
	@override String testSent({required Object machine}) => 'Testbenachrichtigung von ${machine} gesendet.';
	@override String testFailed({required Object machine, required Object error}) => 'Die Testbenachrichtigung von ${machine} ist fehlgeschlagen: ${error}';
	@override String get denied => 'Benachrichtigungen sind für ompanion in den Systemeinstellungen deaktiviert.';
	@override String enableFailed({required Object error}) => 'Einschalten der Push-Benachrichtigungen fehlgeschlagen: ${error}';
	@override String disableFailed({required Object error}) => 'Ausschalten der Push-Benachrichtigungen fehlgeschlagen: ${error}';
	@override String registrationFailed({required Object machine, required Object error}) => 'Push-Benachrichtigungen auf ${machine} konnten nicht aktualisiert werden: ${error}';
	@override String get unknownMachine => 'Diese Benachrichtigung kam von einem Rechner, der nicht mehr in ompanion ist.';
	@override String subtitle({required Object machine, required Object kind}) => '${machine} · ${kind}';
	@override String get subtitleInput => 'Braucht Eingabe';
	@override String get subtitleDone => 'Fertig';
	@override String get subtitleFailed => 'Fehlgeschlagen';
	@override String approval({required Object tool}) => '${tool} erlauben?';
	@override String goalComplete({required Object objective}) => 'Ziel erreicht: ${objective}';
	@override String get finished => 'Fertig';
	@override String get runFailed => 'Der Lauf ist fehlgeschlagen';
	@override String get open => 'Öffnen';
}

// Path: time
class _Translations$time$de extends Translations$time$en {
	_Translations$time$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get now => 'jetzt';
	@override String minutes({required Object n}) => '${n} min';
	@override String hours({required Object n}) => '${n} h';
	@override String days({required Object n}) => '${n} d';
}

// Path: units
class _Translations$units$de extends Translations$units$en {
	_Translations$units$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String milliseconds({required Object value}) => '${value} ms';
	@override String seconds({required Object value}) => '${value} s';
	@override String minutes({required Object value}) => '${value} min';
	@override String hours({required Object value}) => '${value} h';
	@override String days({required Object value}) => '${value} d';
	@override String pair({required Object big, required Object small}) => '${big} ${small}';
	@override String percent({required Object value}) => '${value} %';
	@override String usd({required Object value}) => '${value} \$';
}

// Path: sessions
class _Translations$sessions$de extends Translations$sessions$en {
	_Translations$sessions$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get offline => 'Offline';
	@override String get connecting => 'Verbindung wird hergestellt…';
	@override String online({required Object version}) => 'omp ${version}';
	@override String needsOmp({required Object reason}) => 'omp erforderlich: ${reason}';
	@override String get connect => 'Verbinden';
	@override String get install => 'omp installieren';
	@override String get refresh => 'Aktualisieren';
	@override String get collapse => 'Einklappen';
	@override String get expand => 'Ausklappen';
	@override String get configure => 'Konfigurieren';
	@override String get machinePage => 'Rechnereinstellungen';
	@override String get pin => 'Oben anheften';
	@override String get unpin => 'Anheften aufheben';
	@override String get markRead => 'Als gelesen markieren';
	@override String get newSession => 'Neue Sitzung';
	@override String get newSessionHere => 'Neue Sitzung in diesem Verzeichnis';
	@override String newSessionOn({required Object machine}) => 'Neue Sitzung auf ${machine}';
	@override String get none => 'Noch keine Sitzungen.';
	@override String get untitled => 'Neue Sitzung';
	@override String get unknownDirectory => 'Unbekanntes Verzeichnis';
	@override String showMore({required Object n}) => '${n} weitere anzeigen';
	@override String get working => 'Arbeitet';
	@override String get needsInput => 'Braucht deine Eingabe';
	@override String get failed => 'Der letzte Lauf ist fehlgeschlagen';
	@override String get disconnected => 'Getrennt';
	@override String get runningOnMachine => 'In omp auf dem Rechner geöffnet';
	@override String get opening => 'Wird geöffnet…';
	@override String get unread => 'Ungelesen';
	@override String openFailed({required Object error}) => 'Sitzung konnte nicht geöffnet werden: ${error}';
	@override String modelUnavailable({required Object model}) => 'omp kann ${model} nicht verwenden, das Modell, auf dem diese Sitzung lief';
	@override String get resumeModelTitle => 'Mit einem anderen Modell fortsetzen';
	@override String resumeModelBody({required Object machine, required Object model}) => 'omp auf ${machine} kann ${model} nicht verwenden, das Modell, auf dem diese Sitzung lief. Wähle das Modell, mit dem das Gespräch fortgesetzt wird.';
	@override String listFailed({required Object error}) => 'Sitzungen konnten nicht aufgelistet werden: ${error}';
	@override String get folder => 'Ordner';
	@override String get noFolder => 'Kein Ordner';
	@override String get noFolderHint => 'omp arbeitet in einem temporären Verzeichnis, wie beim Start im Home-Ordner. Die Sitzung erscheint direkt unter dem Rechner.';
	@override String noTempDirectory({required Object paths, required Object machine}) => 'Keines der temporären Verzeichnisse von omp (${paths}) ist ein Verzeichnis auf ${machine}.';
	@override String get directory => 'Arbeitsverzeichnis';
	@override String get directoryHint => 'Ein Pfad auf dem Rechner, z. B. ~/code/project';
	@override String get directoryRequired => 'Wähle ein Arbeitsverzeichnis.';
	@override String notADirectory({required Object path, required Object machine}) => '${path} ist kein Verzeichnis auf ${machine}.';
	@override String get recentDirectories => 'Zuletzt verwendete Projekte';
	@override String get model => 'Modell (optional)';
	@override String get modelDefault => 'Standard (aus den Einstellungen von omp)';
	@override String get modelPick => 'Modell wählen';
	@override String get modelUseDefault => 'Modell aus den Einstellungen von omp verwenden';
	@override String get create => 'Starten';
	@override String get browse => 'Rechner durchsuchen';
	@override String get browseTitle => 'Verzeichnis wählen';
	@override String get up => 'Übergeordnetes Verzeichnis';
	@override String get showHidden => 'Versteckte Verzeichnisse anzeigen';
	@override String get chooseDirectory => 'Dieses Verzeichnis verwenden';
	@override String get external => 'In omp auf dem Rechner';
}

// Path: install
class _Translations$install$de extends Translations$install$en {
	_Translations$install$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String title({required Object machine}) => 'omp auf ${machine} installieren';
	@override String get notConnected => 'Verbinde dich zuerst mit dem Rechner.';
	@override String get viaDownload => 'Der Rechner lädt dieses Release von GitHub herunter und prüft dessen SHA-256, bevor er es installiert.';
	@override String get viaUpload => 'Der Rechner hat weder curl noch wget: die App lädt das Release hier herunter und lädt es hoch, wobei die SHA-256 auf dem Rechner geprüft wird.';
	@override String get manual => 'Skript selbst ausführen';
	@override String get install => 'Installieren';
	@override String get installing => 'Wird auf dem Rechner heruntergeladen und installiert…';
	@override String get installFailed => 'Installation auf dem Rechner fehlgeschlagen';
	@override String downloading({required Object asset}) => '${asset} wird heruntergeladen…';
	@override String downloadFailed({required Object status, required Object url}) => 'Download fehlgeschlagen mit HTTP ${status}: ${url}';
	@override String transferring({required Object asset, required Object done, required Object total}) => 'Übertrage ${asset}: ${done} von ${total} MB';
	@override String get checking => 'Installation wird geprüft…';
	@override String stillMissing({required Object reason}) => 'omp ist weiterhin nicht nutzbar: ${reason}';
	@override String noAsset({required Object os, required Object arch}) => 'omp veröffentlicht keinen Build für ${os} ${arch}.';
	@override String done({required Object version}) => 'omp ${version} installiert.';
	@override String get os => 'OS';
	@override String get arch => 'Architektur';
	@override String get release => 'Release';
	@override String get directory => 'Installationsverzeichnis';
}

// Path: chat
class _Translations$chat$de extends Translations$chat$en {
	_Translations$chat$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get noModel => 'Kein Modell';
	@override String get searchModels => 'Modelle suchen';
	@override String get refreshModels => 'Modellliste neu laden';
	@override String get noModels => 'Keine Modelle passen.';
	@override String modelsFailed({required Object error}) => 'Modelle konnten nicht geladen werden: ${error}';
	@override String modelFailed({required Object error}) => 'Modell konnte nicht gewechselt werden: ${error}';
	@override String modelAgent({required Object agent}) => 'Subagent ${agent}';
	@override String contextWindow({required Object tokens}) => '${tokens} Kontext';
	@override String get reasoning => 'Reasoning';
	@override String thinking({required Object level}) => 'Denken: ${level}';
	@override String get noThinking => 'Dieses Modell hat keine Denkstufen.';
	@override String thinkingFailed({required Object error}) => 'Denkstufe konnte nicht geändert werden: ${error}';
	@override String contextTooltip({required Object tokens, required Object window, required Object percent, required Object cost}) => 'Kontext: ${tokens} von ${window} Tokens (${percent} %) · Kosten ${cost}';
	@override String contextUnknown({required Object cost}) => 'Kontextnutzung noch unbekannt · Kosten ${cost}';
	@override String get pause => 'Pausieren';
	@override String get resume => 'Fortsetzen';
	@override String pauseFailed({required Object error}) => 'Pausieren oder Fortsetzen fehlgeschlagen: ${error}';
	@override String get stop => 'Stoppen';
	@override String abortFailed({required Object error}) => 'Lauf konnte nicht gestoppt werden: ${error}';
	@override String get noCompanion => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind Pausieren, Bearbeiten der Warteschlange, Shell- oder Python-Läufe, Ziele und Schleifen nicht verfügbar.';
	@override String get more => 'Mehr';
	@override String get copyPath => 'Pfad der Sitzungsdatei kopieren';
	@override String get detach => 'Auf diesem Gerät schließen';
	@override String get stopSession => 'omp-Prozess stoppen';
	@override String get setGoal => 'Ziel setzen…';
	@override String get guidedGoal => 'Geführtes Ziel…';
	@override String get startLoop => 'Prompt in Schleife…';
	@override String stopSessionFailed({required Object error}) => 'omp-Prozess konnte nicht gestoppt werden: ${error}';
	@override String reconnecting({required Object attempt, required Object seconds}) => 'Verbindung verloren. Neuer Versuch (${attempt}) in ${seconds} s.';
	@override String get retryNow => 'Jetzt erneut versuchen';
	@override String get closed => 'Diese Sitzung ist geschlossen.';
	@override String exited({required Object code}) => 'omp wurde mit Code ${code} beendet.';
	@override String idleExited({required Object duration}) => 'omp wurde nach ${duration} ohne Aktivität gestoppt.';
	@override String get idleExitedDetail => 'Eine Nachricht startet es erneut.';
	@override String get reopen => 'Wieder öffnen';
	@override String reopenFailed({required Object error}) => 'Sitzung konnte nicht wieder geöffnet werden: ${error}';
	@override String get parked => 'Pausiert: der Lauf wartet vor dem nächsten Schritt';
	@override String get compacting => 'Kontext wird kompaktiert…';
	@override String retrying({required Object attempt, required Object max, required Object error}) => 'Neuer Versuch (${attempt} von ${max}): ${error}';
	@override String failed({required Object error}) => 'Der letzte Lauf ist fehlgeschlagen: ${error}';
	@override String get failedUnknown => 'unbekannter Fehler';
	@override String get aborted => 'Gestoppt';
	@override String get closedState => 'Geschlossen';
	@override String get commandOutput => 'Befehlsausgabe';
	@override String extensionError({required Object path, required Object event, required Object error}) => 'Fehler der Erweiterung in ${path} (${event}): ${error}';
	@override String fallbackServed({required Object model}) => 'Vom Ausweichmodell ${model} bedient.';
	@override String fallbackApplied({required Object from, required Object to, required Object reason}) => 'Von ${from} auf das Ausweichmodell ${to} gewechselt. ${reason}';
	@override String get compactionCancelled => 'Kompaktierung wurde abgebrochen.';
	@override String compactionFailed({required Object error}) => 'Kompaktierung fehlgeschlagen: ${error}';
	@override String get cannotBranch => 'Abzweigen ist nur von deinen eigenen Nachrichten aus möglich.';
	@override String get branch => 'Abzweigen';
	@override String get branchTitle => 'Von dieser Nachricht abzweigen?';
	@override String branchBody({required Object text}) => 'Eine neue Sitzungsdatei beginnt vor dieser Nachricht, und die Nachricht geht zurück ins Eingabefeld:\n\n${text}';
	@override String branchFailed({required Object error}) => 'Abzweigen fehlgeschlagen: ${error}';
	@override String get resetKept => 'Frühere Antworten bleiben im Sitzungsbaum erhalten.';
	@override String get openTree => 'Baum öffnen';
	@override String resetFailed({required Object error}) => 'Zurücksetzen fehlgeschlagen: ${error}';
	@override String get replaceDraftTitle => 'Deinen Entwurf ersetzen?';
	@override String get replaceDraftBody => 'Zurücksetzen bis hierher legt diese Nachricht zurück ins Eingabefeld. Text und Anhänge, die du nicht gesendet hast, gehen verloren.';
	@override String get replaceDraft => 'Ersetzen';
}

// Path: attachments
class _Translations$attachments$de extends Translations$attachments$en {
	_Translations$attachments$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get paste => 'Der große Einfügetext';
	@override String missing({required Object name}) => '${name} ist nicht mehr auf diesem Gerät. Es wurde nichts gesendet.';
	@override String tooLarge({required Object name, required Object size, required Object limit}) => '${name} ist ${size}; Anhänge dürfen höchstens ${limit} groß sein. Es wurde nichts gesendet.';
	@override String folder({required Object name}) => '${name} ist ein Ordner. Ordner lassen sich nur an Sitzungen auf diesem Computer anhängen. Es wurde nichts gesendet.';
	@override String needsCompanion({required Object name}) => '${name} braucht den Companion, um den Rechner der Sitzung zu erreichen, und diese Sitzung hat keinen. Es wurde nichts gesendet.';
	@override String uploadFailed({required Object name, required Object error}) => '${name} konnte nicht auf den Rechner der Sitzung kopiert werden: ${error}. Es wurde nichts gesendet.';
}

// Path: composer
class _Translations$composer$de extends Translations$composer$en {
	_Translations$composer$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get hint => 'Nachricht an omp';
	@override String get hintRunning => 'Laufenden Durchlauf lenken';
	@override String get send => 'Senden';
	@override String get steer => 'Lenken';
	@override String get followUp => 'Folgenachricht';
	@override String get attach => 'Dateien anhängen';
	@override String get attachPhotos => 'Fotomediathek';
	@override String get attachFiles => 'Dateien';
	@override String get remove => 'Entfernen';
	@override String get pastedImage => 'Eingefügtes Bild';
	@override String pastedText({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'Eingefügter Text · ${n} Zeile',
		other: 'Eingefügter Text · ${n} Zeilen',
	);
	@override String get pasteInline => 'Inline einfügen';
	@override String previewTruncated({required Object shown, required Object total}) => 'Die ersten ${shown} von ${total} Zeichen werden angezeigt.';
	@override String get dropToAttach => 'Zum Anhängen loslassen';
	@override String get dropNothing => 'Nur Dateien und Ordner können angehängt werden.';
	@override String pasteFailed({required Object error}) => 'Einfügen fehlgeschlagen: ${error}';
	@override String attachFailed({required Object error}) => 'Anhängen fehlgeschlagen: ${error}';
	@override String uploading({required Object sent, required Object total}) => 'Hochladen ${sent} von ${total}';
	@override String unknownCommand({required Object name}) => '/${name} ist kein Befehl dieser Sitzung. Es wurde nichts gesendet.';
	@override String sendFailed({required Object error}) => 'Nicht gesendet: ${error}';
	@override String externalRunning({required Object machine}) => 'Läuft in omp auf ${machine}';
	@override String externalIdle({required Object machine}) => 'In omp auf ${machine} geöffnet';
	@override String externalTerminal({required Object terminal}) => 'Terminal ${terminal}';
	@override String get externalBody => 'Ein anderer omp-Prozess schreibt in diese Sitzungsdatei. ompanion liest den Verlauf live mit, aber Senden ist aus: zwei Schreiber würden sich gegenseitig überschreiben. In jenem Prozess eingereihte Nachrichten sind hier nicht sichtbar.';
	@override String get externalWait => 'Der andere omp-Prozess besitzt diese Sitzung noch. Übernimm sie, sobald er beendet ist.';
	@override String get takeOver => 'Übernehmen';
	@override String get externalRunningNoMachine => 'Läuft in omp';
	@override String get externalIdleNoMachine => 'In omp geöffnet';
	@override String get externalGone => 'Der andere omp-Prozess wurde beendet';
	@override String get externalBodyGone => 'Der andere omp-Prozess ist weg. Übernimm die Sitzung, um von hier Nachrichten zu senden.';
}

// Path: queue
class _Translations$queue$de extends Translations$queue$en {
	_Translations$queue$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get steer => 'Lenken';
	@override String get followUp => 'Folgenachricht';
	@override String more({required Object n}) => '+${n} weitere';
	@override String get edit => 'Im Eingabefeld bearbeiten';
	@override String get remove => 'Aus der Warteschlange entfernen';
	@override String takeFailed({required Object error}) => 'Warteschlange konnte nicht geändert werden: ${error}';
}

// Path: goal
class _Translations$goal$de extends Translations$goal$en {
	_Translations$goal$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String label({required Object usage}) => 'Ziel ${usage}';
	@override late final _Translations$goal$status$de status = _Translations$goal$status$de._(_root);
	@override String tooltip({required Object status, required Object usage}) => 'Ziel · ${status} · ${usage}';
	@override String usage({required Object used, required Object budget, required Object left}) => '${used} von ${budget} Tokens (${left} übrig)';
	@override String usageNoBudget({required Object used}) => '${used} Tokens, kein Budget';
	@override String spent({required Object time}) => '${time} aufgewendet';
	@override String get pause => 'Pausieren';
	@override String get resume => 'Fortsetzen';
	@override String get budget => 'Token-Budget';
	@override String get budgetHint => 'Eine Zahl oder off';
	@override String get setBudget => 'Budget festlegen';
	@override String get budgetInvalid => 'Das Zielbudget muss eine positive Ganzzahl oder `off` sein.';
	@override String get drop => 'Verwerfen…';
	@override String get dropTitle => 'Ziel verwerfen?';
	@override String get dropBody => 'Damit wird der Zieleintrag entfernt. Die aufgelaufene Nutzung bleibt im Sitzungsprotokoll.';
	@override String get dropConfirm => 'Verwerfen';
	@override String failed({required Object error}) => 'Ziel konnte nicht geändert werden: ${error}';
}

// Path: loop
class _Translations$loop$de extends Translations$loop$en {
	_Translations$loop$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String iterations({required Object remaining, required Object total}) => 'Schleife ${remaining}/${total}';
	@override String timeLeft({required Object time}) => 'Schleife · ${time} übrig';
	@override String get running => 'Schleife läuft';
	@override String get waiting => 'Schleife wartet';
	@override String get paused => 'Schleife pausiert';
	@override String iterationsLeft({required Object remaining, required Object total}) => 'Noch ${remaining} von ${total} Iterationen';
	@override String timeLeftOf({required Object time, required Object total}) => 'Noch ${time} von ${total}';
	@override String whileCondition({required Object command}) => 'solange `${command}` erfolgreich ist';
	@override String untilCondition({required Object command}) => 'bis `${command}` erfolgreich ist';
	@override String get whileLabel => 'Läuft weiter, solange dieser Befehl erfolgreich ist:';
	@override String get untilLabel => 'Läuft weiter, bis dieser Befehl erfolgreich ist:';
	@override String done({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'bisher ${n} Iteration',
		other: 'bisher ${n} Iterationen',
	);
	@override String get waitingPrompt => 'Wartet auf deinen nächsten Prompt, den sie nach jedem Durchlauf wiederholt.';
	@override String get pausedPrompt => 'Ausgesetzt. Der nächste Prompt, den du sendest, setzt sie fort.';
	@override String get suspend => 'Aussetzen';
	@override String get disable => 'Ausschalten';
	@override String failed({required Object error}) => 'Schleife konnte nicht geändert werden: ${error}';
}

// Path: exec
class _Translations$exec$de extends Translations$exec$en {
	_Translations$exec$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get running => 'läuft';
	@override String exited({required Object code}) => 'Exit ${code}';
	@override String get cancelled => 'abgebrochen';
	@override String failed({required Object error}) => 'fehlgeschlagen: ${error}';
	@override String get abort => 'Stopp';
	@override String get truncated => 'Ausgabe gekürzt';
}

// Path: requests
class _Translations$requests$de extends Translations$requests$en {
	_Translations$requests$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String approvalTitle({required Object tool}) => '${tool} zulassen?';
	@override String position({required Object index, required Object count}) => '${index} von ${count}';
	@override String get previous => 'Vorherige Anfrage';
	@override String get next => 'Nächste Anfrage';
	@override String get submit => 'Absenden';
	@override String get yes => 'Ja';
	@override String get no => 'Nein';
	@override String get editorText => 'Text im Eingabefeld';
	@override String get openUrlTitle => 'In deinem Browser öffnen';
	@override String get openInBrowser => 'Öffnen';
	@override String forwarding({required Object port}) => 'localhost:${port} auf diesem Gerät wird für den Login-Callback an den Rechner weitergeleitet.';
	@override String forwardFailed({required Object error}) => 'Der Login-Callback-Port konnte nicht weitergeleitet werden: ${error}';
	@override String answerFailed({required Object error}) => 'Die Antwort konnte nicht gesendet werden: ${error}';
	@override String get unsupportedTitle => 'Nicht unterstützte Anfrage';
	@override String unsupportedBody({required Object method}) => 'Der Companion hat "${method}" angefragt, was diese App-Version nicht anzeigen kann.';
	@override String secondsLeft({required Object n}) => 'noch ${n} s';
	@override String get notWebLink => 'Kein http- oder https-Link, öffnet sich daher nicht von hier.';
}

// Path: ask
class _Translations$ask$de extends Translations$ask$en {
	_Translations$ask$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get title => 'Frage';
	@override String titleMany({required Object n}) => '${n} Fragen';
	@override String invalid({required Object error}) => 'Die Frage konnte nicht gelesen werden: ${error}';
	@override String get recommended => 'Empfohlen';
	@override String get multi => 'Wähle beliebig viele.';
	@override String get otherHint => 'Sonstiges: eigene Antwort eingeben';
	@override String get note => 'Notiz (optional)';
	@override String get chat => 'Dazu chatten';
}

// Path: transcript
class _Translations$transcript$de extends Translations$transcript$en {
	_Translations$transcript$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get jumpToLatest => 'Zum Neuesten springen';
	@override String get loadEarlier => 'Frühere Nachrichten laden';
	@override String get branchFromHere => 'Von hier abzweigen';
	@override String get resetHere => 'Bis hierher zurücksetzen';
	@override String get resetRunning => 'Warte, bis der Durchlauf fertig ist, oder stoppe ihn, bevor du zurücksetzt';
	@override String get copyMessage => 'Nachricht kopieren';
	@override String get copyCode => 'Code kopieren';
	@override String get copyOutput => 'Ausgabe kopieren';
	@override String get fromAgent => 'Vom Agenten gesendet';
	@override String get automatic => 'Automatische Nachricht';
	@override String get waiting => 'Wartet auf Antwort';
	@override String waitingElapsed({required Object seconds}) => 'Wartet auf Antwort · ${seconds} s';
	@override String get thinking => 'Denkt nach…';
	@override String get thought => 'Gedanke';
	@override String thoughtFor({required Object duration}) => 'Nachgedacht: ${duration}';
	@override String reasoningTokens({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Reasoning-Token',
		other: '${n} Reasoning-Tokens',
	);
	@override String get redactedThinking => 'Reasoning vom Anbieter ausgeblendet';
	@override String get interrupted => 'Unterbrochen';
	@override String get failed => 'Die Antwort ist fehlgeschlagen.';
	@override String get lengthLimit => 'Beim Ausgabe-Token-Limit gestoppt.';
	@override String retryRecovered({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; Wiederholung ${attempt} war erfolgreich.';
	@override String retrySuperseded({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; die Wiederholung hat nach Versuch ${attempt} aufgegeben.';
	@override String retryFailed({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; Wiederholung ${attempt} ist ebenfalls fehlgeschlagen.';
	@override String tokensIn({required Object count}) => '${count} rein';
	@override String tokensOut({required Object count}) => '${count} raus';
	@override String tokensCached({required Object count}) => '${count} aus Cache';
	@override String seconds({required Object value}) => '${value} s';
	@override String get image => 'Bild';
	@override String get loadImage => 'Bild laden';
	@override String imageLoading({required Object name}) => 'Lade ${name}…';
	@override String imageMissing({required Object path}) => 'Bild nicht gefunden: ${path}';
	@override String imageNotFile({required Object path}) => 'Keine Datei: ${path}';
	@override String imageDenied({required Object path}) => 'Keine Berechtigung zum Lesen von ${path}';
	@override String imageNotImage({required Object path}) => 'Kein Bild: ${path}';
	@override String imageUnsupported({required Object path, required Object size}) => '${path} (${size}) hat ein Format, das diese App nicht anzeigen kann';
	@override String imageTooLarge({required Object path, required Object size}) => '${path} (${size}) ist zu groß, um einzeln geladen zu werden';
	@override String imageFailed({required Object path, required Object error}) => '${path} konnte nicht geladen werden: ${error}';
	@override String loadOriginal({required Object size}) => 'Original laden (${size})';
	@override String get retryImage => 'Wiederholen';
	@override String imagePreview({required Object sent, required Object size}) => 'Vorschau, ${sent} von ${size}';
	@override String get openInFiles => 'In Dateien öffnen';
	@override String showMoreLines({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'Noch ${n} Zeile anzeigen',
		other: 'Noch ${n} Zeilen anzeigen',
	);
	@override String get showLess => 'Weniger anzeigen';
	@override late final _Translations$transcript$tool$de tool = _Translations$transcript$tool$de._(_root);
	@override late final _Translations$transcript$execution$de execution = _Translations$transcript$execution$de._(_root);
	@override String get compacted => 'Kontext kompaktiert';
	@override String compactedTokens({required Object before, required Object after}) => '${before} → ${after} Tokens';
	@override String compactedFrom({required Object before}) => 'von ${before} Tokens';
	@override String get showSummary => 'Zusammenfassung anzeigen';
	@override String get hideSummary => 'Zusammenfassung ausblenden';
	@override String showAll({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'Alle anzeigen (${n} Zeile)',
		other: 'Alle anzeigen (${n} Zeilen)',
	);
	@override String get branchSummary => 'Zusammenfassung des verlassenen Abzweigs';
	@override String get summaryFiles => 'Dateien';
	@override String get fileRead => 'gelesen';
	@override String get fileWritten => 'geschrieben';
	@override String get fileReadWritten => 'gelesen und geschrieben';
	@override String filesElided({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'Noch ${n} Datei',
		other: 'Noch ${n} Dateien',
	);
	@override String modelChange({required Object model}) => 'Modell: ${model}';
	@override String modelRoleChange({required Object role, required Object model}) => 'Modell (${role}): ${model}';
	@override String thinkingLevel({required Object level}) => 'Denken: ${level}';
	@override String get thinkingOff => 'Denken: aus';
	@override String rulesApplied({required num n, required Object rules}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: 'Regel angewendet: ${rules}',
		other: '${n} Regeln angewendet: ${rules}',
	);
	@override String mentionedFiles({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Datei angehängt',
		other: '${n} Dateien angehängt',
	);
	@override String get skippedTooLarge => 'zu groß';
	@override String get skippedBinary => 'binär';
	@override String get backgroundResult => 'Ergebnis aus dem Hintergrund';
	@override String get delegated => 'Weitergeleitete Anfrage';
	@override late final _Translations$transcript$turn$de turn = _Translations$transcript$turn$de._(_root);
}

// Path: config
class _Translations$config$de extends Translations$config$en {
	_Translations$config$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String title({required Object machine}) => '${machine} konfigurieren';
	@override String get connect => 'Verbinden';
	@override String get connecting => 'Verbinde…';
	@override String needsOmp({required Object reason}) => 'omp muss auf diesem Rechner installiert oder aktualisiert werden: ${reason}';
	@override String get refresh => 'Aktualisieren';
	@override String get noOutput => '(keine Ausgabe)';
	@override late final _Translations$config$sections$de sections = _Translations$config$sections$de._(_root);
	@override late final _Translations$config$scope$de scope = _Translations$config$scope$de._(_root);
	@override late final _Translations$config$provenance$de provenance = _Translations$config$provenance$de._(_root);
	@override late final _Translations$config$settings$de settings = _Translations$config$settings$de._(_root);
	@override late final _Translations$config$roles$de roles = _Translations$config$roles$de._(_root);
	@override late final _Translations$config$accounts$de accounts = _Translations$config$accounts$de._(_root);
	@override late final _Translations$config$mcp$de mcp = _Translations$config$mcp$de._(_root);
	@override late final _Translations$config$plugins$de plugins = _Translations$config$plugins$de._(_root);
	@override late final _Translations$config$skills$de skills = _Translations$config$skills$de._(_root);
	@override late final _Translations$config$stats$de stats = _Translations$config$stats$de._(_root);
}

// Path: usage.units
class _Translations$usage$units$de extends Translations$usage$units$en {
	_Translations$usage$units$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String tokens({required Object value}) => '${value} Tokens';
	@override String requests({required Object value}) => '${value} Anfragen';
	@override String credits({required Object value}) => '${value} Credits';
	@override String minutes({required Object value}) => '${value} min';
	@override String bytes({required Object value}) => '${value} Bytes';
}

// Path: usage.tabs
class _Translations$usage$tabs$de extends Translations$usage$tabs$en {
	_Translations$usage$tabs$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get limits => 'Limits';
	@override String get stats => 'Statistik';
}

// Path: usage.stats
class _Translations$usage$stats$de extends Translations$usage$stats$en {
	_Translations$usage$stats$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get reading => 'Sitzungsdateien werden gelesen…';
	@override String scanned({required Object files, required Object size, required Object time}) => '${files} Sitzungsdateien · ${size} · ${time}';
	@override String unreadable({required num n, required Object error}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Datei konnte nicht gelesen werden: ${error}',
		other: '${n} Dateien konnten nicht gelesen werden: ${error}',
	);
	@override String get allMachines => 'Alle Rechner';
	@override String get machineFilter => 'Rechner';
	@override late final _Translations$usage$stats$ranges$de ranges = _Translations$usage$stats$ranges$de._(_root);
	@override String get none => 'Noch keine Modellanfragen in einer Sitzungsdatei.';
	@override String get requests => 'Anfragen';
	@override String get tokens => 'Tokens';
	@override String get cost => 'Kosten';
	@override String get sessions => 'Sitzungen';
	@override String get currentStreak => 'Aktuelle Serie';
	@override String get longestStreak => 'Längste Serie';
	@override String get activeDays => 'Aktive Tage';
	@override String get speed => 'Geschwindigkeit';
	@override String failed({required Object n, required Object percent}) => '${n} fehlgeschlagen (${percent})';
	@override String fromCache({required Object percent}) => '${percent} aus dem Cache gelesen';
	@override String perActiveDay({required Object cost}) => '${cost} pro aktivem Tag';
	@override String prompts({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${count} Prompt',
		other: '${count} Prompts',
	);
	@override String days({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Tag',
		other: '${n} Tage',
	);
	@override String since({required Object date}) => 'seit ${date}';
	@override String span({required Object from, required Object to}) => '${from} – ${to}';
	@override String ofDays({required Object n}) => 'von ${n} Tagen';
	@override String get noStreak => 'noch keine';
	@override String ttft({required Object ms}) => '${ms} ms bis zum ersten Token';
	@override String tokensPerSecond({required Object n}) => '${n} Tok./s';
	@override String heatmap({required Object tokens, required Object period}) => '${tokens} Tokens · ${period}';
	@override String get lastYear => 'letzte 12 Monate';
	@override String get lastYearOption => 'Letzte 12 Monate';
	@override String get less => 'Weniger';
	@override String get more => 'Mehr';
	@override String requestCount({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${count} Anfrage',
		other: '${count} Anfragen',
	);
	@override String tokenCount({required Object tokens}) => '${tokens} Tokens';
	@override String busiestDay({required Object date, required Object tokens}) => 'Aktivster Tag: ${date}, ${tokens}';
	@override String get activity => 'Aktivität';
	@override late final _Translations$usage$stats$metrics$de metrics = _Translations$usage$stats$metrics$de._(_root);
	@override String weekOf({required Object date}) => 'Woche vom ${date}';
	@override String monthOf({required Object month, required Object year}) => '${month} ${year}';
	@override String get models => 'Modelle';
	@override String get weekHours => 'Woche nach Stunde';
	@override String hourSpan({required Object weekday, required Object from, required Object to}) => '${weekday} ${from}:00–${to}:00';
	@override String busiestHour({required Object hour}) => 'Aktivste Stunde: ${hour}';
	@override String get tokenKinds => 'Tokens nach Art';
	@override String get input => 'Eingabe';
	@override String get output => 'Ausgabe';
	@override String get cacheRead => 'Cache gelesen';
	@override String get cacheWrite => 'Cache geschrieben';
	@override String get agents => 'Agenten';
	@override String get mainSessions => 'Hauptsitzungen';
	@override String get subagents => 'Subagenten';
	@override String get advisor => 'Berater';
	@override String get projects => 'Projekte';
	@override String get noProject => '(kein Projekt)';
	@override String get tools => 'Tools';
	@override String callCount({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${count} Aufruf',
		other: '${count} Aufrufe',
	);
	@override String toolErrors({required Object n}) => '${n} fehlgeschlagen';
	@override String get machines => 'Rechner';
	@override String get promptSection => 'Deine Prompts';
	@override String get promptsTitle => 'Prompts';
	@override String promptsPerDay({required Object n}) => '${n} pro aktivem Tag';
	@override String get words => 'Wörter';
	@override String perPrompt({required Object n}) => '${n} pro Prompt';
	@override String get questions => 'Fragen';
	@override String askedSomething({required Object count}) => '${count} mit einer Frage';
	@override String get longestPrompt => 'Längster Prompt';
	@override String wordCount({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${count} Wort',
		other: '${count} Wörter',
	);
	@override String get cloud => 'Deine häufigsten Wörter';
	@override String get cloudNote => 'Größe nach den Prompts, die sie verwenden; häufige Wörter ausgelassen';
	@override String wordUse({required num n, required Object word, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${word}: ${count} Prompt',
		other: '${word}: ${count} Prompts',
	);
	@override String get noPrompts => 'Keine Prompts in diesem Zeitraum.';
	@override String get promptLength => 'Prompt-Länge';
	@override String lengthUpTo({required Object n}) => '≤${n}';
	@override String lengthBetween({required Object from, required Object to}) => '${from}–${to}';
	@override String lengthOver({required Object n}) => '${n}+';
	@override String lengthDetail({required Object length, required Object prompts, required Object percent}) => '${length} Wörter: ${prompts} (${percent})';
	@override String get promptHours => 'Wann du tippst';
	@override String get wordsTyped => 'Getippte Wörter';
	@override String get tone => 'Tonfall';
	@override String get toneNote => 'Treffer pro 100 Prompts, nach den Statistikregeln von omp';
	@override String get yelling => 'Schreien';
	@override String get profanity => 'Fluchen';
	@override String get anguish => 'Verzweiflung';
	@override String get negation => 'Korrigieren';
	@override String get repetition => 'Wiederholen';
	@override String get blame => 'Agenten beschuldigen';
	@override List<String> get weekdays => [
		'Mo',
		'Di',
		'Mi',
		'Do',
		'Fr',
		'Sa',
		'So',
	];
	@override List<String> get months => [
		'Jan',
		'Feb',
		'Mär',
		'Apr',
		'Mai',
		'Jun',
		'Jul',
		'Aug',
		'Sep',
		'Okt',
		'Nov',
		'Dez',
	];
	@override String date({required Object weekday, required Object day, required Object month, required Object year}) => '${weekday}, ${day}. ${month} ${year}';
	@override String shortDate({required Object day, required Object month}) => '${day}. ${month}';
}

// Path: dock.todo
class _Translations$dock$todo$de extends Translations$dock$todo$en {
	_Translations$dock$todo$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get empty => 'Noch keine Aufgaben. Die Aufgabenliste des Agenten erscheint hier.';
	@override String progress({required Object done, required Object total}) => '${done}/${total}';
	@override String get pending => 'Ausstehend';
	@override String get inProgress => 'In Arbeit';
	@override String get completed => 'Abgeschlossen';
	@override String get abandoned => 'Verworfen';
	@override String get blocked => 'Blockiert';
	@override String blockedBy({required Object reason}) => 'Blockiert: ${reason}';
}

// Path: dock.hub
class _Translations$dock$hub$de extends Translations$dock$hub$en {
	_Translations$dock$hub$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get empty => 'Noch keine Subagenten. Agenten, die die Sitzung startet, erscheinen hier.';
	@override String summary({required Object count, required Object running}) => 'Agenten: ${count} · laufend: ${running}';
	@override String get showList => 'Als Liste anzeigen';
	@override String get showTree => 'Als Baum anzeigen';
	@override String get active => 'Aktiv';
	@override String get inactive => 'Inaktiv';
	@override String get advisor => 'Berater';
	@override String tokens({required Object count}) => '${count} Tok';
	@override String tools({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Tool',
		other: '${n} Tools',
	);
	@override String context({required Object percent}) => 'Kontext ${percent} %';
	@override late final _Translations$dock$hub$status$de status = _Translations$dock$hub$status$de._(_root);
	@override String get back => 'Zurück zu den Agenten';
	@override String get actions => 'Agent-Aktionen';
	@override String get revive => 'Wiederbeleben';
	@override String get revived => 'Agent wiederbelebt.';
	@override String get kill => 'Beenden';
	@override String get killed => 'Agent beendet.';
	@override String killTitle({required Object name}) => '${name} beenden?';
	@override String get killBody => 'Der laufende Durchlauf wird abgebrochen und der Agent freigegeben.';
	@override String get copyId => 'Agent-ID kopieren';
	@override String get steer => 'Senden';
	@override String get steered => 'An den Agenten gesendet.';
	@override String get steerHint => 'Nachricht an diesen Agenten…';
	@override String get steerParkedHint => 'Nachricht weckt diesen geparkten Agenten…';
	@override String get advisorReadOnly => 'Berater sind schreibgeschützt.';
	@override String get noTranscript => 'Noch kein Verlauf.';
	@override String transcriptFailed({required Object error}) => 'Verlauf nicht verfügbar: ${error}';
	@override String failed({required Object error}) => 'Fehlgeschlagen: ${error}';
	@override String get noCompanion => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind Nachrichten, Beenden und Wiederbeleben von Agenten nicht verfügbar.';
	@override String durationHours({required Object hours, required Object minutes}) => '${hours} h ${minutes} min';
	@override String durationMinutes({required Object minutes, required Object seconds}) => '${minutes} min ${seconds} s';
	@override String durationSeconds({required Object seconds}) => '${seconds} s';
}

// Path: dock.sessionTree
class _Translations$dock$sessionTree$de extends Translations$dock$sessionTree$en {
	_Translations$dock$sessionTree$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get search => 'Einträge durchsuchen';
	@override String get filter => 'Filter';
	@override String get filterStandard => 'Unterhaltung';
	@override String get filterNoTools => 'Ohne Tool-Ergebnisse';
	@override String get filterUserOnly => 'Deine Nachrichten';
	@override String get filterLabeled => 'Mit Label';
	@override String get filterAll => 'Alles';
	@override String get refresh => 'Aktualisieren';
	@override String loadFailed({required Object error}) => 'Konnte den Baum nicht laden: ${error}';
	@override String get empty => 'Noch keine Einträge.';
	@override String get noMatches => 'Keine Einträge gefunden.';
	@override String get currentLeaf => 'Aktuelle Position';
	@override String get navigate => 'Hierhin springen';
	@override String get navigateWithSummary => 'Hierhin springen mit Zusammenfassung…';
	@override String get label => 'Label…';
	@override String get branch => 'In neue Sitzung abzweigen';
	@override String get copyText => 'Text kopieren';
	@override String get summarizing => 'Der Abzweig, den du verlässt, wird zusammengefasst…';
	@override String get abort => 'Abbrechen';
	@override String get summaryAborted => 'Zusammenfassung abgebrochen. Nichts hat sich geändert.';
	@override String get navigationCancelled => 'Navigation abgebrochen.';
	@override String get branchCancelled => 'Abzweig abgebrochen.';
	@override String get branched => 'In eine neue Sitzung abgezweigt. Die Nachricht ist wieder im Eingabefeld.';
	@override String failed({required Object error}) => 'Fehlgeschlagen: ${error}';
	@override String get aborted => '(abgebrochen)';
	@override String get noContent => '(kein Inhalt)';
	@override String compaction({required Object tokens}) => 'Kompaktierung (${tokens} Tokens)';
	@override String branchSummary({required Object summary}) => 'Abzweig-Zusammenfassung: ${summary}';
	@override String model({required Object model}) => 'Modell: ${model}';
	@override String thinking({required Object level}) => 'Denken: ${level}';
	@override String labelSet({required Object label}) => 'Label: ${label}';
	@override String get labelCleared => 'Label entfernt';
	@override String advisor({required Object notes}) => 'Berater: ${notes}';
	@override String advisorTagged({required Object tags, required Object notes}) => 'Berater (${tags}): ${notes}';
	@override String get summaryTitle => 'Den Abzweig zusammenfassen, den du verlässt';
	@override String get summaryBody => 'omp schreibt am neuen Punkt eine Zusammenfassung des verlassenen Abzweigs. Das löst einen Modellaufruf aus.';
	@override String get summaryInstructions => 'Eigene Anweisungen (optional)';
	@override String get summarize => 'Zusammenfassen und springen';
	@override String get labelTitle => 'Eintrag mit Label versehen';
	@override String get labelField => 'Label';
	@override String get clearLabel => 'Label entfernen';
	@override String get noCompanion => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind das Springen zu einem Eintrag und Labels nicht verfügbar.';
}

// Path: dock.fileBrowser
class _Translations$dock$fileBrowser$de extends Translations$dock$fileBrowser$en {
	_Translations$dock$fileBrowser$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get up => 'Übergeordneter Ordner';
	@override String get refresh => 'Aktualisieren';
	@override String get newFile => 'Neue Datei';
	@override String get newFolder => 'Neuer Ordner';
	@override String get create => 'Erstellen';
	@override String get rename => 'Umbenennen';
	@override String get open => 'Öffnen';
	@override String get browseHere => 'Durchsuchen';
	@override String get copyPath => 'Pfad kopieren';
	@override String get name => 'Name';
	@override String get nameReserved => 'Dieser Name ist reserviert.';
	@override String get nameSeparator => 'Namen dürfen kein / oder \ enthalten.';
	@override String exists({required Object name}) => '${name} existiert bereits.';
	@override String failed({required Object error}) => 'Fehlgeschlagen: ${error}';
	@override String deleteTitle({required Object name}) => '${name} löschen?';
	@override String get deleteFileBody => 'Die Datei wird vom Rechner gelöscht.';
	@override String get deleteFolderBody => 'Der Ordner und alles darin werden vom Rechner gelöscht.';
	@override String get deleteLinkBody => 'Der symbolische Link wird vom Rechner gelöscht. Worauf er zeigt, bleibt.';
	@override String get link => 'Symbolischer Link';
	@override String get emptyFolder => 'Leerer Ordner';
	@override String listFailed({required Object error}) => 'Konnte nicht auflisten: ${error}';
	@override String openDocuments({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} geöffnete Datei',
		other: '${n} geöffnete Dateien',
	);
	@override String openFailed({required Object error}) => 'Konnte nicht öffnen: ${error}';
	@override String get backToFiles => 'Zurück zu den Dateien';
	@override String get save => 'Speichern';
	@override String saved({required Object name}) => '${name} gespeichert.';
	@override String saveFailed({required Object error}) => 'Speichern fehlgeschlagen: ${error}';
	@override String get more => 'Mehr';
	@override String get find => 'Suchen';
	@override String get reload => 'Vom Datenträger neu laden';
	@override String get showDiff => 'git diff anzeigen';
	@override String get showFile => 'Datei anzeigen';
	@override String get conflictTitle => 'Datei auf dem Rechner geändert';
	@override String get conflictChanged => 'Die Datei wurde auf dem Rechner geändert, seit du sie geöffnet hast. Mit deiner Version überschreiben oder deine Änderungen verwerfen und neu laden?';
	@override String get conflictDeleted => 'Die Datei wurde auf dem Rechner gelöscht, seit du sie geöffnet hast. Überschreiben legt sie neu an.';
	@override String get overwrite => 'Überschreiben';
	@override String get discardAndReload => 'Verwerfen und neu laden';
	@override String discardTitle({required Object name}) => 'Änderungen an ${name} verwerfen?';
	@override String get discardBody => 'Deine ungespeicherten Änderungen gehen verloren.';
	@override String get discard => 'Verwerfen';
	@override String tooLarge({required Object mb}) => 'Größer als ${mb} MB: der Anfang wird schreibgeschützt angezeigt.';
	@override String get binary => 'Binärdatei. Wird nicht angezeigt.';
	@override String get notUtf8 => 'Kein UTF-8-Text: schreibgeschützt, damit Speichern nichts beschädigen kann.';
	@override String get noMatches => 'Keine Treffer';
	@override String get replace => 'Ersetzen';
	@override String get replaceAll => 'Alle ersetzen';
	@override String get caseSensitive => 'Groß-/Kleinschreibung beachten';
	@override String get previousMatch => 'Vorheriger Treffer';
	@override String get nextMatch => 'Nächster Treffer';
	@override String get noChanges => 'Keine Änderungen gegenüber HEAD.';
	@override String diffFailed({required Object error}) => 'git diff fehlgeschlagen: ${error}';
	@override String diffTruncated({required Object shown, required Object total}) => 'Zeige ${shown} von ${total} Diff-Zeilen.';
	@override late final _Translations$dock$fileBrowser$git$de git = _Translations$dock$fileBrowser$git$de._(_root);
}

// Path: dock.terminals
class _Translations$dock$terminals$de extends Translations$dock$terminals$en {
	_Translations$dock$terminals$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get newTerminal => 'Neues Terminal';
	@override String empty({required Object machine}) => 'Kein Terminal auf ${machine} geöffnet.';
	@override String get close => 'Schließen';
	@override String get restart => 'Neu starten';
	@override String get smaller => 'Kleinerer Text';
	@override String get larger => 'Größerer Text';
	@override String get paste => 'Einfügen';
	@override String get selectAll => 'Alles auswählen';
	@override String get clear => 'Leeren';
	@override String failed({required Object error}) => 'Terminal fehlgeschlagen: ${error}';
	@override String exited({required Object code}) => 'Die Shell wurde mit Code ${code} beendet.';
	@override String get exitedBySignal => 'Die Shell wurde beendet.';
}

// Path: themeEditor.preview
class _Translations$themeEditor$preview$de extends Translations$themeEditor$preview$en {
	_Translations$themeEditor$preview$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get session => 'Eine Sitzung';
	@override String get selected => 'Die ausgewählte Sitzung';
	@override String get text => 'Text auf dem Hintergrund';
	@override String get muted => 'Gedämpfter Text';
	@override String get field => 'Ein Textfeld';
	@override String get secondary => 'Sekundär';
	@override String get primary => 'Primär';
	@override String get menuItem => 'Ein Menüeintrag';
	@override String get done => 'Fertig';
	@override String get paused => 'Pausiert';
	@override String get failed => 'Fehlgeschlagen';
	@override String get working => 'Läuft';
	@override String get error => 'Etwas ist schiefgelaufen';
}

// Path: goal.status
class _Translations$goal$status$de extends Translations$goal$status$en {
	_Translations$goal$status$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get active => 'Aktiv';
	@override String get paused => 'Pausiert';
	@override String get budgetLimited => 'Budget erreicht';
	@override String get complete => 'Abgeschlossen';
	@override String get dropped => 'Verworfen';
}

// Path: transcript.tool
class _Translations$transcript$tool$de extends Translations$transcript$tool$en {
	_Translations$transcript$tool$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get running => 'Läuft…';
	@override String get background => 'Läuft im Hintergrund';
	@override String get interrupted => 'Nicht abgeschlossen';
	@override String get error => 'Fehler';
	@override String get arguments => 'Argumente';
	@override String get noOutput => 'Keine Ausgabe';
	@override String exitCode({required Object code}) => 'Exit ${code}';
	@override String get timedOut => 'Zeitüberschreitung';
	@override String lines({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Zeile',
		other: '${n} Zeilen',
	);
	@override String lineRange({required Object from, required Object to}) => 'Zeilen ${from}–${to}';
	@override String get openFile => 'Datei öffnen';
	@override String get created => 'Erstellt';
	@override String get deleted => 'Gelöscht';
	@override String movedTo({required Object path}) => 'Verschoben nach ${path}';
	@override String get noChanges => 'Keine Änderungen';
	@override String todoProgress({required Object done, required Object total}) => '${done} von ${total} erledigt';
	@override String agents({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Agent',
		other: '${n} Agenten',
	);
	@override String get openAgent => 'Agenten öffnen';
	@override String get agentPending => 'Ausstehend';
	@override String get agentRunning => 'Läuft';
	@override String get agentCompleted => 'Fertig';
	@override String get agentFailed => 'Fehlgeschlagen';
	@override String get agentAborted => 'Abgebrochen';
	@override String get askWaiting => 'Wartet unten auf deine Antwort';
	@override String get recommended => 'Empfohlen';
	@override String get cancelled => 'Abgebrochen';
	@override String note({required Object note}) => 'Hinweis: ${note}';
	@override String get autoSelected => 'Nach der Zeitüberschreitung automatisch gewählt';
	@override String sources({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Quelle',
		other: '${n} Quellen',
	);
	@override String get output => 'Ausgabe';
	@override String get context => 'Kontext';
	@override String get diagnostics => 'Diagnose';
	@override String redirectedTo({required Object url}) => 'Weitergeleitet zu ${url}';
	@override String tokens({required Object count}) => '${count} Tokens';
	@override String get goalSet => 'setzen';
	@override String get goalCheck => 'prüfen';
	@override String get goalComplete => 'abschließen';
	@override String get goalResume => 'fortsetzen';
	@override String get goalDrop => 'verwerfen';
	@override String get goalNone => 'kein aktives Ziel';
	@override String goalElapsed({required Object time}) => '${time} vergangen';
	@override String get report => 'Bericht';
}

// Path: transcript.execution
class _Translations$transcript$execution$de extends Translations$transcript$execution$en {
	_Translations$transcript$execution$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get notSent => 'Nicht an das Modell gesendet';
	@override String get cancelled => 'Abgebrochen';
	@override String get truncated => 'Ausgabe gekürzt';
}

// Path: transcript.turn
class _Translations$transcript$turn$de extends Translations$transcript$turn$en {
	_Translations$transcript$turn$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String workedFor({required Object duration}) => '${duration} gearbeitet';
	@override String get worked => 'Gearbeitet';
	@override String toolCalls({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Tool-Aufruf',
		other: '${n} Tool-Aufrufe',
	);
	@override String filesEdited({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n,
		one: '${n} Datei bearbeitet',
		other: '${n} Dateien bearbeitet',
	);
	@override String durationHours({required Object hours, required Object minutes}) => '${hours} h ${minutes} min';
	@override String durationMinutes({required Object minutes, required Object seconds}) => '${minutes} min ${seconds} s';
	@override String durationSeconds({required Object seconds}) => '${seconds} s';
}

// Path: config.sections
class _Translations$config$sections$de extends Translations$config$sections$en {
	_Translations$config$sections$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get settings => 'Einstellungen';
	@override String get roles => 'Modellrollen';
	@override String get accounts => 'Anbieter';
	@override String get mcp => 'MCP-Server';
	@override String get plugins => 'Plugins';
	@override String get skills => 'Skills';
	@override String get stats => 'Statistik';
}

// Path: config.scope
class _Translations$config$scope$de extends Translations$config$scope$en {
	_Translations$config$scope$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get global => 'Global';
	@override String get project => 'Projekt';
	@override String get projectNone => 'Öffne eine Sitzung auf diesem Rechner, um die Projekteinstellungen zu bearbeiten.';
}

// Path: config.provenance
class _Translations$config$provenance$de extends Translations$config$provenance$en {
	_Translations$config$provenance$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String env({required Object name}) => 'env ${name}';
	@override String envHint({required Object name}) => 'Die Umgebungsvariable ${name} überschreibt die Dateien.';
	@override String get runtime => 'Override';
	@override String get runtimeHint => 'Nur für diesen omp-Prozess gesetzt (RPC-Modus oder ein Laufzeit-Override); die Sitzungen der App nutzen ihn.';
	@override String get overlay => 'App-Overlay';
	@override String get overlayHint => 'Erzwungen durch das sitzungsbezogene Konfigurations-Overlay der App.';
	@override String get project => 'Projekt';
	@override String get projectHint => 'Aus .omp/config.yml des Projekts.';
	@override String get global => 'global';
	@override String get globalHint => 'Aus config.yml des Profils.';
	@override String get defaults => 'Standard';
	@override String get defaultsHint => 'omp-Standard; keine Datei setzt ihn.';
}

// Path: config.settings
class _Translations$config$settings$de extends Translations$config$settings$en {
	_Translations$config$settings$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get search => 'Einstellungen durchsuchen';
	@override String editing({required Object path}) => 'Bearbeite ${path}';
	@override String get advancedTab => 'Nur Konfigurationsdatei';
	@override String get advancedNote => 'Einstellungen ohne Zeile im Einstellungs-Panel von omp, gruppiert nach ihrem ersten Schlüssel.';
	@override String get themeNote => 'Dies sind die Terminal-UI-Einstellungen von omp. Das Aussehen der App folgt den App-Einstellungen.';
	@override String get noMatches => 'Keine Einstellung passt.';
	@override String get reset => 'Auf den geerbten Wert zurücksetzen';
	@override String get unset => 'nicht gesetzt';
	@override String get presets => 'Vorgeschlagene Werte';
	@override String get notANumber => 'Keine Zahl';
	@override String notJson({required Object error}) => 'Kein JSON: ${error}';
	@override String get expectedObject => 'JSON-Objekt erwartet';
	@override String get expectedArray => 'JSON-Array erwartet';
	@override String get secretSet => 'Konfiguriert';
	@override String get secretUnset => 'Nicht gesetzt';
	@override String get secretEdit => 'Festlegen…';
	@override String get secretHelp => 'Wird dem Rechner als private Datei gesendet, die omp liest und löscht; nie angezeigt oder protokolliert.';
	@override String get secretGlobalOnly => 'Zugangsdaten werden nur in der globalen Konfiguration gespeichert.';
	@override String get addItem => 'Hinzufügen';
	@override String overriddenLine({required Object value}) => 'Wirksam: ${value} (eine höhere Ebene gewinnt)';
	@override String fileError({required Object path, required Object error}) => '${path} konnte nicht gelesen werden: ${error}';
}

// Path: config.roles
class _Translations$config$roles$de extends Translations$config$roles$en {
	_Translations$config$roles$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String storage({required Object storage}) => 'Die Modellauswahl von omp speichert Rollen in: ${storage}';
	@override String projectIs({required Object path}) => 'Projekt: ${path}';
	@override String get noProject => 'Öffne eine Sitzung auf diesem Rechner, um Projektrollen zuzuweisen.';
	@override String get refreshModels => 'Modelle aktualisieren';
	@override String get modelsRefreshed => 'Modellliste aktualisiert.';
	@override String get chatRoles => 'Chat-Rollen';
	@override String get kindRoles => 'Aufgabenarten';
	@override String get effective => 'Wirksam';
	@override String get projectLayer => 'Projekt';
	@override String get auto => 'auto';
	@override String get assign => 'Festlegen';
	@override String get clear => 'Entfernen';
	@override String pickTitle({required Object role}) => 'Modell für ${role}';
	@override String get searchModels => 'Modelle durchsuchen';
	@override String get thinking => 'Denkstufe';
	@override String get thinkingDefault => 'Modell-Standard';
	@override String useTyped({required Object selector}) => '${selector} verwenden';
	@override String get useTypedHint => 'Ein Modell, das omp hier nicht als verfügbar listet';
	@override String context({required Object tokens}) => '${tokens} Kontext';
	@override String get vision => 'Bilder';
	@override String get noModels => 'Kein Modell passt.';
}

// Path: config.accounts
class _Translations$config$accounts$de extends Translations$config$accounts$en {
	_Translations$config$accounts$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get machineWide => 'Zugangsdaten werden pro Rechner gespeichert.';
	@override String sessionView({required Object path}) => 'Die Markierungen "in Nutzung" und "angeheftet" beziehen sich auf die Sitzung in ${path}.';
	@override String get active => 'in Nutzung';
	@override String get sticky => 'angeheftet';
	@override String expires({required Object date}) => 'läuft ab am ${date}';
	@override String get pin => 'An Sitzung anheften';
	@override String get pinned => 'Konto an die Sitzung angeheftet.';
	@override String get logout => 'Abmelden';
	@override String logoutTitle({required Object account}) => '${account} abmelden?';
	@override String logoutBody({required Object provider}) => 'Die gespeicherten Zugangsdaten für ${provider} werden von diesem Rechner entfernt.';
	@override String get oauthLocal => 'Der Browser öffnet sich auf diesem Computer.';
	@override String get oauthRemote => 'Der Browser öffnet sich auf diesem Gerät; die App leitet den Callback-Port von omp an den Rechner weiter.';
	@override String get saveKey => 'Schlüssel speichern';
	@override String keyStored({required Object provider}) => 'Schlüssel für ${provider} gespeichert.';
	@override String loginTitle({required Object provider}) => 'Bei ${provider} anmelden';
	@override String get waitingForLink => 'Warte auf den Autorisierungslink von omp…';
	@override String get openLink => 'Öffne diesen Link und melde dich an:';
	@override String get openBrowser => 'Browser öffnen';
	@override String get copyLink => 'Link kopieren';
	@override String forwarding({required Object ports}) => 'Lokaler Port ${ports} wird für den Callback an den Rechner weitergeleitet.';
	@override String forwardFailed({required Object port, required Object error}) => 'Port ${port} konnte nicht weitergeleitet werden (${error}). Füge die Redirect-URL ein, wenn omp danach fragt.';
	@override String get submit => 'Absenden';
	@override String get yes => 'Ja';
	@override String get no => 'Nein';
	@override String get loggedIn => 'Angemeldet.';
	@override String get bootstrap => 'Auf diesem Rechner funktioniert noch kein Modell. Melde dich mit einem Konto an oder füge einen API-Schlüssel hinzu; Einstellungen und Rollen funktionieren in der Zwischenzeit.';
	@override String get search => 'Anbieter durchsuchen';
	@override String get noMatches => 'Kein Anbieter passt.';
	@override String get signedIn => 'angemeldet';
	@override String get signIn => 'Anmelden';
	@override String get keyHint => 'API-Schlüssel einfügen';
	@override String get other => 'Anderer Anbieter…';
	@override String get otherId => 'Anbieter-ID';
	@override String get otherNote => 'Speichert einen Schlüssel unter einer Anbieter-ID, die diese Liste nicht zeigt, so wie models.yml oder eine Erweiterung sie nennt.';
	@override late final _Translations$config$accounts$kind$de kind = _Translations$config$accounts$kind$de._(_root);
	@override late final _Translations$config$accounts$source$de source = _Translations$config$accounts$source$de._(_root);
	@override late final _Translations$config$accounts$overridden$de overridden = _Translations$config$accounts$overridden$de._(_root);
}

// Path: config.mcp
class _Translations$config$mcp$de extends Translations$config$mcp$en {
	_Translations$config$mcp$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String userFile({required Object path}) => 'Benutzer: ${path}';
	@override String projectFile({required Object path}) => 'Projekt: ${path}';
	@override String get add => 'Server hinzufügen';
	@override String get addTitle => 'MCP-Server hinzufügen';
	@override String get reload => 'Neu laden';
	@override String get resources => 'Ressourcen';
	@override String get prompts => 'Prompts';
	@override String get smithery => 'Smithery durchsuchen';
	@override String get none => 'Keine MCP-Server konfiguriert.';
	@override String get userScope => 'Benutzer';
	@override String get projectScope => 'Projekt';
	@override String get test => 'Testen';
	@override String removeTitle({required Object name}) => '${name} entfernen?';
	@override String removeBody({required Object scope}) => 'Der Server wird aus der mcp.json im Bereich ${scope} entfernt.';
	@override String get name => 'Name';
	@override String get nameTooLong => 'Höchstens 100 Zeichen';
	@override String get nameInvalid => 'Nur Buchstaben, Ziffern, - _ . : und einzelne Leerzeichen';
	@override String get command => 'Befehl';
	@override String get url => 'URL';
	@override String get token => 'Bearer-Token (optional)';
	@override String get tokenHint => 'Wird als Authorization-Header in die Benutzer-mcp.json geschrieben.';
	@override String get tokenUserOnly => 'Nur Server im Benutzerbereich nehmen hier ein Token: eine Projektsitzung würde es in ihrem Laufprotokoll behalten.';
	@override String get tuiOnly => 'omp 18.3.1 bietet reauth, unauth, reconnect und Smithery-Login nur in seiner Terminal-UI.';
	@override String get testDisabled => 'Aktiviere den Server, um ihn zu testen; omp lädt nur aktivierte Server.';
	@override String get smitheryTitle => 'Smithery-Registry';
}

// Path: config.plugins
class _Translations$config$plugins$de extends Translations$config$plugins$en {
	_Translations$config$plugins$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String inProject({required Object path}) => 'Befehle laufen in ${path}';
	@override String get installed => 'Installiert';
	@override String get none => 'Keine Plugins installiert.';
	@override String get npm => 'npm';
	@override String get uninstall => 'Deinstallieren';
	@override String get upgrade => 'Upgraden';
	@override String get update => 'Aktualisieren';
	@override String marketplaceScope({required Object scope}) => 'Marktplatz · ${scope}';
	@override String get shadowed => 'verdeckt';
	@override String get install => 'Installieren';
	@override String get installHint => 'Ein npm-Paket, name@marketplace, github:user/repo, eine Git-URL oder ein lokaler Pfad. npm-Installationen brauchen bun auf dem Rechner.';
	@override String get installPlaceholder => '@oh-my-pi/exa';
	@override String get installAction => 'Installieren';
	@override String get marketplaces => 'Marktplätze';
	@override String get updateAll => 'Alle aktualisieren';
	@override String get noMarketplaces => 'Keine Marktplätze konfiguriert.';
	@override String get isInstalled => 'installiert';
	@override String get sourcePlaceholder => 'owner/repo, Git-URL oder lokaler Pfad';
	@override String get addMarketplace => 'Marktplatz hinzufügen';
}

// Path: config.skills
class _Translations$config$skills$de extends Translations$config$skills$en {
	_Translations$config$skills$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get registry => 'Registry-Skills von skills.omp.sh';
	@override String get installed => 'Installiert';
	@override String get none => 'Keine Registry-Skills installiert.';
	@override String get notInstalled => 'nicht installiert';
	@override String range({required Object range}) => 'Bereich ${range}';
	@override String get info => 'Info';
	@override String get search => 'Registry durchsuchen';
	@override String get searchHint => 'pdf, git, review…';
	@override String results({required Object shown, required Object total}) => '${shown} von ${total}';
	@override String downloads({required Object number}) => '${number} Downloads pro Woche';
	@override String by({required Object name}) => 'von ${name}';
	@override String deprecated({required Object reason}) => 'Veraltet: ${reason}';
	@override String installWhere({required Object id}) => '${id} installieren für';
	@override String get forUser => 'Alle Projekte (Benutzer)';
	@override String forProject({required Object path}) => 'Dieses Projekt (${path})';
	@override String get scriptsTitle => 'Dieser Skill enthält Skripte';
	@override String get scriptsBody => 'Beim Installieren werden seine Skripte auf dem Rechner ausgeführt. Trotzdem installieren?';
	@override String get installAnyway => 'Trotzdem installieren';
	@override String license({required Object license}) => 'Lizenz: ${license}';
	@override String latest({required Object version}) => 'Neueste: ${version}';
	@override String versions({required Object versions}) => 'Versionen: ${versions}';
	@override String owners({required Object owners}) => 'Eigentümer: ${owners}';
	@override String downloadsTotal({required Object weekly, required Object total}) => 'Downloads: ${weekly} pro Woche, ${total} insgesamt';
	@override String get shipsScripts => 'Enthält Skripte.';
	@override String noHits({required Object query}) => 'Nichts auf skills.omp.sh passt zu "${query}".';
}

// Path: config.stats
class _Translations$config$stats$de extends Translations$config$stats$en {
	_Translations$config$stats$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String span({required Object from, required Object to}) => '${from} – ${to}';
	@override String get none => 'Noch keine Anfragen erfasst.';
	@override String get requests => 'Anfragen';
	@override String get errors => 'Fehler';
	@override String get inputTokens => 'Eingabe-Tokens';
	@override String get outputTokens => 'Ausgabe-Tokens';
	@override String get cacheRead => 'Cache gelesen';
	@override String get cost => 'Kosten';
	@override String get ttft => 'Ø erstes Token';
	@override String get speed => 'Ø Geschwindigkeit';
	@override String tokensPerSecond({required Object n}) => '${n} Tok./s';
	@override String get perHour => 'Anfragen pro Stunde';
	@override String get byModel => 'Nach Modell';
	@override String get byFolder => 'Nach Projekt';
	@override String get byAgent => 'Nach Agent';
	@override String get model => 'Modell';
	@override String get folder => 'Projekt';
	@override String get agent => 'Agent';
}

// Path: usage.stats.ranges
class _Translations$usage$stats$ranges$de extends Translations$usage$stats$ranges$en {
	_Translations$usage$stats$ranges$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get week => '7 Tage';
	@override String get month => '30 Tage';
	@override String get year => 'Jahr';
	@override String get all => 'Gesamter Zeitraum';
}

// Path: usage.stats.metrics
class _Translations$usage$stats$metrics$de extends Translations$usage$stats$metrics$en {
	_Translations$usage$stats$metrics$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get requests => 'Anfragen';
	@override String get tokens => 'Tokens';
	@override String get cost => 'Kosten';
}

// Path: dock.hub.status
class _Translations$dock$hub$status$de extends Translations$dock$hub$status$en {
	_Translations$dock$hub$status$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get running => 'Läuft';
	@override String get pending => 'Ausstehend';
	@override String get idle => 'Leerlauf';
	@override String get parked => 'Geparkt';
	@override String get completed => 'Abgeschlossen';
	@override String get failed => 'Fehlgeschlagen';
	@override String get aborted => 'Beendet';
}

// Path: dock.fileBrowser.git
class _Translations$dock$fileBrowser$git$de extends Translations$dock$fileBrowser$git$en {
	_Translations$dock$fileBrowser$git$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get modified => 'Geändert';
	@override String get added => 'Hinzugefügt';
	@override String get deleted => 'Gelöscht';
	@override String get renamed => 'Umbenannt';
	@override String get copied => 'Kopiert';
	@override String get typeChanged => 'Typ geändert';
	@override String get untracked => 'Nicht verfolgt';
	@override String get ignored => 'Ignoriert';
	@override String get conflicted => 'Konflikt';
}

// Path: config.accounts.kind
class _Translations$config$accounts$kind$de extends Translations$config$accounts$kind$en {
	_Translations$config$accounts$kind$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get account => 'Konto';
	@override String get apiKey => 'API-Schlüssel';
	@override String get local => 'lokal';
}

// Path: config.accounts.source
class _Translations$config$accounts$source$de extends Translations$config$accounts$source$en {
	_Translations$config$accounts$source$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get runtime => 'omp nutzt einen Schlüssel, der nur für diesen omp-Prozess gesetzt ist.';
	@override String get config => 'omp nutzt den Schlüssel, den models.yml setzt.';
	@override String get oauth => 'omp nutzt ein angemeldetes Konto.';
	@override String get apiKey => 'omp nutzt einen gespeicherten API-Schlüssel.';
	@override String env({required Object name}) => 'omp nutzt den Schlüssel in der Umgebungsvariable ${name}.';
	@override String get working => 'omp hat funktionierende Zugangsdaten für diesen Anbieter.';
	@override String get none => 'Nicht angemeldet.';
	@override String get noKey => 'Kein Schlüssel gespeichert.';
}

// Path: config.accounts.overridden
class _Translations$config$accounts$overridden$de extends Translations$config$accounts$overridden$en {
	_Translations$config$accounts$overridden$de._(TranslationsDe root) : this._root = root, super.internal(root);

	final TranslationsDe _root; // ignore: unused_field

	// Translations
	@override String get config => 'models.yml setzt einen Schlüssel für diesen Anbieter, daher nutzt omp diesen und nicht den gespeicherten.';
	@override String env({required Object name}) => 'Die Umgebungsvariable ${name} setzt einen Schlüssel, daher nutzt omp diesen und nicht den gespeicherten.';
	@override String get runtime => 'Ein für diesen omp-Prozess gesetzter Schlüssel hat Vorrang vor dem gespeicherten.';
}

/// The flat map containing all translations for locale <de>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on TranslationsDe {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => 'ompanion',
			'common.cancel' => 'Abbrechen',
			'common.close' => 'Schließen',
			'common.save' => 'Speichern',
			'common.delete' => 'Löschen',
			'common.edit' => 'Bearbeiten',
			'common.retry' => 'Wiederholen',
			'common.copy' => 'Kopieren',
			'common.copied' => 'Kopiert',
			'common.continueAction' => 'Fortsetzen',
			'common.required' => 'Erforderlich',
			'common.chooseFile' => 'Datei wählen…',
			'common.cancelled' => 'Abgebrochen.',
			'shell.showSidebar' => 'Seitenleiste einblenden',
			'shell.hideSidebar' => 'Seitenleiste ausblenden',
			'shell.showPanels' => 'Panels einblenden',
			'shell.hidePanels' => 'Panels ausblenden',
			'shell.panels' => 'Panels',
			'shell.homeTitle' => 'Kein Rechner ausgewählt',
			'shell.homeBody' => 'Wähle in der Seitenleiste einen Rechner aus oder füge einen hinzu.',
			'shell.keysTitle' => 'SSH-Schlüssel',
			'shell.usageTitle' => 'Nutzung',
			'shell.settingsTitle' => 'Einstellungen',
			'usage.fetchAgain' => 'Anbieter erneut abfragen',
			'usage.fetched' => ({required Object ago}) => 'Vor ${ago} abgerufen',
			'usage.notFetched' => 'Noch nicht abgerufen',
			'usage.hideIdentities' => 'E-Mails und Organisationen ausblenden',
			'usage.showIdentities' => 'E-Mails und Organisationen anzeigen',
			'usage.none' => 'Keine Nutzungsdaten. Konten von Anbietern mit Nutzungs-Endpunkt (zum Beispiel Claude- und ChatGPT-Abos) zeigen hier ihre Limits.',
			'usage.noMachines' => 'Noch keine Rechner. Füge einen in der Seitenleiste hinzu.',
			'usage.machines' => 'Rechner',
			'usage.asking' => 'omp wird abgefragt…',
			'usage.machineAccounts' => ({required num n, required Object version}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'omp ${version} · ${n} Konto', other: 'omp ${version} · ${n} Konten', ), 
			'usage.providerAccounts' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Konto', other: '${n} Konten', ), 
			'usage.accountN' => ({required Object n}) => 'Konto ${n}',
			'usage.apiKey' => 'API-Schlüssel',
			'usage.oauthAccount' => 'OAuth-Konto',
			'usage.plan' => ({required Object plan}) => 'Tarif: ${plan}',
			'usage.daybreak' => 'Daybreak',
			'usage.savedResets' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} gespeicherter Reset', other: '${n} gespeicherte Resets', ), 
			'usage.usableNow' => ({required Object n}) => '${n} jetzt nutzbar',
			'usage.resetExpiresIn' => ({required Object duration, required Object date}) => 'nächster Ablauf in ${duration} (${date})',
			'usage.resetExpired' => ({required Object date}) => 'abgelaufen (${date})',
			'usage.resetUnavailable' => ({required Object reason}) => 'nicht verfügbar: ${reason}',
			'usage.resetCooldown' => ({required Object time}) => 'Abklingzeit bis ${time}',
			'usage.resetBlocked' => ({required Object windows}) => 'blockiert durch ${windows}',
			'usage.resetNotEligible' => 'nicht berechtigt',
			'usage.resetNotUsable' => 'derzeit nicht nutzbar',
			'usage.fetchedAgo' => ({required Object ago}) => 'vor ${ago} abgerufen',
			'usage.policy' => ({required Object priority, required Object reserve}) => 'Richtlinie: Priorität ${priority} · Reserve ${reserve}',
			'usage.reserveGlobal' => ({required Object percent}) => '${percent} % (global)',
			'usage.reserveOverride' => ({required Object percent}) => '${percent} % (Override)',
			'usage.reserveUnknown' => 'Reserve unbekannt',
			'usage.eligible' => 'berechtigt',
			'usage.insideReserve' => 'innerhalb der Reserve',
			'usage.exhausted' => 'ausgeschöpft',
			'usage.policyOn' => ({required Object line, required Object machine}) => '${line} (${machine})',
			'usage.noLimits' => 'keine Limits gemeldet',
			'usage.notReported' => 'nicht gemeldet',
			'usage.noData' => 'keine Daten',
			'usage.amountOf' => ({required Object used, required Object limit}) => '${used} / ${limit}',
			'usage.amountLeft' => ({required Object amount}) => '${amount} übrig',
			'usage.amountUsed' => ({required Object amount}) => '${amount} verbraucht',
			'usage.percentUsed' => ({required Object percent}) => '${percent} % verbraucht',
			'usage.percentLeft' => ({required Object percent}) => '${percent} % übrig',
			'usage.resets' => 'Reset',
			'usage.resetsIn' => ({required Object verb, required Object duration}) => '${verb} in ${duration}',
			'usage.units.tokens' => ({required Object value}) => '${value} Tokens',
			'usage.units.requests' => ({required Object value}) => '${value} Anfragen',
			'usage.units.credits' => ({required Object value}) => '${value} Credits',
			'usage.units.minutes' => ({required Object value}) => '${value} min',
			'usage.units.bytes' => ({required Object value}) => '${value} Bytes',
			'usage.withoutUsage' => 'keine Nutzungsdaten',
			'usage.disabledAgo' => ({required Object ago, required Object cause}) => 'vor ${ago} deaktiviert: ${cause}',
			'usage.disabled' => ({required Object cause}) => 'deaktiviert: ${cause}',
			'usage.reloginToRestore' => '(erneut anmelden, um wiederherzustellen)',
			'usage.reloginWithin' => ({required Object duration}) => 'innerhalb von ${duration} erneut anmelden (Anthropic lässt OAuth-Grants ~30 Tage nach der Anmeldung ablaufen)',
			'usage.reloginNow' => 'Grant ist älter als die ~30 Tage von Anthropic; melde dich jetzt neu an',
			'usage.capacity' => 'Kapazität',
			'usage.capacityWindow' => ({required num n, required Object used, required Object left}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${used}/${n} Konto genutzt · ${left}× Kontingent übrig', other: '${used}/${n} Konten genutzt · ${left}× Kontingent übrig', ), 
			'usage.tabs.limits' => 'Limits',
			'usage.tabs.stats' => 'Statistik',
			'usage.stats.reading' => 'Sitzungsdateien werden gelesen…',
			'usage.stats.scanned' => ({required Object files, required Object size, required Object time}) => '${files} Sitzungsdateien · ${size} · ${time}',
			'usage.stats.unreadable' => ({required num n, required Object error}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Datei konnte nicht gelesen werden: ${error}', other: '${n} Dateien konnten nicht gelesen werden: ${error}', ), 
			'usage.stats.allMachines' => 'Alle Rechner',
			'usage.stats.machineFilter' => 'Rechner',
			'usage.stats.ranges.week' => '7 Tage',
			'usage.stats.ranges.month' => '30 Tage',
			'usage.stats.ranges.year' => 'Jahr',
			'usage.stats.ranges.all' => 'Gesamter Zeitraum',
			'usage.stats.none' => 'Noch keine Modellanfragen in einer Sitzungsdatei.',
			'usage.stats.requests' => 'Anfragen',
			'usage.stats.tokens' => 'Tokens',
			'usage.stats.cost' => 'Kosten',
			'usage.stats.sessions' => 'Sitzungen',
			'usage.stats.currentStreak' => 'Aktuelle Serie',
			'usage.stats.longestStreak' => 'Längste Serie',
			'usage.stats.activeDays' => 'Aktive Tage',
			'usage.stats.speed' => 'Geschwindigkeit',
			'usage.stats.failed' => ({required Object n, required Object percent}) => '${n} fehlgeschlagen (${percent})',
			'usage.stats.fromCache' => ({required Object percent}) => '${percent} aus dem Cache gelesen',
			'usage.stats.perActiveDay' => ({required Object cost}) => '${cost} pro aktivem Tag',
			'usage.stats.prompts' => ({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${count} Prompt', other: '${count} Prompts', ), 
			'usage.stats.days' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Tag', other: '${n} Tage', ), 
			'usage.stats.since' => ({required Object date}) => 'seit ${date}',
			'usage.stats.span' => ({required Object from, required Object to}) => '${from} – ${to}',
			'usage.stats.ofDays' => ({required Object n}) => 'von ${n} Tagen',
			'usage.stats.noStreak' => 'noch keine',
			'usage.stats.ttft' => ({required Object ms}) => '${ms} ms bis zum ersten Token',
			'usage.stats.tokensPerSecond' => ({required Object n}) => '${n} Tok./s',
			'usage.stats.heatmap' => ({required Object tokens, required Object period}) => '${tokens} Tokens · ${period}',
			'usage.stats.lastYear' => 'letzte 12 Monate',
			'usage.stats.lastYearOption' => 'Letzte 12 Monate',
			'usage.stats.less' => 'Weniger',
			'usage.stats.more' => 'Mehr',
			'usage.stats.requestCount' => ({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${count} Anfrage', other: '${count} Anfragen', ), 
			'usage.stats.tokenCount' => ({required Object tokens}) => '${tokens} Tokens',
			'usage.stats.busiestDay' => ({required Object date, required Object tokens}) => 'Aktivster Tag: ${date}, ${tokens}',
			'usage.stats.activity' => 'Aktivität',
			'usage.stats.metrics.requests' => 'Anfragen',
			'usage.stats.metrics.tokens' => 'Tokens',
			'usage.stats.metrics.cost' => 'Kosten',
			'usage.stats.weekOf' => ({required Object date}) => 'Woche vom ${date}',
			'usage.stats.monthOf' => ({required Object month, required Object year}) => '${month} ${year}',
			'usage.stats.models' => 'Modelle',
			'usage.stats.weekHours' => 'Woche nach Stunde',
			'usage.stats.hourSpan' => ({required Object weekday, required Object from, required Object to}) => '${weekday} ${from}:00–${to}:00',
			'usage.stats.busiestHour' => ({required Object hour}) => 'Aktivste Stunde: ${hour}',
			'usage.stats.tokenKinds' => 'Tokens nach Art',
			'usage.stats.input' => 'Eingabe',
			'usage.stats.output' => 'Ausgabe',
			'usage.stats.cacheRead' => 'Cache gelesen',
			'usage.stats.cacheWrite' => 'Cache geschrieben',
			'usage.stats.agents' => 'Agenten',
			'usage.stats.mainSessions' => 'Hauptsitzungen',
			'usage.stats.subagents' => 'Subagenten',
			'usage.stats.advisor' => 'Berater',
			'usage.stats.projects' => 'Projekte',
			'usage.stats.noProject' => '(kein Projekt)',
			'usage.stats.tools' => 'Tools',
			'usage.stats.callCount' => ({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${count} Aufruf', other: '${count} Aufrufe', ), 
			'usage.stats.toolErrors' => ({required Object n}) => '${n} fehlgeschlagen',
			'usage.stats.machines' => 'Rechner',
			'usage.stats.promptSection' => 'Deine Prompts',
			'usage.stats.promptsTitle' => 'Prompts',
			'usage.stats.promptsPerDay' => ({required Object n}) => '${n} pro aktivem Tag',
			'usage.stats.words' => 'Wörter',
			'usage.stats.perPrompt' => ({required Object n}) => '${n} pro Prompt',
			'usage.stats.questions' => 'Fragen',
			'usage.stats.askedSomething' => ({required Object count}) => '${count} mit einer Frage',
			'usage.stats.longestPrompt' => 'Längster Prompt',
			'usage.stats.wordCount' => ({required num n, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${count} Wort', other: '${count} Wörter', ), 
			'usage.stats.cloud' => 'Deine häufigsten Wörter',
			'usage.stats.cloudNote' => 'Größe nach den Prompts, die sie verwenden; häufige Wörter ausgelassen',
			'usage.stats.wordUse' => ({required num n, required Object word, required Object count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${word}: ${count} Prompt', other: '${word}: ${count} Prompts', ), 
			'usage.stats.noPrompts' => 'Keine Prompts in diesem Zeitraum.',
			'usage.stats.promptLength' => 'Prompt-Länge',
			'usage.stats.lengthUpTo' => ({required Object n}) => '≤${n}',
			'usage.stats.lengthBetween' => ({required Object from, required Object to}) => '${from}–${to}',
			'usage.stats.lengthOver' => ({required Object n}) => '${n}+',
			'usage.stats.lengthDetail' => ({required Object length, required Object prompts, required Object percent}) => '${length} Wörter: ${prompts} (${percent})',
			'usage.stats.promptHours' => 'Wann du tippst',
			'usage.stats.wordsTyped' => 'Getippte Wörter',
			'usage.stats.tone' => 'Tonfall',
			'usage.stats.toneNote' => 'Treffer pro 100 Prompts, nach den Statistikregeln von omp',
			'usage.stats.yelling' => 'Schreien',
			'usage.stats.profanity' => 'Fluchen',
			'usage.stats.anguish' => 'Verzweiflung',
			'usage.stats.negation' => 'Korrigieren',
			'usage.stats.repetition' => 'Wiederholen',
			'usage.stats.blame' => 'Agenten beschuldigen',
			'usage.stats.weekdays.0' => 'Mo',
			'usage.stats.weekdays.1' => 'Di',
			'usage.stats.weekdays.2' => 'Mi',
			'usage.stats.weekdays.3' => 'Do',
			'usage.stats.weekdays.4' => 'Fr',
			'usage.stats.weekdays.5' => 'Sa',
			'usage.stats.weekdays.6' => 'So',
			'usage.stats.months.0' => 'Jan',
			'usage.stats.months.1' => 'Feb',
			'usage.stats.months.2' => 'Mär',
			'usage.stats.months.3' => 'Apr',
			'usage.stats.months.4' => 'Mai',
			'usage.stats.months.5' => 'Jun',
			'usage.stats.months.6' => 'Jul',
			'usage.stats.months.7' => 'Aug',
			'usage.stats.months.8' => 'Sep',
			'usage.stats.months.9' => 'Okt',
			'usage.stats.months.10' => 'Nov',
			'usage.stats.months.11' => 'Dez',
			'usage.stats.date' => ({required Object weekday, required Object day, required Object month, required Object year}) => '${weekday}, ${day}. ${month} ${year}',
			'usage.stats.shortDate' => ({required Object day, required Object month}) => '${day}. ${month}',
			'dock.agents' => 'Agenten',
			'dock.todos' => 'Aufgaben',
			'dock.tree' => 'Baum',
			'dock.files' => 'Dateien',
			'dock.terminal' => 'Terminal',
			'dock.noSession' => 'Öffne eine Sitzung, um dieses Panel zu nutzen.',
			'dock.noMachine' => 'Öffne eine Sitzung oder wähle einen Rechner, um dieses Panel zu nutzen.',
			'dock.todo.empty' => 'Noch keine Aufgaben. Die Aufgabenliste des Agenten erscheint hier.',
			'dock.todo.progress' => ({required Object done, required Object total}) => '${done}/${total}',
			'dock.todo.pending' => 'Ausstehend',
			'dock.todo.inProgress' => 'In Arbeit',
			'dock.todo.completed' => 'Abgeschlossen',
			'dock.todo.abandoned' => 'Verworfen',
			'dock.todo.blocked' => 'Blockiert',
			'dock.todo.blockedBy' => ({required Object reason}) => 'Blockiert: ${reason}',
			'dock.hub.empty' => 'Noch keine Subagenten. Agenten, die die Sitzung startet, erscheinen hier.',
			'dock.hub.summary' => ({required Object count, required Object running}) => 'Agenten: ${count} · laufend: ${running}',
			'dock.hub.showList' => 'Als Liste anzeigen',
			'dock.hub.showTree' => 'Als Baum anzeigen',
			'dock.hub.active' => 'Aktiv',
			'dock.hub.inactive' => 'Inaktiv',
			'dock.hub.advisor' => 'Berater',
			'dock.hub.tokens' => ({required Object count}) => '${count} Tok',
			'dock.hub.tools' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Tool', other: '${n} Tools', ), 
			'dock.hub.context' => ({required Object percent}) => 'Kontext ${percent} %',
			'dock.hub.status.running' => 'Läuft',
			'dock.hub.status.pending' => 'Ausstehend',
			'dock.hub.status.idle' => 'Leerlauf',
			'dock.hub.status.parked' => 'Geparkt',
			'dock.hub.status.completed' => 'Abgeschlossen',
			'dock.hub.status.failed' => 'Fehlgeschlagen',
			'dock.hub.status.aborted' => 'Beendet',
			'dock.hub.back' => 'Zurück zu den Agenten',
			'dock.hub.actions' => 'Agent-Aktionen',
			'dock.hub.revive' => 'Wiederbeleben',
			'dock.hub.revived' => 'Agent wiederbelebt.',
			'dock.hub.kill' => 'Beenden',
			'dock.hub.killed' => 'Agent beendet.',
			'dock.hub.killTitle' => ({required Object name}) => '${name} beenden?',
			'dock.hub.killBody' => 'Der laufende Durchlauf wird abgebrochen und der Agent freigegeben.',
			'dock.hub.copyId' => 'Agent-ID kopieren',
			'dock.hub.steer' => 'Senden',
			'dock.hub.steered' => 'An den Agenten gesendet.',
			'dock.hub.steerHint' => 'Nachricht an diesen Agenten…',
			'dock.hub.steerParkedHint' => 'Nachricht weckt diesen geparkten Agenten…',
			'dock.hub.advisorReadOnly' => 'Berater sind schreibgeschützt.',
			'dock.hub.noTranscript' => 'Noch kein Verlauf.',
			'dock.hub.transcriptFailed' => ({required Object error}) => 'Verlauf nicht verfügbar: ${error}',
			'dock.hub.failed' => ({required Object error}) => 'Fehlgeschlagen: ${error}',
			'dock.hub.noCompanion' => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind Nachrichten, Beenden und Wiederbeleben von Agenten nicht verfügbar.',
			'dock.hub.durationHours' => ({required Object hours, required Object minutes}) => '${hours} h ${minutes} min',
			'dock.hub.durationMinutes' => ({required Object minutes, required Object seconds}) => '${minutes} min ${seconds} s',
			'dock.hub.durationSeconds' => ({required Object seconds}) => '${seconds} s',
			'dock.sessionTree.search' => 'Einträge durchsuchen',
			'dock.sessionTree.filter' => 'Filter',
			'dock.sessionTree.filterStandard' => 'Unterhaltung',
			'dock.sessionTree.filterNoTools' => 'Ohne Tool-Ergebnisse',
			'dock.sessionTree.filterUserOnly' => 'Deine Nachrichten',
			'dock.sessionTree.filterLabeled' => 'Mit Label',
			'dock.sessionTree.filterAll' => 'Alles',
			'dock.sessionTree.refresh' => 'Aktualisieren',
			'dock.sessionTree.loadFailed' => ({required Object error}) => 'Konnte den Baum nicht laden: ${error}',
			'dock.sessionTree.empty' => 'Noch keine Einträge.',
			'dock.sessionTree.noMatches' => 'Keine Einträge gefunden.',
			'dock.sessionTree.currentLeaf' => 'Aktuelle Position',
			'dock.sessionTree.navigate' => 'Hierhin springen',
			'dock.sessionTree.navigateWithSummary' => 'Hierhin springen mit Zusammenfassung…',
			'dock.sessionTree.label' => 'Label…',
			'dock.sessionTree.branch' => 'In neue Sitzung abzweigen',
			'dock.sessionTree.copyText' => 'Text kopieren',
			'dock.sessionTree.summarizing' => 'Der Abzweig, den du verlässt, wird zusammengefasst…',
			'dock.sessionTree.abort' => 'Abbrechen',
			'dock.sessionTree.summaryAborted' => 'Zusammenfassung abgebrochen. Nichts hat sich geändert.',
			'dock.sessionTree.navigationCancelled' => 'Navigation abgebrochen.',
			'dock.sessionTree.branchCancelled' => 'Abzweig abgebrochen.',
			'dock.sessionTree.branched' => 'In eine neue Sitzung abgezweigt. Die Nachricht ist wieder im Eingabefeld.',
			'dock.sessionTree.failed' => ({required Object error}) => 'Fehlgeschlagen: ${error}',
			'dock.sessionTree.aborted' => '(abgebrochen)',
			'dock.sessionTree.noContent' => '(kein Inhalt)',
			'dock.sessionTree.compaction' => ({required Object tokens}) => 'Kompaktierung (${tokens} Tokens)',
			'dock.sessionTree.branchSummary' => ({required Object summary}) => 'Abzweig-Zusammenfassung: ${summary}',
			'dock.sessionTree.model' => ({required Object model}) => 'Modell: ${model}',
			'dock.sessionTree.thinking' => ({required Object level}) => 'Denken: ${level}',
			'dock.sessionTree.labelSet' => ({required Object label}) => 'Label: ${label}',
			'dock.sessionTree.labelCleared' => 'Label entfernt',
			'dock.sessionTree.advisor' => ({required Object notes}) => 'Berater: ${notes}',
			'dock.sessionTree.advisorTagged' => ({required Object tags, required Object notes}) => 'Berater (${tags}): ${notes}',
			'dock.sessionTree.summaryTitle' => 'Den Abzweig zusammenfassen, den du verlässt',
			'dock.sessionTree.summaryBody' => 'omp schreibt am neuen Punkt eine Zusammenfassung des verlassenen Abzweigs. Das löst einen Modellaufruf aus.',
			'dock.sessionTree.summaryInstructions' => 'Eigene Anweisungen (optional)',
			'dock.sessionTree.summarize' => 'Zusammenfassen und springen',
			'dock.sessionTree.labelTitle' => 'Eintrag mit Label versehen',
			'dock.sessionTree.labelField' => 'Label',
			'dock.sessionTree.clearLabel' => 'Label entfernen',
			'dock.sessionTree.noCompanion' => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind das Springen zu einem Eintrag und Labels nicht verfügbar.',
			'dock.fileBrowser.up' => 'Übergeordneter Ordner',
			'dock.fileBrowser.refresh' => 'Aktualisieren',
			'dock.fileBrowser.newFile' => 'Neue Datei',
			'dock.fileBrowser.newFolder' => 'Neuer Ordner',
			'dock.fileBrowser.create' => 'Erstellen',
			'dock.fileBrowser.rename' => 'Umbenennen',
			'dock.fileBrowser.open' => 'Öffnen',
			'dock.fileBrowser.browseHere' => 'Durchsuchen',
			'dock.fileBrowser.copyPath' => 'Pfad kopieren',
			'dock.fileBrowser.name' => 'Name',
			'dock.fileBrowser.nameReserved' => 'Dieser Name ist reserviert.',
			'dock.fileBrowser.nameSeparator' => 'Namen dürfen kein / oder \ enthalten.',
			'dock.fileBrowser.exists' => ({required Object name}) => '${name} existiert bereits.',
			'dock.fileBrowser.failed' => ({required Object error}) => 'Fehlgeschlagen: ${error}',
			'dock.fileBrowser.deleteTitle' => ({required Object name}) => '${name} löschen?',
			'dock.fileBrowser.deleteFileBody' => 'Die Datei wird vom Rechner gelöscht.',
			'dock.fileBrowser.deleteFolderBody' => 'Der Ordner und alles darin werden vom Rechner gelöscht.',
			'dock.fileBrowser.deleteLinkBody' => 'Der symbolische Link wird vom Rechner gelöscht. Worauf er zeigt, bleibt.',
			'dock.fileBrowser.link' => 'Symbolischer Link',
			'dock.fileBrowser.emptyFolder' => 'Leerer Ordner',
			'dock.fileBrowser.listFailed' => ({required Object error}) => 'Konnte nicht auflisten: ${error}',
			'dock.fileBrowser.openDocuments' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} geöffnete Datei', other: '${n} geöffnete Dateien', ), 
			'dock.fileBrowser.openFailed' => ({required Object error}) => 'Konnte nicht öffnen: ${error}',
			'dock.fileBrowser.backToFiles' => 'Zurück zu den Dateien',
			'dock.fileBrowser.save' => 'Speichern',
			'dock.fileBrowser.saved' => ({required Object name}) => '${name} gespeichert.',
			'dock.fileBrowser.saveFailed' => ({required Object error}) => 'Speichern fehlgeschlagen: ${error}',
			'dock.fileBrowser.more' => 'Mehr',
			'dock.fileBrowser.find' => 'Suchen',
			'dock.fileBrowser.reload' => 'Vom Datenträger neu laden',
			'dock.fileBrowser.showDiff' => 'git diff anzeigen',
			'dock.fileBrowser.showFile' => 'Datei anzeigen',
			'dock.fileBrowser.conflictTitle' => 'Datei auf dem Rechner geändert',
			'dock.fileBrowser.conflictChanged' => 'Die Datei wurde auf dem Rechner geändert, seit du sie geöffnet hast. Mit deiner Version überschreiben oder deine Änderungen verwerfen und neu laden?',
			'dock.fileBrowser.conflictDeleted' => 'Die Datei wurde auf dem Rechner gelöscht, seit du sie geöffnet hast. Überschreiben legt sie neu an.',
			'dock.fileBrowser.overwrite' => 'Überschreiben',
			'dock.fileBrowser.discardAndReload' => 'Verwerfen und neu laden',
			'dock.fileBrowser.discardTitle' => ({required Object name}) => 'Änderungen an ${name} verwerfen?',
			'dock.fileBrowser.discardBody' => 'Deine ungespeicherten Änderungen gehen verloren.',
			'dock.fileBrowser.discard' => 'Verwerfen',
			'dock.fileBrowser.tooLarge' => ({required Object mb}) => 'Größer als ${mb} MB: der Anfang wird schreibgeschützt angezeigt.',
			'dock.fileBrowser.binary' => 'Binärdatei. Wird nicht angezeigt.',
			'dock.fileBrowser.notUtf8' => 'Kein UTF-8-Text: schreibgeschützt, damit Speichern nichts beschädigen kann.',
			'dock.fileBrowser.noMatches' => 'Keine Treffer',
			'dock.fileBrowser.replace' => 'Ersetzen',
			'dock.fileBrowser.replaceAll' => 'Alle ersetzen',
			'dock.fileBrowser.caseSensitive' => 'Groß-/Kleinschreibung beachten',
			'dock.fileBrowser.previousMatch' => 'Vorheriger Treffer',
			'dock.fileBrowser.nextMatch' => 'Nächster Treffer',
			'dock.fileBrowser.noChanges' => 'Keine Änderungen gegenüber HEAD.',
			'dock.fileBrowser.diffFailed' => ({required Object error}) => 'git diff fehlgeschlagen: ${error}',
			'dock.fileBrowser.diffTruncated' => ({required Object shown, required Object total}) => 'Zeige ${shown} von ${total} Diff-Zeilen.',
			'dock.fileBrowser.git.modified' => 'Geändert',
			'dock.fileBrowser.git.added' => 'Hinzugefügt',
			'dock.fileBrowser.git.deleted' => 'Gelöscht',
			'dock.fileBrowser.git.renamed' => 'Umbenannt',
			'dock.fileBrowser.git.copied' => 'Kopiert',
			'dock.fileBrowser.git.typeChanged' => 'Typ geändert',
			'dock.fileBrowser.git.untracked' => 'Nicht verfolgt',
			'dock.fileBrowser.git.ignored' => 'Ignoriert',
			'dock.fileBrowser.git.conflicted' => 'Konflikt',
			'dock.terminals.newTerminal' => 'Neues Terminal',
			'dock.terminals.empty' => ({required Object machine}) => 'Kein Terminal auf ${machine} geöffnet.',
			'dock.terminals.close' => 'Schließen',
			'dock.terminals.restart' => 'Neu starten',
			'dock.terminals.smaller' => 'Kleinerer Text',
			'dock.terminals.larger' => 'Größerer Text',
			'dock.terminals.paste' => 'Einfügen',
			'dock.terminals.selectAll' => 'Alles auswählen',
			'dock.terminals.clear' => 'Leeren',
			'dock.terminals.failed' => ({required Object error}) => 'Terminal fehlgeschlagen: ${error}',
			'dock.terminals.exited' => ({required Object code}) => 'Die Shell wurde mit Code ${code} beendet.',
			'dock.terminals.exitedBySignal' => 'Die Shell wurde beendet.',
			'sidebar.addMachine' => 'Rechner hinzufügen',
			'sidebar.more' => 'Mehr',
			'sidebar.importMachines' => 'Rechner importieren…',
			'sidebar.exportMachines' => 'Rechner exportieren…',
			'sidebar.keys' => 'SSH-Schlüssel',
			'sidebar.usage' => 'Nutzung',
			'sidebar.settings' => 'Einstellungen',
			'sidebar.noMachines' => 'Noch keine Rechner.',
			'sidebar.search' => 'Sitzungen durchsuchen',
			'sidebar.searchHint' => 'Suchen',
			'sidebar.noMatches' => 'Keine passenden Sitzungen.',
			'sidebar.pinned' => 'Angeheftet',
			'machines.thisComputer' => 'Dieser Computer',
			'machines.tailscale' => 'Tailscale',
			'machines.route' => 'Route',
			'machines.target' => 'Rechner',
			'machines.sshConfigAlias' => ({required Object alias}) => 'Aus SSH-Config-Alias ${alias}',
			'machines.deleteTitle' => ({required Object name}) => '${name} löschen?',
			'machines.deleteBody' => 'Gespeicherte Passwörter dieses Rechners werden ebenfalls gelöscht. Schlüssel und vertrauenswürdige Hostschlüssel bleiben.',
			'machines.testConnection' => 'Verbindung testen',
			'machines.connecting' => 'Verbinden…',
			'machines.connectedIn' => ({required Object ms}) => 'Verbunden in ${ms} ms.',
			'machines.failed' => ({required Object error}) => 'Fehlgeschlagen: ${error}',
			'machines.updateOmp' => 'omp aktualisieren',
			'machines.updatingOmp' => 'omp update läuft auf dem Rechner…',
			'machines.ompUpdated' => ({required Object from, required Object to}) => 'omp von ${from} auf ${to} aktualisiert. Laufende Sitzungen behalten ${from}, bis ihr omp endet.',
			'machines.hostKeys' => 'Vertrauenswürdige Hostschlüssel',
			'machines.noHostKeys' => 'Noch kein Hostschlüssel als vertrauenswürdig markiert. Die erste Verbindung fragt nach.',
			'machines.forgetHostKey' => 'Diesen Hostschlüssel vergessen',
			'machines.noKeySelected' => 'kein Schlüssel ausgewählt',
			'machines.facts' => 'System',
			'machines.status' => 'Status',
			'machines.os' => 'OS',
			'machines.arch' => 'Architektur',
			'machines.shell' => 'Shell',
			'machines.loginPath' => 'Login-PATH',
			'machines.home' => 'Home',
			'machines.omp' => 'omp',
			'machines.ompVersion' => 'omp-Version',
			'machines.companion' => 'Companion',
			'machines.companionReady' => 'Hochgeladen',
			'machines.companionMissing' => 'Nicht hochgeladen',
			'machines.notFound' => 'Nicht gefunden',
			'machines.notProbed' => 'Verbinde dich, um OS, Shell und omp des Rechners zu lesen.',
			'machines.power' => 'Energie',
			'machines.keepAwake' => 'Diesen Mac wach halten, während omp arbeitet',
			'machines.keepAwakeDetail' => 'Während omp in einer Sitzung aus ompanion arbeitet, schläft der Mac nicht – auch nicht direkt nach dem Aufwecken durch eine Anfrage. Nur am Strom; das Display schaltet sich weiterhin ab. Jedes Gerät sieht diesen Schalter.',
			'auth.key' => 'Schlüssel',
			'auth.password' => 'Passwort',
			'auth.agent' => 'SSH-Konfiguration und Agent (wie ssh)',
			'auth.none' => 'Keine (Tailscale SSH)',
			'auth.keyboardInteractive' => 'Tastatur-interaktiv',
			'editor.addTitle' => 'Rechner hinzufügen',
			'editor.editTitle' => 'Rechner bearbeiten',
			'editor.kind' => 'Art',
			'editor.kindSsh' => 'SSH',
			'editor.name' => 'Name',
			'editor.host' => 'Host',
			'editor.hostHelper' => 'Hostname, IP-Adresse, MagicDNS-Name oder 100.x-Adresse',
			'editor.port' => 'Port',
			'editor.invalidPort' => 'Zwischen 1 und 65535',
			'editor.user' => 'Benutzer',
			'editor.auth' => 'Authentifizierung',
			'editor.key' => 'Schlüssel',
			'editor.chooseKey' => 'Schlüssel wählen',
			'editor.noKeys' => 'Noch keine Schlüssel auf diesem Gerät.',
			'editor.importKey' => 'Schlüssel importieren…',
			'editor.generateKey' => 'Schlüssel erzeugen…',
			'editor.password' => 'Passwort',
			'editor.passwordSavedHint' => 'Leer lassen, um das gespeicherte Passwort zu behalten',
			'editor.passwordAskHint' => 'Leer lassen, um beim Verbinden gefragt zu werden',
			'editor.savePassword' => 'Passwort auf diesem Gerät speichern',
			'editor.tailscale' => 'Über Tailscale erreichbar',
			'editor.jumpHosts' => 'Jump-Hosts',
			'editor.jumpHostsHelp' => 'Die Verbindung zum Rechner läuft der Reihe nach über diese Hosts. Für einen Host hinter NAT mit Reverse-Tunnel den Relay-Host hier eintragen und beim Rechner localhost als Host sowie den Tunnel-Port angeben.',
			'editor.jumpHostN' => ({required Object n}) => 'Jump-Host ${n}',
			'editor.addJumpHost' => 'Jump-Host hinzufügen',
			'editor.moveUp' => 'Nach oben',
			'editor.moveDown' => 'Nach unten',
			'editor.remove' => 'Entfernen',
			'editor.fromSshConfig' => 'Aus SSH-Konfiguration',
			'editor.fromTailscale' => 'Aus Tailscale',
			'editor.proxyCommandIgnored' => ({required Object command}) => 'ProxyCommand wird nicht unterstützt und wurde ignoriert: ${command}',
			'editor.hostKeysPretrusted' => 'Hostschlüssel von Tailscale gelten beim Speichern als vertrauenswürdig.',
			'editor.agentHelp' => 'Wie der Befehl ssh: zuerst die Schlüssel des ssh-agent (IdentityAgent, sonst SSH_AUTH_SOCK), dann die IdentityFile-Schlüssel, die ~/.ssh/config für diesen Host setzt, sonst ~/.ssh/id_ed25519, id_ecdsa und id_rsa. Verschlüsselte Schlüssel fragen nach ihrer Passphrase. Lehnt der Host jeden Schlüssel ab, folgt seine Passwortabfrage.',
			'keys.empty' => 'Noch keine Schlüssel. Importiere einen vorhandenen Schlüssel oder erzeuge einen neuen.',
			'keys.import' => 'Schlüssel importieren',
			'keys.generate' => 'Schlüssel erzeugen',
			'keys.copyPublicKey' => 'Öffentlichen Schlüssel kopieren',
			'keys.publicKeyCopied' => 'Öffentlicher Schlüssel kopiert.',
			'keys.deleteTitle' => ({required Object name}) => '${name} löschen?',
			'keys.deleteBody' => 'Der private Schlüssel wird von diesem Gerät entfernt.',
			'keys.deleteUsedBy' => ({required Object machines}) => 'Rechner, die ihn nutzen, brauchen einen anderen Schlüssel: ${machines}.',
			'keys.name' => 'Name',
			'keys.privateKey' => 'Privater Schlüssel',
			'keys.privateKeyHint' => 'OpenSSH- oder PEM-Schlüssel einfügen',
			'keys.passphrase' => 'Passphrase',
			'keys.passphraseHint' => 'Nur für verschlüsselte Schlüssel',
			'keys.importTitle' => 'SSH-Schlüssel importieren',
			'keys.importAction' => 'Importieren',
			'keys.generateTitle' => 'Ed25519-Schlüssel erzeugen',
			'keys.generateAction' => 'Erzeugen',
			'keys.generatedBody' => 'Füge diesen öffentlichen Schlüssel auf deinen Rechnern zu ~/.ssh/authorized_keys hinzu.',
			'keys.malformed' => 'Das ist kein privater Schlüssel, den die App lesen kann.',
			'keys.unsupported' => 'Dieser Schlüsseltyp wird nicht unterstützt.',
			'keys.passphraseRequired' => 'Dieser Schlüssel ist verschlüsselt. Gib seine Passphrase ein.',
			'keys.wrongPassphrase' => 'Falsche Passphrase.',
			'keys.duplicate' => ({required Object name}) => 'Dieser Schlüssel ist bereits als ${name} gespeichert.',
			'keys.fileTooLarge' => 'Diese Datei ist zu groß für einen privaten Schlüssel.',
			'hostKey.unknownTitle' => 'Diesem Host vertrauen?',
			'hostKey.unknownBody' => ({required Object host}) => 'Erste Verbindung zu ${host}. Vergleiche den Fingerabdruck mit dem Schlüssel des Servers, bevor du vertraust.',
			'hostKey.changedTitle' => 'Hostschlüssel geändert',
			'hostKey.changedBody' => ({required Object host}) => '${host} hat einen anderen Schlüssel vorgelegt als den zuvor vertrauten. Der Server wurde vielleicht neu installiert, oder jemand fängt die Verbindung ab.',
			'hostKey.changedOpenSshBody' => ({required Object host}) => '${host} hat einen Schlüssel vorgelegt, der von ~/.ssh/known_hosts abweicht. Der Server wurde vielleicht neu installiert, oder jemand fängt die Verbindung ab.',
			'hostKey.previouslyTrusted' => 'Zuvor vertraut',
			'hostKey.revokedTitle' => 'Hostschlüssel widerrufen',
			'hostKey.revokedBody' => ({required Object host}) => '~/.ssh/known_hosts markiert den Schlüssel von ${host} als widerrufen. Die Verbindung wird abgelehnt.',
			'hostKey.keyType' => 'Schlüsseltyp',
			'hostKey.fingerprint' => 'Fingerabdruck',
			'hostKey.trust' => 'Vertrauen',
			'hostKey.replace' => 'Ersetzen und verbinden',
			'hostKey.otherTypesTitle' => 'Unerwarteter Schlüsseltyp',
			'hostKey.otherTypesBody' => ({required Object host}) => '~/.ssh/known_hosts kennt ${host} nur mit Schlüsseln anderer Typen. Der Server hat vielleicht einen Schlüsseltyp hinzugefügt, oder jemand fängt die Verbindung ab. Vergleiche den Fingerabdruck mit dem Schlüssel des Servers, bevor du vertraust.',
			'hostKey.knownToOpenSsh' => 'Bekannt in ~/.ssh/known_hosts',
			'links.confirmTitle' => 'Diesen Link öffnen?',
			'links.confirmBody' => ({required Object scheme}) => 'Das ist ein ${scheme}:-Link, keine Webseite. Er wird in der App geöffnet, die ${scheme}:-Links auf diesem Gerät verarbeitet.',
			'links.open' => 'Öffnen',
			'prompt.passwordTitle' => ({required Object hop}) => 'Passwort für ${hop}',
			'prompt.signInTitle' => ({required Object hop}) => 'Bei ${hop} anmelden',
			'prompt.passphraseTitle' => ({required Object path}) => 'Passphrase für ${path}',
			'prompt.passphraseAccepted' => ({required Object hop}) => '${hop} akzeptiert diesen Schlüssel. Gib die Passphrase ein, um ihn zu verwenden.',
			'prompt.passphraseUnknownKey' => ({required Object hop}) => 'Gib die Passphrase ein, um diesen Schlüssel ${hop} anzubieten.',
			'prompt.passphraseWrong' => 'Falsche Passphrase.',
			'prompt.passphrase' => 'Passphrase',
			'prompt.rememberPassphrase' => 'Auf diesem Gerät merken',
			'connectError.noKeySelected' => ({required Object hop}) => '${hop} nutzt Schlüssel-Authentifizierung, aber es ist kein Schlüssel ausgewählt. Bearbeite den Rechner, um einen auszuwählen.',
			'connectError.keyMissing' => ({required Object hop}) => 'Der private Schlüssel für ${hop} fehlt auf diesem Gerät.',
			'connectError.passwordMissing' => ({required Object hop}) => 'Kein Passwort für ${hop}.',
			'connectError.unreachable' => ({required Object hop}) => '${hop} ist nicht erreichbar.',
			'connectError.hostKeyRejected' => ({required Object hop}) => 'Dem Hostschlüssel von ${hop} wurde nicht vertraut.',
			'connectError.authFailed' => ({required Object hop}) => '${hop} hat die Zugangsdaten abgelehnt.',
			'connectError.timeout' => ({required Object hop}) => '${hop} hat nicht rechtzeitig geantwortet.',
			'connectError.keyUnavailable' => ({required Object hop}) => 'Der Schlüssel für ${hop} kann auf diesem Gerät nicht verwendet werden.',
			'connectError.protocol' => ({required Object hop}) => 'SSH-Handshake mit ${hop} fehlgeschlagen.',
			'connectError.keyRefused' => ({required Object host, required Object key}) => '${host} hat den Schlüssel ${key} nicht akzeptiert.',
			'connectError.agentKeysRefused' => ({required num n, required Object host}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${host} hat den einzigen Schlüssel im ssh-agent nicht akzeptiert.', other: '${host} hat keinen der ${n} Schlüssel im ssh-agent akzeptiert.', ), 
			'connectError.keysRefused' => ({required Object host}) => '${host} hat keinen dieser Schlüssel akzeptiert:',
			'connectError.agentKey' => ({required Object comment}) => '${comment} aus dem ssh-agent',
			'connectError.agentKeyUnnamed' => 'ein Schlüssel aus dem ssh-agent',
			'connectError.authorizedKeysHint' => ({required Object user, required Object host}) => 'Füge den öffentlichen Schlüssel in ~/.ssh/authorized_keys von ${user} auf ${host} ein.',
			'connectError.noKeys' => ({required Object host}) => 'Kein Schlüssel für ${host} verfügbar. Füge einen mit ssh-add zum ssh-agent hinzu oder benenne ihn mit IdentityFile in ~/.ssh/config.',
			_ => null,
		} ?? switch (path) {
			'tailscale.title' => 'Tailscale-Geräte',
			'tailscale.notInstalled' => 'Tailscale ist auf diesem Computer nicht installiert.',
			'tailscale.failed' => ({required Object message}) => 'Tailscale hat nicht geantwortet: ${message}',
			'tailscale.notRunning' => ({required Object state}) => 'Tailscale ist nicht verbunden (Status: ${state}).',
			'tailscale.noPeers' => 'Keine weiteren Geräte in diesem Tailnet.',
			'tailscale.offline' => 'offline',
			'tailscale.search' => 'Geräte durchsuchen',
			'sshConfig.title' => 'Hosts aus der SSH-Konfiguration',
			'sshConfig.empty' => 'Keine Hosts in ~/.ssh/config.',
			'sshConfig.failed' => ({required Object error}) => '~/.ssh/config konnte nicht gelesen werden: ${error}',
			'transfer.exportTitle' => 'Rechner exportieren',
			'transfer.exportBody' => ({required Object count}) => '${count} SSH-Rechner mit ihren Jump-Hosts und vertrauenswürdigen Hostschlüsseln. Private Schlüssel, Passphrasen und Passwörter werden nie exportiert.',
			'transfer.exportNone' => 'Es gibt keine SSH-Rechner zum Exportieren.',
			'transfer.saveFile' => 'In Datei speichern…',
			'transfer.saved' => 'Gespeichert.',
			'transfer.importTitle' => 'Rechner importieren',
			'transfer.importHint' => 'Füge einen Export von einem anderen Gerät ein oder wähle seine Datei.',
			'transfer.importAction' => 'Importieren',
			'transfer.imported' => ({required Object added, required Object skipped}) => '${added} importiert, ${skipped} übersprungen (bereits vorhanden).',
			'transfer.invalid' => ({required Object error}) => 'Kein Rechner-Export: ${error}',
			'transfer.hostKeysTitle' => 'Zu bestätigende Hostschlüssel',
			'transfer.hostKeysBody' => 'Der Import enthält Hostschlüssel, die ändern würden, welchen Servern dieses Gerät vertraut. Vertraue den Schlüsseln eines Hosts nur, wenn du weißt, dass sie stimmen; die anderen werden nicht importiert.',
			'transfer.trustedHere' => 'Auf diesem Gerät vertrauenswürdig',
			'transfer.nothingTrusted' => 'Noch nichts',
			'transfer.inImport' => 'Im Import',
			'transfer.trustKeys' => 'Diesen Schlüsseln vertrauen',
			'transfer.keysTrusted' => 'Vertraut',
			'settings.theme' => 'Design',
			'settings.themeSystem' => 'System',
			'settings.themeLight' => 'Hell',
			'settings.themeDark' => 'Dunkel',
			'settings.themeCustom' => 'Eigenes',
			'settings.editColors' => 'Farben bearbeiten',
			'settings.language' => 'Sprache',
			'settings.languageSystem' => 'System',
			'settings.customBase' => ({required Object base}) => '${base} (Basis)',
			'settings.customPicked' => ({required Object base, required Object count}) => '${base} (Basis) · ${count} geändert',
			'settings.buildChannel' => 'Build-Kanal',
			'settings.shortcuts' => 'Tastenkürzel',
			'settings.shortcutToggleSidebar' => 'Seitenleiste umschalten',
			'settings.shortcutTogglePanels' => 'Panels umschalten',
			'settings.shortcutPanelTab' => 'Einen Panel-Tab anzeigen',
			'settings.shortcutAddMachine' => 'Rechner hinzufügen',
			'settings.shortcutSettings' => 'Einstellungen',
			'settings.shortcutNewSession' => 'Neue Sitzung',
			'settings.shortcutTogglePause' => 'Sitzung pausieren oder fortsetzen',
			'settings.shortcutPalette' => 'Befehlspalette',
			'settings.shortcutSearchSessions' => 'Sitzungen durchsuchen',
			'settings.shortcutAbort' => 'Laufenden Durchlauf stoppen',
			'settings.about' => 'Über',
			'settings.aboutVersion' => ({required Object version, required Object build}) => 'Version ${version} (Build ${build})',
			'settings.aboutClient' => 'Ein Client für omp, den Coding-Agenten oh-my-pi',
			'settings.aboutPrivacy' => 'Datenschutzerklärung',
			'settings.aboutSource' => 'Quellcode',
			'settings.aboutIssues' => 'Problem melden',
			'settings.aboutLicense' => 'Lizenz',
			'settings.aboutLicenseValue' => 'GPL-3.0',
			'settings.aboutLicenses' => 'Open-Source-Lizenzen',
			'themeEditor.title' => 'Eigenes Design',
			'themeEditor.resetAll' => 'Alles zurücksetzen',
			'themeEditor.startFrom' => 'Ausgangspunkt',
			'themeEditor.reset' => 'Auf die Basisfarbe zurücksetzen',
			'themeEditor.hex' => 'Hex-Farbe',
			'themeEditor.terminalNote' => 'Das Terminal stellt diese unverändert dar; Befehlsausgaben im Chat behalten ihren Farbton bei eigenem Kontrast.',
			'themeEditor.groups.surfaces' => 'Flächen',
			'themeEditor.groups.text' => 'Text',
			'themeEditor.groups.accent' => 'Akzent',
			'themeEditor.groups.status' => 'Status',
			'themeEditor.groups.diff' => 'Diff',
			'themeEditor.groups.syntax' => 'Syntax-Hervorhebung',
			'themeEditor.groups.terminal' => 'Terminal',
			'themeEditor.names.background' => 'Hintergrund',
			'themeEditor.names.pane' => 'Bereiche',
			'themeEditor.names.card' => 'Karten',
			'themeEditor.names.field' => 'Eingabefelder',
			'themeEditor.names.selected' => 'Auswahl',
			'themeEditor.names.popover' => 'Pop-ups',
			'themeEditor.names.text' => 'Text',
			'themeEditor.names.textMuted' => 'Gedämpfter Text',
			'themeEditor.names.accent' => 'Akzent',
			'themeEditor.names.onAccent' => 'Auf Akzent',
			'themeEditor.names.error' => 'Fehler',
			'themeEditor.names.errorSurface' => 'Fehlerhintergrund',
			'themeEditor.names.warning' => 'Warnung',
			'themeEditor.names.success' => 'Erfolg',
			'themeEditor.names.running' => 'Läuft',
			'themeEditor.names.diffAdd' => 'Hinzugefügt',
			'themeEditor.names.diffAddSurface' => 'Hintergrund für Hinzugefügtes',
			'themeEditor.names.diffRemove' => 'Entfernt',
			'themeEditor.names.diffRemoveSurface' => 'Hintergrund für Entferntes',
			'themeEditor.names.comment' => 'Kommentare',
			'themeEditor.names.keyword' => 'Schlüsselwörter',
			'themeEditor.names.tag' => 'Tags',
			'themeEditor.names.literal' => 'Literale',
			'themeEditor.names.string' => 'Strings',
			'themeEditor.names.number' => 'Zahlen',
			'themeEditor.names.title' => 'Funktionen',
			'themeEditor.names.builtIn' => 'Eingebaute',
			'themeEditor.names.ansiBlack' => 'Schwarz',
			'themeEditor.names.ansiRed' => 'Rot',
			'themeEditor.names.ansiGreen' => 'Grün',
			'themeEditor.names.ansiYellow' => 'Gelb',
			'themeEditor.names.ansiBlue' => 'Blau',
			'themeEditor.names.ansiMagenta' => 'Magenta',
			'themeEditor.names.ansiCyan' => 'Cyan',
			'themeEditor.names.ansiWhite' => 'Weiß',
			'themeEditor.names.ansiBrightBlack' => 'Hellschwarz',
			'themeEditor.names.ansiBrightRed' => 'Hellrot',
			'themeEditor.names.ansiBrightGreen' => 'Hellgrün',
			'themeEditor.names.ansiBrightYellow' => 'Hellgelb',
			'themeEditor.names.ansiBrightBlue' => 'Hellblau',
			'themeEditor.names.ansiBrightMagenta' => 'Hellmagenta',
			'themeEditor.names.ansiBrightCyan' => 'Hellcyan',
			'themeEditor.names.ansiBrightWhite' => 'Hellweiß',
			'themeEditor.uses.background' => 'App-Hintergrund, Chat, Terminal',
			'themeEditor.uses.pane' => 'Seitenleiste, Dock, Konfigurationsnavigation',
			'themeEditor.uses.card' => 'Karten, Eingabefeld, Codeblöcke, Dialoge',
			'themeEditor.uses.field' => 'Textfelder, Chips, sekundäre Buttons',
			'themeEditor.uses.selected' => 'Hover, ausgewählte Zeilen, fokussierte Felder, Tab-Indikatoren',
			'themeEditor.uses.popover' => 'Menüs und Pop-up-Listen',
			'themeEditor.uses.text' => 'Primärer Text und Symbole',
			'themeEditor.uses.textMuted' => 'Sekundärer Text und Symbole',
			'themeEditor.uses.accent' => 'Primäre Buttons, aktive Schalter, Fortschritt',
			'themeEditor.uses.onAccent' => 'Text und Symbole auf dem Akzent',
			'themeEditor.uses.error' => 'Fehler und fehlgeschlagene Läufe',
			'themeEditor.uses.errorSurface' => 'Hinter Fehlermeldungen',
			'themeEditor.uses.warning' => 'Warnungen, pausierte Ziele und Schleifen',
			'themeEditor.uses.success' => 'Fertige Läufe, bestandene Prüfungen',
			'themeEditor.uses.running' => 'Laufende Arbeit',
			'themeEditor.uses.diffAdd' => 'Hinzugefügte Zeilen',
			'themeEditor.uses.diffAddSurface' => 'Hinter hinzugefügten Zeilen',
			'themeEditor.uses.diffRemove' => 'Entfernte Zeilen',
			'themeEditor.uses.diffRemoveSurface' => 'Hinter entfernten Zeilen',
			'themeEditor.uses.comment' => 'Kommentare und Zitate',
			'themeEditor.uses.keyword' => 'Schlüsselwörter und Doc-Tags',
			'themeEditor.uses.tag' => 'Tags, Namen, Abschnitte',
			'themeEditor.uses.literal' => 'true, false, null',
			'themeEditor.uses.string' => 'Strings, reguläre Ausdrücke, Attribute',
			'themeEditor.uses.number' => 'Zahlen, Typen, Variablen',
			'themeEditor.uses.title' => 'Funktionsnamen, Titel, Links',
			'themeEditor.uses.builtIn' => 'Eingebaute und Klassennamen',
			'themeEditor.uses.ansiBlack' => 'ANSI 0',
			'themeEditor.uses.ansiRed' => 'ANSI 1',
			'themeEditor.uses.ansiGreen' => 'ANSI 2',
			'themeEditor.uses.ansiYellow' => 'ANSI 3',
			'themeEditor.uses.ansiBlue' => 'ANSI 4',
			'themeEditor.uses.ansiMagenta' => 'ANSI 5',
			'themeEditor.uses.ansiCyan' => 'ANSI 6',
			'themeEditor.uses.ansiWhite' => 'ANSI 7',
			'themeEditor.uses.ansiBrightBlack' => 'ANSI 8',
			'themeEditor.uses.ansiBrightRed' => 'ANSI 9',
			'themeEditor.uses.ansiBrightGreen' => 'ANSI 10',
			'themeEditor.uses.ansiBrightYellow' => 'ANSI 11',
			'themeEditor.uses.ansiBrightBlue' => 'ANSI 12',
			'themeEditor.uses.ansiBrightMagenta' => 'ANSI 13',
			'themeEditor.uses.ansiBrightCyan' => 'ANSI 14',
			'themeEditor.uses.ansiBrightWhite' => 'ANSI 15',
			'themeEditor.preview.session' => 'Eine Sitzung',
			'themeEditor.preview.selected' => 'Die ausgewählte Sitzung',
			'themeEditor.preview.text' => 'Text auf dem Hintergrund',
			'themeEditor.preview.muted' => 'Gedämpfter Text',
			'themeEditor.preview.field' => 'Ein Textfeld',
			'themeEditor.preview.secondary' => 'Sekundär',
			'themeEditor.preview.primary' => 'Primär',
			'themeEditor.preview.menuItem' => 'Ein Menüeintrag',
			'themeEditor.preview.done' => 'Fertig',
			'themeEditor.preview.paused' => 'Pausiert',
			'themeEditor.preview.failed' => 'Fehlgeschlagen',
			'themeEditor.preview.working' => 'Läuft',
			'themeEditor.preview.error' => 'Etwas ist schiefgelaufen',
			'notifications.title' => 'Benachrichtigungen',
			'notifications.desktop' => 'Benachrichtigungen',
			'notifications.desktopDetail' => 'Zu den hier offenen Sitzungen, während du in einem anderen Fenster oder einer anderen Sitzung bist',
			'notifications.push' => 'Push-Benachrichtigungen',
			'notifications.pushDetail' => 'Von deinen Rechnern, während dieses Telefon nicht in der Sitzung ist',
			'notifications.pushLost' => 'Deaktiviert: Dieses Telefon hat seinen Benachrichtigungsschlüssel nicht mehr, etwa nach einer Wiederherstellung aus einem Backup. Schalte sie wieder ein.',
			'notifications.pushUnavailable' => ({required Object reason}) => 'Nicht verfügbar: ${reason}',
			'notifications.kindInput' => 'Eine Sitzung braucht eine Eingabe',
			'notifications.kindDone' => 'Ein Lauf endet',
			'notifications.kindFailed' => 'Ein Lauf schlägt fehl',
			'notifications.test' => 'Testbenachrichtigung senden',
			'notifications.testNone' => 'Verbinde dich mit einem Rechner, um eine Testbenachrichtigung zu senden.',
			'notifications.testSent' => ({required Object machine}) => 'Testbenachrichtigung von ${machine} gesendet.',
			'notifications.testFailed' => ({required Object machine, required Object error}) => 'Die Testbenachrichtigung von ${machine} ist fehlgeschlagen: ${error}',
			'notifications.denied' => 'Benachrichtigungen sind für ompanion in den Systemeinstellungen deaktiviert.',
			'notifications.enableFailed' => ({required Object error}) => 'Einschalten der Push-Benachrichtigungen fehlgeschlagen: ${error}',
			'notifications.disableFailed' => ({required Object error}) => 'Ausschalten der Push-Benachrichtigungen fehlgeschlagen: ${error}',
			'notifications.registrationFailed' => ({required Object machine, required Object error}) => 'Push-Benachrichtigungen auf ${machine} konnten nicht aktualisiert werden: ${error}',
			'notifications.unknownMachine' => 'Diese Benachrichtigung kam von einem Rechner, der nicht mehr in ompanion ist.',
			'notifications.subtitle' => ({required Object machine, required Object kind}) => '${machine} · ${kind}',
			'notifications.subtitleInput' => 'Braucht Eingabe',
			'notifications.subtitleDone' => 'Fertig',
			'notifications.subtitleFailed' => 'Fehlgeschlagen',
			'notifications.approval' => ({required Object tool}) => '${tool} erlauben?',
			'notifications.goalComplete' => ({required Object objective}) => 'Ziel erreicht: ${objective}',
			'notifications.finished' => 'Fertig',
			'notifications.runFailed' => 'Der Lauf ist fehlgeschlagen',
			'notifications.open' => 'Öffnen',
			'time.now' => 'jetzt',
			'time.minutes' => ({required Object n}) => '${n} min',
			'time.hours' => ({required Object n}) => '${n} h',
			'time.days' => ({required Object n}) => '${n} d',
			'units.milliseconds' => ({required Object value}) => '${value} ms',
			'units.seconds' => ({required Object value}) => '${value} s',
			'units.minutes' => ({required Object value}) => '${value} min',
			'units.hours' => ({required Object value}) => '${value} h',
			'units.days' => ({required Object value}) => '${value} d',
			'units.pair' => ({required Object big, required Object small}) => '${big} ${small}',
			'units.percent' => ({required Object value}) => '${value} %',
			'units.usd' => ({required Object value}) => '${value} \$',
			'sessions.offline' => 'Offline',
			'sessions.connecting' => 'Verbindung wird hergestellt…',
			'sessions.online' => ({required Object version}) => 'omp ${version}',
			'sessions.needsOmp' => ({required Object reason}) => 'omp erforderlich: ${reason}',
			'sessions.connect' => 'Verbinden',
			'sessions.install' => 'omp installieren',
			'sessions.refresh' => 'Aktualisieren',
			'sessions.collapse' => 'Einklappen',
			'sessions.expand' => 'Ausklappen',
			'sessions.configure' => 'Konfigurieren',
			'sessions.machinePage' => 'Rechnereinstellungen',
			'sessions.pin' => 'Oben anheften',
			'sessions.unpin' => 'Anheften aufheben',
			'sessions.markRead' => 'Als gelesen markieren',
			'sessions.newSession' => 'Neue Sitzung',
			'sessions.newSessionHere' => 'Neue Sitzung in diesem Verzeichnis',
			'sessions.newSessionOn' => ({required Object machine}) => 'Neue Sitzung auf ${machine}',
			'sessions.none' => 'Noch keine Sitzungen.',
			'sessions.untitled' => 'Neue Sitzung',
			'sessions.unknownDirectory' => 'Unbekanntes Verzeichnis',
			'sessions.showMore' => ({required Object n}) => '${n} weitere anzeigen',
			'sessions.working' => 'Arbeitet',
			'sessions.needsInput' => 'Braucht deine Eingabe',
			'sessions.failed' => 'Der letzte Lauf ist fehlgeschlagen',
			'sessions.disconnected' => 'Getrennt',
			'sessions.runningOnMachine' => 'In omp auf dem Rechner geöffnet',
			'sessions.opening' => 'Wird geöffnet…',
			'sessions.unread' => 'Ungelesen',
			'sessions.openFailed' => ({required Object error}) => 'Sitzung konnte nicht geöffnet werden: ${error}',
			'sessions.modelUnavailable' => ({required Object model}) => 'omp kann ${model} nicht verwenden, das Modell, auf dem diese Sitzung lief',
			'sessions.resumeModelTitle' => 'Mit einem anderen Modell fortsetzen',
			'sessions.resumeModelBody' => ({required Object machine, required Object model}) => 'omp auf ${machine} kann ${model} nicht verwenden, das Modell, auf dem diese Sitzung lief. Wähle das Modell, mit dem das Gespräch fortgesetzt wird.',
			'sessions.listFailed' => ({required Object error}) => 'Sitzungen konnten nicht aufgelistet werden: ${error}',
			'sessions.folder' => 'Ordner',
			'sessions.noFolder' => 'Kein Ordner',
			'sessions.noFolderHint' => 'omp arbeitet in einem temporären Verzeichnis, wie beim Start im Home-Ordner. Die Sitzung erscheint direkt unter dem Rechner.',
			'sessions.noTempDirectory' => ({required Object paths, required Object machine}) => 'Keines der temporären Verzeichnisse von omp (${paths}) ist ein Verzeichnis auf ${machine}.',
			'sessions.directory' => 'Arbeitsverzeichnis',
			'sessions.directoryHint' => 'Ein Pfad auf dem Rechner, z. B. ~/code/project',
			'sessions.directoryRequired' => 'Wähle ein Arbeitsverzeichnis.',
			'sessions.notADirectory' => ({required Object path, required Object machine}) => '${path} ist kein Verzeichnis auf ${machine}.',
			'sessions.recentDirectories' => 'Zuletzt verwendete Projekte',
			'sessions.model' => 'Modell (optional)',
			'sessions.modelDefault' => 'Standard (aus den Einstellungen von omp)',
			'sessions.modelPick' => 'Modell wählen',
			'sessions.modelUseDefault' => 'Modell aus den Einstellungen von omp verwenden',
			'sessions.create' => 'Starten',
			'sessions.browse' => 'Rechner durchsuchen',
			'sessions.browseTitle' => 'Verzeichnis wählen',
			'sessions.up' => 'Übergeordnetes Verzeichnis',
			'sessions.showHidden' => 'Versteckte Verzeichnisse anzeigen',
			'sessions.chooseDirectory' => 'Dieses Verzeichnis verwenden',
			'sessions.external' => 'In omp auf dem Rechner',
			'install.title' => ({required Object machine}) => 'omp auf ${machine} installieren',
			'install.notConnected' => 'Verbinde dich zuerst mit dem Rechner.',
			'install.viaDownload' => 'Der Rechner lädt dieses Release von GitHub herunter und prüft dessen SHA-256, bevor er es installiert.',
			'install.viaUpload' => 'Der Rechner hat weder curl noch wget: die App lädt das Release hier herunter und lädt es hoch, wobei die SHA-256 auf dem Rechner geprüft wird.',
			'install.manual' => 'Skript selbst ausführen',
			'install.install' => 'Installieren',
			'install.installing' => 'Wird auf dem Rechner heruntergeladen und installiert…',
			'install.installFailed' => 'Installation auf dem Rechner fehlgeschlagen',
			'install.downloading' => ({required Object asset}) => '${asset} wird heruntergeladen…',
			'install.downloadFailed' => ({required Object status, required Object url}) => 'Download fehlgeschlagen mit HTTP ${status}: ${url}',
			'install.transferring' => ({required Object asset, required Object done, required Object total}) => 'Übertrage ${asset}: ${done} von ${total} MB',
			'install.checking' => 'Installation wird geprüft…',
			'install.stillMissing' => ({required Object reason}) => 'omp ist weiterhin nicht nutzbar: ${reason}',
			'install.noAsset' => ({required Object os, required Object arch}) => 'omp veröffentlicht keinen Build für ${os} ${arch}.',
			'install.done' => ({required Object version}) => 'omp ${version} installiert.',
			'install.os' => 'OS',
			'install.arch' => 'Architektur',
			'install.release' => 'Release',
			'install.directory' => 'Installationsverzeichnis',
			'chat.noModel' => 'Kein Modell',
			'chat.searchModels' => 'Modelle suchen',
			'chat.refreshModels' => 'Modellliste neu laden',
			'chat.noModels' => 'Keine Modelle passen.',
			'chat.modelsFailed' => ({required Object error}) => 'Modelle konnten nicht geladen werden: ${error}',
			'chat.modelFailed' => ({required Object error}) => 'Modell konnte nicht gewechselt werden: ${error}',
			'chat.modelAgent' => ({required Object agent}) => 'Subagent ${agent}',
			'chat.contextWindow' => ({required Object tokens}) => '${tokens} Kontext',
			'chat.reasoning' => 'Reasoning',
			'chat.thinking' => ({required Object level}) => 'Denken: ${level}',
			'chat.noThinking' => 'Dieses Modell hat keine Denkstufen.',
			'chat.thinkingFailed' => ({required Object error}) => 'Denkstufe konnte nicht geändert werden: ${error}',
			'chat.contextTooltip' => ({required Object tokens, required Object window, required Object percent, required Object cost}) => 'Kontext: ${tokens} von ${window} Tokens (${percent} %) · Kosten ${cost}',
			'chat.contextUnknown' => ({required Object cost}) => 'Kontextnutzung noch unbekannt · Kosten ${cost}',
			'chat.pause' => 'Pausieren',
			'chat.resume' => 'Fortsetzen',
			'chat.pauseFailed' => ({required Object error}) => 'Pausieren oder Fortsetzen fehlgeschlagen: ${error}',
			'chat.stop' => 'Stoppen',
			'chat.abortFailed' => ({required Object error}) => 'Lauf konnte nicht gestoppt werden: ${error}',
			'chat.noCompanion' => 'Der Companion ist in dieser Sitzung nicht geladen, daher sind Pausieren, Bearbeiten der Warteschlange, Shell- oder Python-Läufe, Ziele und Schleifen nicht verfügbar.',
			'chat.more' => 'Mehr',
			'chat.copyPath' => 'Pfad der Sitzungsdatei kopieren',
			'chat.detach' => 'Auf diesem Gerät schließen',
			'chat.stopSession' => 'omp-Prozess stoppen',
			'chat.setGoal' => 'Ziel setzen…',
			'chat.guidedGoal' => 'Geführtes Ziel…',
			'chat.startLoop' => 'Prompt in Schleife…',
			'chat.stopSessionFailed' => ({required Object error}) => 'omp-Prozess konnte nicht gestoppt werden: ${error}',
			'chat.reconnecting' => ({required Object attempt, required Object seconds}) => 'Verbindung verloren. Neuer Versuch (${attempt}) in ${seconds} s.',
			'chat.retryNow' => 'Jetzt erneut versuchen',
			'chat.closed' => 'Diese Sitzung ist geschlossen.',
			'chat.exited' => ({required Object code}) => 'omp wurde mit Code ${code} beendet.',
			'chat.idleExited' => ({required Object duration}) => 'omp wurde nach ${duration} ohne Aktivität gestoppt.',
			'chat.idleExitedDetail' => 'Eine Nachricht startet es erneut.',
			'chat.reopen' => 'Wieder öffnen',
			'chat.reopenFailed' => ({required Object error}) => 'Sitzung konnte nicht wieder geöffnet werden: ${error}',
			'chat.parked' => 'Pausiert: der Lauf wartet vor dem nächsten Schritt',
			'chat.compacting' => 'Kontext wird kompaktiert…',
			'chat.retrying' => ({required Object attempt, required Object max, required Object error}) => 'Neuer Versuch (${attempt} von ${max}): ${error}',
			'chat.failed' => ({required Object error}) => 'Der letzte Lauf ist fehlgeschlagen: ${error}',
			'chat.failedUnknown' => 'unbekannter Fehler',
			'chat.aborted' => 'Gestoppt',
			'chat.closedState' => 'Geschlossen',
			'chat.commandOutput' => 'Befehlsausgabe',
			'chat.extensionError' => ({required Object path, required Object event, required Object error}) => 'Fehler der Erweiterung in ${path} (${event}): ${error}',
			'chat.fallbackServed' => ({required Object model}) => 'Vom Ausweichmodell ${model} bedient.',
			'chat.fallbackApplied' => ({required Object from, required Object to, required Object reason}) => 'Von ${from} auf das Ausweichmodell ${to} gewechselt. ${reason}',
			'chat.compactionCancelled' => 'Kompaktierung wurde abgebrochen.',
			'chat.compactionFailed' => ({required Object error}) => 'Kompaktierung fehlgeschlagen: ${error}',
			'chat.cannotBranch' => 'Abzweigen ist nur von deinen eigenen Nachrichten aus möglich.',
			'chat.branch' => 'Abzweigen',
			'chat.branchTitle' => 'Von dieser Nachricht abzweigen?',
			'chat.branchBody' => ({required Object text}) => 'Eine neue Sitzungsdatei beginnt vor dieser Nachricht, und die Nachricht geht zurück ins Eingabefeld:\n\n${text}',
			'chat.branchFailed' => ({required Object error}) => 'Abzweigen fehlgeschlagen: ${error}',
			'chat.resetKept' => 'Frühere Antworten bleiben im Sitzungsbaum erhalten.',
			'chat.openTree' => 'Baum öffnen',
			'chat.resetFailed' => ({required Object error}) => 'Zurücksetzen fehlgeschlagen: ${error}',
			'chat.replaceDraftTitle' => 'Deinen Entwurf ersetzen?',
			'chat.replaceDraftBody' => 'Zurücksetzen bis hierher legt diese Nachricht zurück ins Eingabefeld. Text und Anhänge, die du nicht gesendet hast, gehen verloren.',
			'chat.replaceDraft' => 'Ersetzen',
			'attachments.paste' => 'Der große Einfügetext',
			'attachments.missing' => ({required Object name}) => '${name} ist nicht mehr auf diesem Gerät. Es wurde nichts gesendet.',
			'attachments.tooLarge' => ({required Object name, required Object size, required Object limit}) => '${name} ist ${size}; Anhänge dürfen höchstens ${limit} groß sein. Es wurde nichts gesendet.',
			'attachments.folder' => ({required Object name}) => '${name} ist ein Ordner. Ordner lassen sich nur an Sitzungen auf diesem Computer anhängen. Es wurde nichts gesendet.',
			'attachments.needsCompanion' => ({required Object name}) => '${name} braucht den Companion, um den Rechner der Sitzung zu erreichen, und diese Sitzung hat keinen. Es wurde nichts gesendet.',
			'attachments.uploadFailed' => ({required Object name, required Object error}) => '${name} konnte nicht auf den Rechner der Sitzung kopiert werden: ${error}. Es wurde nichts gesendet.',
			'composer.hint' => 'Nachricht an omp',
			'composer.hintRunning' => 'Laufenden Durchlauf lenken',
			'composer.send' => 'Senden',
			'composer.steer' => 'Lenken',
			'composer.followUp' => 'Folgenachricht',
			'composer.attach' => 'Dateien anhängen',
			'composer.attachPhotos' => 'Fotomediathek',
			'composer.attachFiles' => 'Dateien',
			'composer.remove' => 'Entfernen',
			'composer.pastedImage' => 'Eingefügtes Bild',
			'composer.pastedText' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'Eingefügter Text · ${n} Zeile', other: 'Eingefügter Text · ${n} Zeilen', ), 
			'composer.pasteInline' => 'Inline einfügen',
			'composer.previewTruncated' => ({required Object shown, required Object total}) => 'Die ersten ${shown} von ${total} Zeichen werden angezeigt.',
			'composer.dropToAttach' => 'Zum Anhängen loslassen',
			'composer.dropNothing' => 'Nur Dateien und Ordner können angehängt werden.',
			'composer.pasteFailed' => ({required Object error}) => 'Einfügen fehlgeschlagen: ${error}',
			'composer.attachFailed' => ({required Object error}) => 'Anhängen fehlgeschlagen: ${error}',
			'composer.uploading' => ({required Object sent, required Object total}) => 'Hochladen ${sent} von ${total}',
			'composer.unknownCommand' => ({required Object name}) => '/${name} ist kein Befehl dieser Sitzung. Es wurde nichts gesendet.',
			'composer.sendFailed' => ({required Object error}) => 'Nicht gesendet: ${error}',
			'composer.externalRunning' => ({required Object machine}) => 'Läuft in omp auf ${machine}',
			'composer.externalIdle' => ({required Object machine}) => 'In omp auf ${machine} geöffnet',
			'composer.externalTerminal' => ({required Object terminal}) => 'Terminal ${terminal}',
			'composer.externalBody' => 'Ein anderer omp-Prozess schreibt in diese Sitzungsdatei. ompanion liest den Verlauf live mit, aber Senden ist aus: zwei Schreiber würden sich gegenseitig überschreiben. In jenem Prozess eingereihte Nachrichten sind hier nicht sichtbar.',
			'composer.externalWait' => 'Der andere omp-Prozess besitzt diese Sitzung noch. Übernimm sie, sobald er beendet ist.',
			'composer.takeOver' => 'Übernehmen',
			'composer.externalRunningNoMachine' => 'Läuft in omp',
			'composer.externalIdleNoMachine' => 'In omp geöffnet',
			'composer.externalGone' => 'Der andere omp-Prozess wurde beendet',
			'composer.externalBodyGone' => 'Der andere omp-Prozess ist weg. Übernimm die Sitzung, um von hier Nachrichten zu senden.',
			'queue.steer' => 'Lenken',
			'queue.followUp' => 'Folgenachricht',
			'queue.more' => ({required Object n}) => '+${n} weitere',
			'queue.edit' => 'Im Eingabefeld bearbeiten',
			'queue.remove' => 'Aus der Warteschlange entfernen',
			'queue.takeFailed' => ({required Object error}) => 'Warteschlange konnte nicht geändert werden: ${error}',
			'goal.label' => ({required Object usage}) => 'Ziel ${usage}',
			'goal.status.active' => 'Aktiv',
			'goal.status.paused' => 'Pausiert',
			'goal.status.budgetLimited' => 'Budget erreicht',
			'goal.status.complete' => 'Abgeschlossen',
			'goal.status.dropped' => 'Verworfen',
			'goal.tooltip' => ({required Object status, required Object usage}) => 'Ziel · ${status} · ${usage}',
			'goal.usage' => ({required Object used, required Object budget, required Object left}) => '${used} von ${budget} Tokens (${left} übrig)',
			'goal.usageNoBudget' => ({required Object used}) => '${used} Tokens, kein Budget',
			'goal.spent' => ({required Object time}) => '${time} aufgewendet',
			'goal.pause' => 'Pausieren',
			'goal.resume' => 'Fortsetzen',
			'goal.budget' => 'Token-Budget',
			'goal.budgetHint' => 'Eine Zahl oder off',
			'goal.setBudget' => 'Budget festlegen',
			'goal.budgetInvalid' => 'Das Zielbudget muss eine positive Ganzzahl oder `off` sein.',
			'goal.drop' => 'Verwerfen…',
			'goal.dropTitle' => 'Ziel verwerfen?',
			'goal.dropBody' => 'Damit wird der Zieleintrag entfernt. Die aufgelaufene Nutzung bleibt im Sitzungsprotokoll.',
			'goal.dropConfirm' => 'Verwerfen',
			'goal.failed' => ({required Object error}) => 'Ziel konnte nicht geändert werden: ${error}',
			'loop.iterations' => ({required Object remaining, required Object total}) => 'Schleife ${remaining}/${total}',
			'loop.timeLeft' => ({required Object time}) => 'Schleife · ${time} übrig',
			'loop.running' => 'Schleife läuft',
			'loop.waiting' => 'Schleife wartet',
			'loop.paused' => 'Schleife pausiert',
			'loop.iterationsLeft' => ({required Object remaining, required Object total}) => 'Noch ${remaining} von ${total} Iterationen',
			'loop.timeLeftOf' => ({required Object time, required Object total}) => 'Noch ${time} von ${total}',
			'loop.whileCondition' => ({required Object command}) => 'solange `${command}` erfolgreich ist',
			'loop.untilCondition' => ({required Object command}) => 'bis `${command}` erfolgreich ist',
			'loop.whileLabel' => 'Läuft weiter, solange dieser Befehl erfolgreich ist:',
			'loop.untilLabel' => 'Läuft weiter, bis dieser Befehl erfolgreich ist:',
			'loop.done' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'bisher ${n} Iteration', other: 'bisher ${n} Iterationen', ), 
			'loop.waitingPrompt' => 'Wartet auf deinen nächsten Prompt, den sie nach jedem Durchlauf wiederholt.',
			'loop.pausedPrompt' => 'Ausgesetzt. Der nächste Prompt, den du sendest, setzt sie fort.',
			'loop.suspend' => 'Aussetzen',
			'loop.disable' => 'Ausschalten',
			'loop.failed' => ({required Object error}) => 'Schleife konnte nicht geändert werden: ${error}',
			'exec.running' => 'läuft',
			'exec.exited' => ({required Object code}) => 'Exit ${code}',
			'exec.cancelled' => 'abgebrochen',
			'exec.failed' => ({required Object error}) => 'fehlgeschlagen: ${error}',
			'exec.abort' => 'Stopp',
			'exec.truncated' => 'Ausgabe gekürzt',
			'requests.approvalTitle' => ({required Object tool}) => '${tool} zulassen?',
			'requests.position' => ({required Object index, required Object count}) => '${index} von ${count}',
			'requests.previous' => 'Vorherige Anfrage',
			'requests.next' => 'Nächste Anfrage',
			'requests.submit' => 'Absenden',
			'requests.yes' => 'Ja',
			'requests.no' => 'Nein',
			'requests.editorText' => 'Text im Eingabefeld',
			'requests.openUrlTitle' => 'In deinem Browser öffnen',
			'requests.openInBrowser' => 'Öffnen',
			'requests.forwarding' => ({required Object port}) => 'localhost:${port} auf diesem Gerät wird für den Login-Callback an den Rechner weitergeleitet.',
			'requests.forwardFailed' => ({required Object error}) => 'Der Login-Callback-Port konnte nicht weitergeleitet werden: ${error}',
			'requests.answerFailed' => ({required Object error}) => 'Die Antwort konnte nicht gesendet werden: ${error}',
			'requests.unsupportedTitle' => 'Nicht unterstützte Anfrage',
			'requests.unsupportedBody' => ({required Object method}) => 'Der Companion hat "${method}" angefragt, was diese App-Version nicht anzeigen kann.',
			'requests.secondsLeft' => ({required Object n}) => 'noch ${n} s',
			'requests.notWebLink' => 'Kein http- oder https-Link, öffnet sich daher nicht von hier.',
			'ask.title' => 'Frage',
			'ask.titleMany' => ({required Object n}) => '${n} Fragen',
			'ask.invalid' => ({required Object error}) => 'Die Frage konnte nicht gelesen werden: ${error}',
			'ask.recommended' => 'Empfohlen',
			'ask.multi' => 'Wähle beliebig viele.',
			'ask.otherHint' => 'Sonstiges: eigene Antwort eingeben',
			'ask.note' => 'Notiz (optional)',
			'ask.chat' => 'Dazu chatten',
			'transcript.jumpToLatest' => 'Zum Neuesten springen',
			'transcript.loadEarlier' => 'Frühere Nachrichten laden',
			'transcript.branchFromHere' => 'Von hier abzweigen',
			'transcript.resetHere' => 'Bis hierher zurücksetzen',
			'transcript.resetRunning' => 'Warte, bis der Durchlauf fertig ist, oder stoppe ihn, bevor du zurücksetzt',
			'transcript.copyMessage' => 'Nachricht kopieren',
			'transcript.copyCode' => 'Code kopieren',
			'transcript.copyOutput' => 'Ausgabe kopieren',
			'transcript.fromAgent' => 'Vom Agenten gesendet',
			'transcript.automatic' => 'Automatische Nachricht',
			'transcript.waiting' => 'Wartet auf Antwort',
			'transcript.waitingElapsed' => ({required Object seconds}) => 'Wartet auf Antwort · ${seconds} s',
			'transcript.thinking' => 'Denkt nach…',
			'transcript.thought' => 'Gedanke',
			'transcript.thoughtFor' => ({required Object duration}) => 'Nachgedacht: ${duration}',
			'transcript.reasoningTokens' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Reasoning-Token', other: '${n} Reasoning-Tokens', ), 
			'transcript.redactedThinking' => 'Reasoning vom Anbieter ausgeblendet',
			'transcript.interrupted' => 'Unterbrochen',
			'transcript.failed' => 'Die Antwort ist fehlgeschlagen.',
			'transcript.lengthLimit' => 'Beim Ausgabe-Token-Limit gestoppt.',
			'transcript.retryRecovered' => ({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; Wiederholung ${attempt} war erfolgreich.',
			'transcript.retrySuperseded' => ({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; die Wiederholung hat nach Versuch ${attempt} aufgegeben.',
			'transcript.retryFailed' => ({required Object attempt}) => 'Dieser Versuch ist fehlgeschlagen; Wiederholung ${attempt} ist ebenfalls fehlgeschlagen.',
			'transcript.tokensIn' => ({required Object count}) => '${count} rein',
			'transcript.tokensOut' => ({required Object count}) => '${count} raus',
			'transcript.tokensCached' => ({required Object count}) => '${count} aus Cache',
			'transcript.seconds' => ({required Object value}) => '${value} s',
			'transcript.image' => 'Bild',
			'transcript.loadImage' => 'Bild laden',
			'transcript.imageLoading' => ({required Object name}) => 'Lade ${name}…',
			'transcript.imageMissing' => ({required Object path}) => 'Bild nicht gefunden: ${path}',
			'transcript.imageNotFile' => ({required Object path}) => 'Keine Datei: ${path}',
			'transcript.imageDenied' => ({required Object path}) => 'Keine Berechtigung zum Lesen von ${path}',
			'transcript.imageNotImage' => ({required Object path}) => 'Kein Bild: ${path}',
			'transcript.imageUnsupported' => ({required Object path, required Object size}) => '${path} (${size}) hat ein Format, das diese App nicht anzeigen kann',
			'transcript.imageTooLarge' => ({required Object path, required Object size}) => '${path} (${size}) ist zu groß, um einzeln geladen zu werden',
			'transcript.imageFailed' => ({required Object path, required Object error}) => '${path} konnte nicht geladen werden: ${error}',
			'transcript.loadOriginal' => ({required Object size}) => 'Original laden (${size})',
			'transcript.retryImage' => 'Wiederholen',
			'transcript.imagePreview' => ({required Object sent, required Object size}) => 'Vorschau, ${sent} von ${size}',
			'transcript.openInFiles' => 'In Dateien öffnen',
			'transcript.showMoreLines' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'Noch ${n} Zeile anzeigen', other: 'Noch ${n} Zeilen anzeigen', ), 
			'transcript.showLess' => 'Weniger anzeigen',
			'transcript.tool.running' => 'Läuft…',
			'transcript.tool.background' => 'Läuft im Hintergrund',
			'transcript.tool.interrupted' => 'Nicht abgeschlossen',
			'transcript.tool.error' => 'Fehler',
			'transcript.tool.arguments' => 'Argumente',
			'transcript.tool.noOutput' => 'Keine Ausgabe',
			'transcript.tool.exitCode' => ({required Object code}) => 'Exit ${code}',
			'transcript.tool.timedOut' => 'Zeitüberschreitung',
			'transcript.tool.lines' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Zeile', other: '${n} Zeilen', ), 
			'transcript.tool.lineRange' => ({required Object from, required Object to}) => 'Zeilen ${from}–${to}',
			'transcript.tool.openFile' => 'Datei öffnen',
			'transcript.tool.created' => 'Erstellt',
			'transcript.tool.deleted' => 'Gelöscht',
			'transcript.tool.movedTo' => ({required Object path}) => 'Verschoben nach ${path}',
			'transcript.tool.noChanges' => 'Keine Änderungen',
			'transcript.tool.todoProgress' => ({required Object done, required Object total}) => '${done} von ${total} erledigt',
			_ => null,
		} ?? switch (path) {
			'transcript.tool.agents' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Agent', other: '${n} Agenten', ), 
			'transcript.tool.openAgent' => 'Agenten öffnen',
			'transcript.tool.agentPending' => 'Ausstehend',
			'transcript.tool.agentRunning' => 'Läuft',
			'transcript.tool.agentCompleted' => 'Fertig',
			'transcript.tool.agentFailed' => 'Fehlgeschlagen',
			'transcript.tool.agentAborted' => 'Abgebrochen',
			'transcript.tool.askWaiting' => 'Wartet unten auf deine Antwort',
			'transcript.tool.recommended' => 'Empfohlen',
			'transcript.tool.cancelled' => 'Abgebrochen',
			'transcript.tool.note' => ({required Object note}) => 'Hinweis: ${note}',
			'transcript.tool.autoSelected' => 'Nach der Zeitüberschreitung automatisch gewählt',
			'transcript.tool.sources' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Quelle', other: '${n} Quellen', ), 
			'transcript.tool.output' => 'Ausgabe',
			'transcript.tool.context' => 'Kontext',
			'transcript.tool.diagnostics' => 'Diagnose',
			'transcript.tool.redirectedTo' => ({required Object url}) => 'Weitergeleitet zu ${url}',
			'transcript.tool.tokens' => ({required Object count}) => '${count} Tokens',
			'transcript.tool.goalSet' => 'setzen',
			'transcript.tool.goalCheck' => 'prüfen',
			'transcript.tool.goalComplete' => 'abschließen',
			'transcript.tool.goalResume' => 'fortsetzen',
			'transcript.tool.goalDrop' => 'verwerfen',
			'transcript.tool.goalNone' => 'kein aktives Ziel',
			'transcript.tool.goalElapsed' => ({required Object time}) => '${time} vergangen',
			'transcript.tool.report' => 'Bericht',
			'transcript.execution.notSent' => 'Nicht an das Modell gesendet',
			'transcript.execution.cancelled' => 'Abgebrochen',
			'transcript.execution.truncated' => 'Ausgabe gekürzt',
			'transcript.compacted' => 'Kontext kompaktiert',
			'transcript.compactedTokens' => ({required Object before, required Object after}) => '${before} → ${after} Tokens',
			'transcript.compactedFrom' => ({required Object before}) => 'von ${before} Tokens',
			'transcript.showSummary' => 'Zusammenfassung anzeigen',
			'transcript.hideSummary' => 'Zusammenfassung ausblenden',
			'transcript.showAll' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'Alle anzeigen (${n} Zeile)', other: 'Alle anzeigen (${n} Zeilen)', ), 
			'transcript.branchSummary' => 'Zusammenfassung des verlassenen Abzweigs',
			'transcript.summaryFiles' => 'Dateien',
			'transcript.fileRead' => 'gelesen',
			'transcript.fileWritten' => 'geschrieben',
			'transcript.fileReadWritten' => 'gelesen und geschrieben',
			'transcript.filesElided' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'Noch ${n} Datei', other: 'Noch ${n} Dateien', ), 
			'transcript.modelChange' => ({required Object model}) => 'Modell: ${model}',
			'transcript.modelRoleChange' => ({required Object role, required Object model}) => 'Modell (${role}): ${model}',
			'transcript.thinkingLevel' => ({required Object level}) => 'Denken: ${level}',
			'transcript.thinkingOff' => 'Denken: aus',
			'transcript.rulesApplied' => ({required num n, required Object rules}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: 'Regel angewendet: ${rules}', other: '${n} Regeln angewendet: ${rules}', ), 
			'transcript.mentionedFiles' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Datei angehängt', other: '${n} Dateien angehängt', ), 
			'transcript.skippedTooLarge' => 'zu groß',
			'transcript.skippedBinary' => 'binär',
			'transcript.backgroundResult' => 'Ergebnis aus dem Hintergrund',
			'transcript.delegated' => 'Weitergeleitete Anfrage',
			'transcript.turn.workedFor' => ({required Object duration}) => '${duration} gearbeitet',
			'transcript.turn.worked' => 'Gearbeitet',
			'transcript.turn.toolCalls' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Tool-Aufruf', other: '${n} Tool-Aufrufe', ), 
			'transcript.turn.filesEdited' => ({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('de'))(n, one: '${n} Datei bearbeitet', other: '${n} Dateien bearbeitet', ), 
			'transcript.turn.durationHours' => ({required Object hours, required Object minutes}) => '${hours} h ${minutes} min',
			'transcript.turn.durationMinutes' => ({required Object minutes, required Object seconds}) => '${minutes} min ${seconds} s',
			'transcript.turn.durationSeconds' => ({required Object seconds}) => '${seconds} s',
			'config.title' => ({required Object machine}) => '${machine} konfigurieren',
			'config.connect' => 'Verbinden',
			'config.connecting' => 'Verbinde…',
			'config.needsOmp' => ({required Object reason}) => 'omp muss auf diesem Rechner installiert oder aktualisiert werden: ${reason}',
			'config.refresh' => 'Aktualisieren',
			'config.noOutput' => '(keine Ausgabe)',
			'config.sections.settings' => 'Einstellungen',
			'config.sections.roles' => 'Modellrollen',
			'config.sections.accounts' => 'Anbieter',
			'config.sections.mcp' => 'MCP-Server',
			'config.sections.plugins' => 'Plugins',
			'config.sections.skills' => 'Skills',
			'config.sections.stats' => 'Statistik',
			'config.scope.global' => 'Global',
			'config.scope.project' => 'Projekt',
			'config.scope.projectNone' => 'Öffne eine Sitzung auf diesem Rechner, um die Projekteinstellungen zu bearbeiten.',
			'config.provenance.env' => ({required Object name}) => 'env ${name}',
			'config.provenance.envHint' => ({required Object name}) => 'Die Umgebungsvariable ${name} überschreibt die Dateien.',
			'config.provenance.runtime' => 'Override',
			'config.provenance.runtimeHint' => 'Nur für diesen omp-Prozess gesetzt (RPC-Modus oder ein Laufzeit-Override); die Sitzungen der App nutzen ihn.',
			'config.provenance.overlay' => 'App-Overlay',
			'config.provenance.overlayHint' => 'Erzwungen durch das sitzungsbezogene Konfigurations-Overlay der App.',
			'config.provenance.project' => 'Projekt',
			'config.provenance.projectHint' => 'Aus .omp/config.yml des Projekts.',
			'config.provenance.global' => 'global',
			'config.provenance.globalHint' => 'Aus config.yml des Profils.',
			'config.provenance.defaults' => 'Standard',
			'config.provenance.defaultsHint' => 'omp-Standard; keine Datei setzt ihn.',
			'config.settings.search' => 'Einstellungen durchsuchen',
			'config.settings.editing' => ({required Object path}) => 'Bearbeite ${path}',
			'config.settings.advancedTab' => 'Nur Konfigurationsdatei',
			'config.settings.advancedNote' => 'Einstellungen ohne Zeile im Einstellungs-Panel von omp, gruppiert nach ihrem ersten Schlüssel.',
			'config.settings.themeNote' => 'Dies sind die Terminal-UI-Einstellungen von omp. Das Aussehen der App folgt den App-Einstellungen.',
			'config.settings.noMatches' => 'Keine Einstellung passt.',
			'config.settings.reset' => 'Auf den geerbten Wert zurücksetzen',
			'config.settings.unset' => 'nicht gesetzt',
			'config.settings.presets' => 'Vorgeschlagene Werte',
			'config.settings.notANumber' => 'Keine Zahl',
			'config.settings.notJson' => ({required Object error}) => 'Kein JSON: ${error}',
			'config.settings.expectedObject' => 'JSON-Objekt erwartet',
			'config.settings.expectedArray' => 'JSON-Array erwartet',
			'config.settings.secretSet' => 'Konfiguriert',
			'config.settings.secretUnset' => 'Nicht gesetzt',
			'config.settings.secretEdit' => 'Festlegen…',
			'config.settings.secretHelp' => 'Wird dem Rechner als private Datei gesendet, die omp liest und löscht; nie angezeigt oder protokolliert.',
			'config.settings.secretGlobalOnly' => 'Zugangsdaten werden nur in der globalen Konfiguration gespeichert.',
			'config.settings.addItem' => 'Hinzufügen',
			'config.settings.overriddenLine' => ({required Object value}) => 'Wirksam: ${value} (eine höhere Ebene gewinnt)',
			'config.settings.fileError' => ({required Object path, required Object error}) => '${path} konnte nicht gelesen werden: ${error}',
			'config.roles.storage' => ({required Object storage}) => 'Die Modellauswahl von omp speichert Rollen in: ${storage}',
			'config.roles.projectIs' => ({required Object path}) => 'Projekt: ${path}',
			'config.roles.noProject' => 'Öffne eine Sitzung auf diesem Rechner, um Projektrollen zuzuweisen.',
			'config.roles.refreshModels' => 'Modelle aktualisieren',
			'config.roles.modelsRefreshed' => 'Modellliste aktualisiert.',
			'config.roles.chatRoles' => 'Chat-Rollen',
			'config.roles.kindRoles' => 'Aufgabenarten',
			'config.roles.effective' => 'Wirksam',
			'config.roles.projectLayer' => 'Projekt',
			'config.roles.auto' => 'auto',
			'config.roles.assign' => 'Festlegen',
			'config.roles.clear' => 'Entfernen',
			'config.roles.pickTitle' => ({required Object role}) => 'Modell für ${role}',
			'config.roles.searchModels' => 'Modelle durchsuchen',
			'config.roles.thinking' => 'Denkstufe',
			'config.roles.thinkingDefault' => 'Modell-Standard',
			'config.roles.useTyped' => ({required Object selector}) => '${selector} verwenden',
			'config.roles.useTypedHint' => 'Ein Modell, das omp hier nicht als verfügbar listet',
			'config.roles.context' => ({required Object tokens}) => '${tokens} Kontext',
			'config.roles.vision' => 'Bilder',
			'config.roles.noModels' => 'Kein Modell passt.',
			'config.accounts.machineWide' => 'Zugangsdaten werden pro Rechner gespeichert.',
			'config.accounts.sessionView' => ({required Object path}) => 'Die Markierungen "in Nutzung" und "angeheftet" beziehen sich auf die Sitzung in ${path}.',
			'config.accounts.active' => 'in Nutzung',
			'config.accounts.sticky' => 'angeheftet',
			'config.accounts.expires' => ({required Object date}) => 'läuft ab am ${date}',
			'config.accounts.pin' => 'An Sitzung anheften',
			'config.accounts.pinned' => 'Konto an die Sitzung angeheftet.',
			'config.accounts.logout' => 'Abmelden',
			'config.accounts.logoutTitle' => ({required Object account}) => '${account} abmelden?',
			'config.accounts.logoutBody' => ({required Object provider}) => 'Die gespeicherten Zugangsdaten für ${provider} werden von diesem Rechner entfernt.',
			'config.accounts.oauthLocal' => 'Der Browser öffnet sich auf diesem Computer.',
			'config.accounts.oauthRemote' => 'Der Browser öffnet sich auf diesem Gerät; die App leitet den Callback-Port von omp an den Rechner weiter.',
			'config.accounts.saveKey' => 'Schlüssel speichern',
			'config.accounts.keyStored' => ({required Object provider}) => 'Schlüssel für ${provider} gespeichert.',
			'config.accounts.loginTitle' => ({required Object provider}) => 'Bei ${provider} anmelden',
			'config.accounts.waitingForLink' => 'Warte auf den Autorisierungslink von omp…',
			'config.accounts.openLink' => 'Öffne diesen Link und melde dich an:',
			'config.accounts.openBrowser' => 'Browser öffnen',
			'config.accounts.copyLink' => 'Link kopieren',
			'config.accounts.forwarding' => ({required Object ports}) => 'Lokaler Port ${ports} wird für den Callback an den Rechner weitergeleitet.',
			'config.accounts.forwardFailed' => ({required Object port, required Object error}) => 'Port ${port} konnte nicht weitergeleitet werden (${error}). Füge die Redirect-URL ein, wenn omp danach fragt.',
			'config.accounts.submit' => 'Absenden',
			'config.accounts.yes' => 'Ja',
			'config.accounts.no' => 'Nein',
			'config.accounts.loggedIn' => 'Angemeldet.',
			'config.accounts.bootstrap' => 'Auf diesem Rechner funktioniert noch kein Modell. Melde dich mit einem Konto an oder füge einen API-Schlüssel hinzu; Einstellungen und Rollen funktionieren in der Zwischenzeit.',
			'config.accounts.search' => 'Anbieter durchsuchen',
			'config.accounts.noMatches' => 'Kein Anbieter passt.',
			'config.accounts.signedIn' => 'angemeldet',
			'config.accounts.signIn' => 'Anmelden',
			'config.accounts.keyHint' => 'API-Schlüssel einfügen',
			'config.accounts.other' => 'Anderer Anbieter…',
			'config.accounts.otherId' => 'Anbieter-ID',
			'config.accounts.otherNote' => 'Speichert einen Schlüssel unter einer Anbieter-ID, die diese Liste nicht zeigt, so wie models.yml oder eine Erweiterung sie nennt.',
			'config.accounts.kind.account' => 'Konto',
			'config.accounts.kind.apiKey' => 'API-Schlüssel',
			'config.accounts.kind.local' => 'lokal',
			'config.accounts.source.runtime' => 'omp nutzt einen Schlüssel, der nur für diesen omp-Prozess gesetzt ist.',
			'config.accounts.source.config' => 'omp nutzt den Schlüssel, den models.yml setzt.',
			'config.accounts.source.oauth' => 'omp nutzt ein angemeldetes Konto.',
			'config.accounts.source.apiKey' => 'omp nutzt einen gespeicherten API-Schlüssel.',
			'config.accounts.source.env' => ({required Object name}) => 'omp nutzt den Schlüssel in der Umgebungsvariable ${name}.',
			'config.accounts.source.working' => 'omp hat funktionierende Zugangsdaten für diesen Anbieter.',
			'config.accounts.source.none' => 'Nicht angemeldet.',
			'config.accounts.source.noKey' => 'Kein Schlüssel gespeichert.',
			'config.accounts.overridden.config' => 'models.yml setzt einen Schlüssel für diesen Anbieter, daher nutzt omp diesen und nicht den gespeicherten.',
			'config.accounts.overridden.env' => ({required Object name}) => 'Die Umgebungsvariable ${name} setzt einen Schlüssel, daher nutzt omp diesen und nicht den gespeicherten.',
			'config.accounts.overridden.runtime' => 'Ein für diesen omp-Prozess gesetzter Schlüssel hat Vorrang vor dem gespeicherten.',
			'config.mcp.userFile' => ({required Object path}) => 'Benutzer: ${path}',
			'config.mcp.projectFile' => ({required Object path}) => 'Projekt: ${path}',
			'config.mcp.add' => 'Server hinzufügen',
			'config.mcp.addTitle' => 'MCP-Server hinzufügen',
			'config.mcp.reload' => 'Neu laden',
			'config.mcp.resources' => 'Ressourcen',
			'config.mcp.prompts' => 'Prompts',
			'config.mcp.smithery' => 'Smithery durchsuchen',
			'config.mcp.none' => 'Keine MCP-Server konfiguriert.',
			'config.mcp.userScope' => 'Benutzer',
			'config.mcp.projectScope' => 'Projekt',
			'config.mcp.test' => 'Testen',
			'config.mcp.removeTitle' => ({required Object name}) => '${name} entfernen?',
			'config.mcp.removeBody' => ({required Object scope}) => 'Der Server wird aus der mcp.json im Bereich ${scope} entfernt.',
			'config.mcp.name' => 'Name',
			'config.mcp.nameTooLong' => 'Höchstens 100 Zeichen',
			'config.mcp.nameInvalid' => 'Nur Buchstaben, Ziffern, - _ . : und einzelne Leerzeichen',
			'config.mcp.command' => 'Befehl',
			'config.mcp.url' => 'URL',
			'config.mcp.token' => 'Bearer-Token (optional)',
			'config.mcp.tokenHint' => 'Wird als Authorization-Header in die Benutzer-mcp.json geschrieben.',
			'config.mcp.tokenUserOnly' => 'Nur Server im Benutzerbereich nehmen hier ein Token: eine Projektsitzung würde es in ihrem Laufprotokoll behalten.',
			'config.mcp.tuiOnly' => 'omp 18.3.1 bietet reauth, unauth, reconnect und Smithery-Login nur in seiner Terminal-UI.',
			'config.mcp.testDisabled' => 'Aktiviere den Server, um ihn zu testen; omp lädt nur aktivierte Server.',
			'config.mcp.smitheryTitle' => 'Smithery-Registry',
			'config.plugins.inProject' => ({required Object path}) => 'Befehle laufen in ${path}',
			'config.plugins.installed' => 'Installiert',
			'config.plugins.none' => 'Keine Plugins installiert.',
			'config.plugins.npm' => 'npm',
			'config.plugins.uninstall' => 'Deinstallieren',
			'config.plugins.upgrade' => 'Upgraden',
			'config.plugins.update' => 'Aktualisieren',
			'config.plugins.marketplaceScope' => ({required Object scope}) => 'Marktplatz · ${scope}',
			'config.plugins.shadowed' => 'verdeckt',
			'config.plugins.install' => 'Installieren',
			'config.plugins.installHint' => 'Ein npm-Paket, name@marketplace, github:user/repo, eine Git-URL oder ein lokaler Pfad. npm-Installationen brauchen bun auf dem Rechner.',
			'config.plugins.installPlaceholder' => '@oh-my-pi/exa',
			'config.plugins.installAction' => 'Installieren',
			'config.plugins.marketplaces' => 'Marktplätze',
			'config.plugins.updateAll' => 'Alle aktualisieren',
			'config.plugins.noMarketplaces' => 'Keine Marktplätze konfiguriert.',
			'config.plugins.isInstalled' => 'installiert',
			'config.plugins.sourcePlaceholder' => 'owner/repo, Git-URL oder lokaler Pfad',
			'config.plugins.addMarketplace' => 'Marktplatz hinzufügen',
			'config.skills.registry' => 'Registry-Skills von skills.omp.sh',
			'config.skills.installed' => 'Installiert',
			'config.skills.none' => 'Keine Registry-Skills installiert.',
			'config.skills.notInstalled' => 'nicht installiert',
			'config.skills.range' => ({required Object range}) => 'Bereich ${range}',
			'config.skills.info' => 'Info',
			'config.skills.search' => 'Registry durchsuchen',
			'config.skills.searchHint' => 'pdf, git, review…',
			'config.skills.results' => ({required Object shown, required Object total}) => '${shown} von ${total}',
			'config.skills.downloads' => ({required Object number}) => '${number} Downloads pro Woche',
			'config.skills.by' => ({required Object name}) => 'von ${name}',
			'config.skills.deprecated' => ({required Object reason}) => 'Veraltet: ${reason}',
			'config.skills.installWhere' => ({required Object id}) => '${id} installieren für',
			'config.skills.forUser' => 'Alle Projekte (Benutzer)',
			'config.skills.forProject' => ({required Object path}) => 'Dieses Projekt (${path})',
			'config.skills.scriptsTitle' => 'Dieser Skill enthält Skripte',
			'config.skills.scriptsBody' => 'Beim Installieren werden seine Skripte auf dem Rechner ausgeführt. Trotzdem installieren?',
			'config.skills.installAnyway' => 'Trotzdem installieren',
			'config.skills.license' => ({required Object license}) => 'Lizenz: ${license}',
			'config.skills.latest' => ({required Object version}) => 'Neueste: ${version}',
			'config.skills.versions' => ({required Object versions}) => 'Versionen: ${versions}',
			'config.skills.owners' => ({required Object owners}) => 'Eigentümer: ${owners}',
			'config.skills.downloadsTotal' => ({required Object weekly, required Object total}) => 'Downloads: ${weekly} pro Woche, ${total} insgesamt',
			'config.skills.shipsScripts' => 'Enthält Skripte.',
			'config.skills.noHits' => ({required Object query}) => 'Nichts auf skills.omp.sh passt zu "${query}".',
			'config.stats.span' => ({required Object from, required Object to}) => '${from} – ${to}',
			'config.stats.none' => 'Noch keine Anfragen erfasst.',
			'config.stats.requests' => 'Anfragen',
			'config.stats.errors' => 'Fehler',
			'config.stats.inputTokens' => 'Eingabe-Tokens',
			'config.stats.outputTokens' => 'Ausgabe-Tokens',
			'config.stats.cacheRead' => 'Cache gelesen',
			'config.stats.cost' => 'Kosten',
			'config.stats.ttft' => 'Ø erstes Token',
			'config.stats.speed' => 'Ø Geschwindigkeit',
			'config.stats.tokensPerSecond' => ({required Object n}) => '${n} Tok./s',
			'config.stats.perHour' => 'Anfragen pro Stunde',
			'config.stats.byModel' => 'Nach Modell',
			'config.stats.byFolder' => 'Nach Projekt',
			'config.stats.byAgent' => 'Nach Agent',
			'config.stats.model' => 'Modell',
			'config.stats.folder' => 'Projekt',
			'config.stats.agent' => 'Agent',
			_ => null,
		};
	}
}
