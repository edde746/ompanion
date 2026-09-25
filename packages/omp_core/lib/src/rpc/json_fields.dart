/// Typed field access on decoded JSON objects. Every accessor throws a [FormatException] naming the
/// field when the value is missing or has the wrong type, so decoding fails at the boundary.
extension JsonFields on Map<String, Object?> {
  String string(String key) => _field<String>(key);

  String? optString(String key) => _field<String?>(key);

  bool boolean(String key) => _field<bool>(key);

  bool? optBool(String key) => _field<bool?>(key);

  int integer(String key) => _field<int>(key);

  int? optInt(String key) => _field<int?>(key);

  num number(String key) => _field<num>(key);

  num? optNumber(String key) => _field<num?>(key);

  Map<String, Object?> object(String key) => _field<Map<String, Object?>>(key);

  Map<String, Object?>? optObject(String key) => _field<Map<String, Object?>?>(key);

  List<Object?> list(String key) => _field<List<Object?>>(key);

  List<Object?>? optList(String key) => _field<List<Object?>?>(key);

  List<String> strings(String key) => _elements<String>(key, list(key));

  List<String>? optStrings(String key) {
    final values = optList(key);
    return values == null ? null : _elements<String>(key, values);
  }

  List<int> integers(String key) => _elements<int>(key, list(key));

  List<Map<String, Object?>> objects(String key) => _elements<Map<String, Object?>>(key, list(key));

  List<Map<String, Object?>>? optObjects(String key) {
    final values = optList(key);
    return values == null ? null : _elements<Map<String, Object?>>(key, values);
  }

  /// Milliseconds as a [Duration]; omp sends plain JSON numbers, which may be fractional.
  Duration? optMilliseconds(String key) {
    final value = optNumber(key);
    return value == null ? null : Duration(microseconds: (value * 1000).round());
  }

  T _field<T>(String key) {
    final value = this[key];
    if (value is T) return value;
    throw FormatException('"$key": expected $T, got ${describeJson(value)}');
  }

  List<T> _elements<T>(String key, List<Object?> values) => [
    for (final (index, value) in values.indexed)
      if (value is T) value else throw FormatException('"$key[$index]": expected $T, got ${describeJson(value)}'),
  ];
}

/// The value of [values] named [name], or a [FormatException].
T enumByName<T extends Enum>(List<T> values, String name) =>
    values.asNameMap()[name] ??
    (throw FormatException('unknown value "$name"; expected one of ${values.map((v) => v.name).join(', ')}'));

/// Parses [value] as a JSON object, or throws a [FormatException].
Map<String, Object?> asJsonObject(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$what: expected a JSON object, got ${describeJson(value)}');
}

String describeJson(Object? value) => switch (value) {
  null => 'nothing',
  String() => 'a string',
  bool() => 'a boolean',
  num() => 'a number',
  List() => 'an array',
  Map() => 'an object',
  _ => value.runtimeType.toString(),
};
