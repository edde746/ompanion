#!/bin/sh
# Writes expected.json, fixtures/flutter-v{1,2}.sqlite and fixtures/expected-v{1,2}.json from seed_data.dart with
# fixtures.dart, in a temporary Dart package holding drift's generated schemas v1 and v2 of commit 359d920 and the drift
# and sqlite3 versions of its pubspec.lock. Run it after changing seed_data.dart. fixtures/flutter-v3.sqlite is not
# made here: it is the database of a macOS seed run (README.md).
set -eu

commit=359d920
here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
dart=/Users/edde/Documents/flutter/bin/dart
[ -x "$dart" ] || dart=dart

work=$(mktemp -d "${TMPDIR:-/tmp}/flutter-seed-fixtures.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$repo" archive "$commit" pubspec.lock test/drift/app_database/generated/schema_v1.dart \
  test/drift/app_database/generated/schema_v2.dart | tar -x -C "$work"
version() { sed -n "/^  $1:\$/,/^    version:/s/^    version: \"\(.*\)\"/\1/p" "$work/pubspec.lock"; }
cat > "$work/pubspec.yaml" << EOF
name: flutter_seed_fixtures
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
  drift: $(version drift)
  sqlite3: $(version sqlite3)
EOF
cp "$work"/test/drift/app_database/generated/schema_v[12].dart "$here/seed_data.dart" "$here/fixtures.dart" "$work/"
mkdir -p "$here/fixtures"
cd "$work"
"$dart" pub get > /dev/null
# A zone west of UTC with summer time: the v1/v2 files hold "-05:00" and "-04:00" offsets, where a seed run in Europe
# writes "+01:00" and "+02:00".
TZ=America/New_York "$dart" run fixtures.dart "$here"
