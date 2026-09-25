import 'dart:math';

final _random = Random.secure();

/// A random 128-bit id in hex, for rows created on this device.
String newId() => [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
