#!/bin/sh
# Writes the SQLite fixtures of sqlite_test.go with the sqlite3 CLI (3.33 or later). Pages are 512 bytes to keep the
# files small. Run it after changing what a fixture holds, and the tests after that.
#   types.sqlite              every serial type, rowid aliases, overflow chains, a three-level table b-tree,
#                             WITHOUT ROWID tables (one with overflowing interior cells), sqlite_sequence
#   utf16le.sqlite, utf16be.sqlite   a table in each UTF-16 encoding
#   hot.sqlite(-journal)      copied mid-transaction: the database holds uncommitted pages, the journal the originals
#   wal.sqlite(-wal)          a WAL with three commits and the frames of one uncommitted transaction after them
set -eu
cd "$(dirname "$0")"
rm -f ./*.sqlite ./*.sqlite-journal ./*.sqlite-wal work.sqlite*

sqlite3 types.sqlite << 'EOF'
PRAGMA page_size=512;
CREATE TABLE types(id INTEGER PRIMARY KEY, v);
INSERT INTO types(id, v) VALUES (1, NULL), (2, 0), (3, 1), (4, -100), (5, 1000), (6, -100000), (7, 100000000),
  (8, -100000000000), (9, 9223372036854775807), (10, -9223372036854775808), (11, 1.5), (12, -0.25), (13, 1e999),
  (14, -1e999), (15, x''), (16, x'00ff10'), (17, ''), (18, 'héllo ☃ 😀');
CREATE INDEX types_v ON types(v);
CREATE VIEW types_view AS SELECT v FROM types;
CREATE TABLE quirk(id INTEGER PRIMARY KEY DESC, v TEXT);
INSERT INTO quirk VALUES (5, 'five'), (3, 'three');
CREATE TABLE aliased(name TEXT, n INTEGER, PRIMARY KEY(n DESC));
INSERT INTO aliased VALUES ('ten', 10), ('minus three', -3);
CREATE TABLE "odd ""name"""([a,b] TEXT /* c, d */, "x(y)" INTEGER -- z, (
  , `w``v` DEFAULT ('p,q'), CONSTRAINT pk PRIMARY KEY ("x(y)"));
INSERT INTO "odd ""name""" VALUES ('A', 7, 'W');
CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
INSERT INTO seq(v) VALUES ('one'), ('two');
CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT, data BLOB);
INSERT INTO notes VALUES (1, replace(printf('%.400c', '*'), '*', 'overflow '),
  CAST(replace(printf('%.250c', '*'), '*', '01234567') AS BLOB));
INSERT INTO notes VALUES (2, 'short', NULL);
INSERT INTO notes VALUES (3, printf('%.472c', 'b'), NULL), (4, printf('%.473c', 'b'), NULL);
INSERT INTO notes VALUES (5, printf('%.595c', 'c'), NULL), (6, printf('%.1000c', 'd'), x'ff');
CREATE TABLE big(n INTEGER, s TEXT);
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 2000)
  INSERT INTO big SELECT n, printf('row %05d', n) FROM c;
CREATE TABLE wr(b TEXT, a INTEGER, c, PRIMARY KEY(a, b)) WITHOUT ROWID;
WITH RECURSIVE c(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM c WHERE n < 499)
  INSERT INTO wr SELECT 'b' || (n % 3), n * 7 % 500, n FROM c;
CREATE TABLE wrlong(k INTEGER PRIMARY KEY, t TEXT) WITHOUT ROWID;
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 30)
  INSERT INTO wrlong SELECT n, printf('%.300c', char(64 + n)) FROM c;
EOF

for order in le be; do
  sqlite3 "utf16$order.sqlite" << EOF
PRAGMA encoding='UTF-16$order';
PRAGMA page_size=512;
CREATE TABLE "tâble"(id INTEGER PRIMARY KEY, s TEXT);
INSERT INTO "tâble" VALUES (1, 'héllo ☃ 😀'), (2, replace(printf('%.300c', '*'), '*', 'ß☃'));
EOF
done

# A cache of 10 pages makes the transaction spill pages before it commits: into the database file, after the journal
# holds their originals, or into the WAL as frames without a commit.
sqlite3 work.sqlite << 'EOF'
PRAGMA page_size=512;
CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT);
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 100) INSERT INTO t SELECT n, 'before ' || n FROM c;
PRAGMA cache_size=10;
BEGIN;
UPDATE t SET s = 'after ' || id;
WITH RECURSIVE c(n) AS (SELECT 101 UNION ALL SELECT n + 1 FROM c WHERE n < 1000) INSERT INTO t SELECT n, 'new ' || n FROM c;
.shell cp work.sqlite hot.sqlite && cp work.sqlite-journal hot.sqlite-journal
ROLLBACK;
EOF
rm -f work.sqlite*

sqlite3 work.sqlite << 'EOF'
PRAGMA page_size=512;
PRAGMA journal_mode=WAL;
PRAGMA wal_autocheckpoint=0;
CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT);
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 100) INSERT INTO t SELECT n, 'first ' || n FROM c;
UPDATE t SET s = 'second ' || id;
PRAGMA cache_size=10;
BEGIN;
UPDATE t SET s = 'uncommitted ' || id;
WITH RECURSIVE c(n) AS (SELECT 101 UNION ALL SELECT n + 1 FROM c WHERE n < 1000) INSERT INTO t SELECT n, 'new ' || n FROM c;
.shell cp work.sqlite wal.sqlite && cp work.sqlite-wal wal.sqlite-wal
ROLLBACK;
EOF
rm -f work.sqlite*
ls -l
