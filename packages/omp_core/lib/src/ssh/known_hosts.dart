import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'keys.dart';
import 'ssh_config.dart';

enum KnownHostMarker { none, revoked, certAuthority }

/// How a presented host key relates to `known_hosts`, strongest first.
enum KnownHostStatus {
  /// A `@revoked` line lists this key for the host: never accept.
  revoked,

  /// The host is known with this exact key.
  match,

  /// The host is known with a different key of the same type: the key changed or someone intercepts.
  mismatch,

  /// The host is known, but only with keys of other types. OpenSSH asks, with a warning.
  differentKeyType,

  /// Nothing is known about this host.
  unknown,
}

/// One host key line of an OpenSSH `known_hosts` file.
final class KnownHostEntry {
  KnownHostEntry._({
    required this.lineNumber,
    required this.marker,
    required this.patterns,
    required this._salt,
    required this._hash,
    required this.key,
  });

  /// 1-based, for editing the file.
  final int lineNumber;
  final KnownHostMarker marker;

  /// Comma-separated host patterns of a plain line; empty for a hashed line.
  final List<String> patterns;

  /// `|1|salt|hash` parts of a hashed line (HMAC-SHA1 of the host name keyed with the salt).
  final Uint8List? _salt;
  final Uint8List? _hash;

  final SshPublicKey key;

  bool get isHashed => _salt != null;

  /// Whether this line names [host]:[port] (OpenSSH writes `[host]:port` for ports other than 22).
  bool matchesHost(String host, int port) {
    final name = knownHostName(host, port);
    final salt = _salt;
    if (salt != null) return _bytesEqual(_hmacSha1(salt, utf8.encode(name)), _hash!);
    var matched = false;
    for (final pattern in patterns) {
      final negated = pattern.startsWith('!');
      if (_globMatch(name, (negated ? pattern.substring(1) : pattern).toLowerCase())) {
        if (negated) return false;
        matched = true;
      }
    }
    return matched;
  }
}

/// Parses `known_hosts` text. Lines OpenSSH would skip (comments, malformed, unknown markers) are skipped.
List<KnownHostEntry> parseKnownHosts(String text) {
  final entries = <KnownHostEntry>[];
  final lines = const LineSplitter().convert(text);
  for (var index = 0; index < lines.length; index++) {
    final entry = _parseLine(index + 1, lines[index]);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

KnownHostEntry? _parseLine(int lineNumber, String line) {
  final fields = line.trim().split(RegExp(r'\s+'));
  if (fields.first.isEmpty || fields.first.startsWith('#')) return null;
  var marker = KnownHostMarker.none;
  if (fields.first.startsWith('@')) {
    switch (fields.removeAt(0)) {
      case '@revoked':
        marker = KnownHostMarker.revoked;
      case '@cert-authority':
        marker = KnownHostMarker.certAuthority;
      default:
        return null;
    }
  }
  if (fields.length < 3) return null;
  final SshPublicKey key;
  try {
    key = SshPublicKey.parse(fields.sublist(1).join(' '));
  } on FormatException {
    return null;
  }
  final hosts = fields[0];
  if (hosts.startsWith('|')) {
    final parts = hosts.split('|');
    if (parts.length != 4 || parts[1] != '1') return null;
    final Uint8List salt;
    final Uint8List hash;
    try {
      salt = base64.decode(parts[2]);
      hash = base64.decode(parts[3]);
    } on FormatException {
      return null;
    }
    // OpenSSH only accepts SHA-1-sized salts and hashes.
    if (salt.length != 20 || hash.length != 20) return null;
    return KnownHostEntry._(
      lineNumber: lineNumber,
      marker: marker,
      patterns: const [],
      salt: salt,
      hash: hash,
      key: key,
    );
  }
  return KnownHostEntry._(
    lineNumber: lineNumber,
    marker: marker,
    patterns: hosts.split(',').where((pattern) => pattern.isNotEmpty).toList(),
    salt: null,
    hash: null,
    key: key,
  );
}

/// Checks [check] against [entries] with OpenSSH's precedence: revoked, then an exact match, then a
/// changed key of the same type, then other key types known for the host.
KnownHostStatus checkKnownHost(Iterable<KnownHostEntry> entries, HostKeyCheck check) {
  var status = KnownHostStatus.unknown;
  for (final entry in entries) {
    if (entry.marker == KnownHostMarker.certAuthority || !entry.matchesHost(check.host, check.port)) continue;
    final sameKey = _bytesEqual(entry.key.blob, check.keyBlob);
    if (entry.marker == KnownHostMarker.revoked) {
      if (sameKey) return KnownHostStatus.revoked;
      continue;
    }
    final found = sameKey
        ? KnownHostStatus.match
        : entry.key.type == check.keyType
            ? KnownHostStatus.mismatch
            : KnownHostStatus.differentKeyType;
    if (found.index < status.index) status = found;
  }
  return status;
}

/// A `known_hosts` line for [check], optionally with the host name hashed like `HashKnownHosts yes`.
String knownHostsLine(HostKeyCheck check, {bool hashed = false}) {
  final name = knownHostName(check.host, check.port);
  final String hosts;
  if (hashed) {
    final random = Random.secure();
    final salt = Uint8List.fromList(List<int>.generate(20, (_) => random.nextInt(256)));
    hosts = '|1|${base64.encode(salt)}|${base64.encode(_hmacSha1(salt, utf8.encode(name)))}';
  } else {
    hosts = name;
  }
  return '$hosts ${check.keyType} ${base64.encode(check.keyBlob)}';
}

/// The name OpenSSH records: the lowercased host, bracketed with the port unless it is 22.
String knownHostName(String host, int port) {
  final lower = host.toLowerCase();
  return port == 22 ? lower : '[$lower]:$port';
}

List<int> _hmacSha1(List<int> key, List<int> data) => Hmac(sha1, key).convert(data).bytes;

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// OpenSSH `match_pattern`: `*` matches any run, `?` one character, everything else itself.
bool _globMatch(String text, String pattern) {
  var t = 0;
  var p = 0;
  var starP = -1;
  var starT = 0;
  while (t < text.length) {
    if (p < pattern.length && (pattern[p] == '?' || pattern[p] == text[t])) {
      t++;
      p++;
    } else if (p < pattern.length && pattern[p] == '*') {
      starP = p++;
      starT = t;
    } else if (starP >= 0) {
      p = starP + 1;
      t = ++starT;
    } else {
      return false;
    }
  }
  while (p < pattern.length && pattern[p] == '*') {
    p++;
  }
  return p == pattern.length;
}
