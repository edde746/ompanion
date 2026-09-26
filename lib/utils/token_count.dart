/// [tokens] for people: `950`, `1.2K`, `128K`, `1M`, `1.5M`; one decimal unless the value is whole in its unit.
String formatTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  // Rounded to tenths of the unit first, so 999,960 reads `1M` rather than `1000K`.
  final tenthsOfK = (tokens / 100).round();
  final (tenths, unit) = tenthsOfK < 10000 ? (tenthsOfK, 'K') : ((tokens / 100000).round(), 'M');
  final whole = tenths ~/ 10;
  final decimal = tenths % 10;
  return decimal == 0 ? '$whole$unit' : '$whole.$decimal$unit';
}
