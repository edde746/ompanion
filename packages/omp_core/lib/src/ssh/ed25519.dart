import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// dartssh2 signs with Ed25519 keys but cannot derive a public key from a seed, and omp_core has no
// curve dependency. RFC 8032 §5.1.5 needs one fixed-base scalar multiplication, done here in
// extended twisted Edwards coordinates (a = -1), where one complete formula covers add and double.

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _d = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _d2 = (_d * BigInt.two) % _p;
final BigInt _baseX = BigInt.parse('15112221349535400772501151409588531511454012693041857206046113283949847762202');
final BigInt _baseY = BigInt.parse('46316835694926478169428394003475163141307993866256225615783033603165251855960');

typedef _Point = (BigInt x, BigInt y, BigInt z, BigInt t);

/// The 32-byte Ed25519 public key for a 32-byte private seed (RFC 8032 §5.1.5).
Uint8List ed25519PublicKey(Uint8List seed) {
  if (seed.length != 32) throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  final hash = sha512.convert(seed).bytes;
  final scalar = Uint8List.fromList(hash.sublist(0, 32));
  scalar[0] &= 248;
  scalar[31] &= 127;
  scalar[31] |= 64;
  return _encode(_multiply(_littleEndian(scalar), (_baseX, _baseY, BigInt.one, (_baseX * _baseY) % _p)));
}

_Point _add(_Point p, _Point q) {
  final a = ((p.$2 - p.$1) * (q.$2 - q.$1)) % _p;
  final b = ((p.$2 + p.$1) * (q.$2 + q.$1)) % _p;
  final c = (p.$4 * _d2 * q.$4) % _p;
  final d = (p.$3 * BigInt.two * q.$3) % _p;
  final e = b - a;
  final f = d - c;
  final g = d + c;
  final h = b + a;
  return ((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _multiply(BigInt scalar, _Point point) {
  _Point result = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var addend = point;
  var rest = scalar;
  while (rest > BigInt.zero) {
    if (rest.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    rest >>= 1;
  }
  return result;
}

Uint8List _encode(_Point point) {
  final zInverse = point.$3.modInverse(_p);
  final x = (point.$1 * zInverse) % _p;
  var y = (point.$2 * zInverse) % _p;
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (y & BigInt.from(0xff)).toInt();
    y >>= 8;
  }
  if (x.isOdd) bytes[31] |= 0x80;
  return bytes;
}

BigInt _littleEndian(Uint8List bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}
