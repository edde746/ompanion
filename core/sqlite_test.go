package core

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// The fixtures come from testdata/sqlite/make.sh.

func readFixture(t *testing.T, path string) map[string][]map[string]any {
	t.Helper()
	tables, err := readSQLite(path)
	if err != nil {
		t.Fatal(err)
	}
	return tables
}

func fixture(name string) string { return filepath.Join("testdata", "sqlite", name) }

// copyFixture copies the named fixture files into a temporary directory, as name with each one's suffix, and returns
// the database's path there.
func copyFixture(t *testing.T, name string, suffixes ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, suffix := range append([]string{""}, suffixes...) {
		data, err := os.ReadFile(fixture(name + suffix))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name+suffix), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(dir, name)
}

func codeOf(err error) string {
	var coded *codedError
	if errors.As(err, &coded) {
		return coded.code
	}
	return ""
}

func wantRows(t *testing.T, tables map[string][]map[string]any, table string, want []map[string]any) {
	t.Helper()
	got, ok := tables[table]
	if !ok {
		t.Fatalf("no table %q in %v", table, slices.Sorted(maps.Keys(tables)))
	}
	if len(got) != len(want) {
		t.Fatalf("%s: %d rows, want %d", table, len(got), len(want))
	}
	for i := range want {
		if !reflect.DeepEqual(got[i], want[i]) {
			t.Fatalf("%s row %d = %v, want %v", table, i, got[i], want[i])
		}
	}
}

func TestSQLiteSerialTypes(t *testing.T) {
	tables := readFixture(t, fixture("types.sqlite"))
	values := []any{nil, int64(0), int64(1), int64(-100), int64(1000), int64(-100000), int64(100000000),
		int64(-100000000000), int64(math.MaxInt64), int64(math.MinInt64), 1.5, -0.25, json.RawMessage("9e999"),
		json.RawMessage("-9e999"), "", "AP8Q", "", "héllo ☃ 😀"}
	var want []map[string]any
	for i, v := range values {
		want = append(want, map[string]any{"id": int64(i + 1), "v": v})
	}
	wantRows(t, tables, "types", want)
}

func TestSQLiteTables(t *testing.T) {
	tables := readFixture(t, fixture("types.sqlite"))
	names := slices.Sorted(maps.Keys(tables))
	want := []string{"aliased", "big", "notes", `odd "name"`, "quirk", "seq", "sqlite_sequence", "types", "wr", "wrlong"}
	if !slices.Equal(names, want) {
		t.Fatalf("tables %q, want %q (no index, no view)", names, want)
	}
	wantRows(t, tables, "seq", []map[string]any{{"id": int64(1), "v": "one"}, {"id": int64(2), "v": "two"}})
	wantRows(t, tables, "sqlite_sequence", []map[string]any{{"name": "seq", "seq": int64(2)}})
}

func TestSQLiteRowidAlias(t *testing.T) {
	tables := readFixture(t, fixture("types.sqlite"))
	// INTEGER PRIMARY KEY DESC on the column is not an alias: the rowids are 1 and 2.
	wantRows(t, tables, "quirk", []map[string]any{{"id": int64(5), "v": "five"}, {"id": int64(3), "v": "three"}})
	wantRows(t, tables, "aliased", []map[string]any{{"name": "minus three", "n": int64(-3)}, {"name": "ten", "n": int64(10)}})
	wantRows(t, tables, `odd "name"`, []map[string]any{{"a,b": "A", "x(y)": int64(7), "w`v": "W"}})
}

func TestSQLiteOverflow(t *testing.T) {
	tables := readFixture(t, fixture("types.sqlite"))
	wantRows(t, tables, "notes", []map[string]any{
		{"id": int64(1), "body": strings.Repeat("overflow ", 400),
			"data": base64.StdEncoding.EncodeToString([]byte(strings.Repeat("01234567", 250)))},
		{"id": int64(2), "body": "short", "data": nil},
		{"id": int64(3), "body": strings.Repeat("b", 472), "data": nil},
		{"id": int64(4), "body": strings.Repeat("b", 473), "data": nil},
		{"id": int64(5), "body": strings.Repeat("c", 595), "data": nil},
		{"id": int64(6), "body": strings.Repeat("d", 1000), "data": "/w=="},
	})
}

// treeDepth returns the depth of the b-tree rooted at the table's root page, following first children.
func treeDepth(t *testing.T, path, table string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	f, err := openSQLite(data)
	if err != nil {
		t.Fatal(err)
	}
	var page uint32
	err = f.walk(1, false, 0, func(_ int64, payload []byte) error {
		values, err := f.record(payload)
		if err == nil && values[0] == "table" && values[1] == table {
			page = uint32(values[3].(int64))
		}
		return err
	})
	if err != nil || page == 0 {
		t.Fatalf("no root page for %s: %v", table, err)
	}
	for depth := 1; ; depth++ {
		at := int(page-1) * f.pageSize
		if kind := data[at]; kind != 2 && kind != 5 {
			return depth
		}
		first := int(binary.BigEndian.Uint16(data[at+12:]))
		page = binary.BigEndian.Uint32(data[at+first:])
	}
}

func TestSQLiteInteriorPages(t *testing.T) {
	if depth := treeDepth(t, fixture("types.sqlite"), "big"); depth < 3 {
		t.Fatalf("big's b-tree is %d deep, want 3 or more", depth)
	}
	tables := readFixture(t, fixture("types.sqlite"))
	var want []map[string]any
	for n := int64(1); n <= 2000; n++ {
		want = append(want, map[string]any{"n": n, "s": fmt.Sprintf("row %05d", n)})
	}
	wantRows(t, tables, "big", want)
}

func TestSQLiteWithoutRowid(t *testing.T) {
	for _, table := range []string{"wr", "wrlong"} {
		if depth := treeDepth(t, fixture("types.sqlite"), table); depth < 2 {
			t.Fatalf("%s's b-tree is %d deep, want interior pages", table, depth)
		}
	}
	tables := readFixture(t, fixture("types.sqlite"))
	// Rows come in primary key order (a, b), where make.sh inserted them in n order.
	want := make([]map[string]any, 500)
	for n := range int64(500) {
		want[n*7%500] = map[string]any{"a": n * 7 % 500, "b": fmt.Sprintf("b%d", n%3), "c": n}
	}
	wantRows(t, tables, "wr", want)
	want = nil
	for k := int64(1); k <= 30; k++ {
		want = append(want, map[string]any{"k": k, "t": strings.Repeat(string(rune(64+k)), 300)})
	}
	wantRows(t, tables, "wrlong", want)
}

func TestParseCreateTable(t *testing.T) {
	for sql, want := range map[string]sqliteTable{
		`CREATE TABLE t("id" integer primary key, v)`:                {[]string{"id", "v"}, 0, []int{0, 1}, false},
		`CREATE TABLE t(id INTEGER(8) PRIMARY KEY, v)`:               {[]string{"id", "v"}, -1, []int{0, 1}, false},
		`CREATE TABLE t(id INT PRIMARY KEY, v)`:                      {[]string{"id", "v"}, -1, []int{0, 1}, false},
		`CREATE TABLE t(v, id INTEGER CONSTRAINT k PRIMARY KEY ASC)`: {[]string{"v", "id"}, 1, []int{0, 1}, false},
		`CREATE TABLE t(a DECIMAL(10, 2) NOT NULL, b, c, PRIMARY KEY(c, a COLLATE nocase, c)) WITHOUT ROWID`: {
			[]string{"a", "b", "c"}, -1, []int{2, 0, 1}, true},
	} {
		got, err := parseCreateTable(sql)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %+v %v, want %+v", sql, got, err, want)
		}
	}
}

func TestSQLiteUTF16(t *testing.T) {
	for _, name := range []string{"utf16le.sqlite", "utf16be.sqlite"} {
		wantRows(t, readFixture(t, fixture(name)), "tâble", []map[string]any{
			{"id": int64(1), "s": "héllo ☃ 😀"},
			{"id": int64(2), "s": strings.Repeat("ß☃", 300)},
		})
	}
}

func TestSQLiteHotJournal(t *testing.T) {
	var want []map[string]any
	for n := int64(1); n <= 100; n++ {
		want = append(want, map[string]any{"id": n, "s": fmt.Sprintf("before %d", n)})
	}
	path := copyFixture(t, "hot.sqlite", "-journal")
	wantRows(t, readFixture(t, path), "t", want)
	// The files stay as they were: the rollback happened in memory.
	for _, suffix := range []string{"", "-journal"} {
		original, _ := os.ReadFile(fixture("hot.sqlite" + suffix))
		after, _ := os.ReadFile(path + suffix)
		if !bytes.Equal(original, after) {
			t.Fatalf("hot.sqlite%s changed", suffix)
		}
	}

	// Without the journal the file holds the transaction's pages: a test of nothing if it read the same.
	alone := copyFixture(t, "hot.sqlite")
	tables, err := readSQLite(alone)
	if err == nil && reflect.DeepEqual(tables["t"], want) {
		t.Fatal("hot.sqlite reads the same without its journal")
	}
	// A journal whose header has no magic is not hot.
	journal, _ := os.ReadFile(path + "-journal")
	clear(journal[:8])
	if err := os.WriteFile(alone+"-journal", journal, 0o600); err != nil {
		t.Fatal(err)
	}
	cold, coldErr := readSQLite(alone)
	if !reflect.DeepEqual(cold, tables) || fmt.Sprint(coldErr) != fmt.Sprint(err) {
		t.Fatalf("a journal without magic was applied: %v, %d rows", coldErr, len(cold["t"]))
	}
}

// walFrames returns each WAL frame's commit field (0: not a commit), for the frames with the header's salts.
func walFrames(wal []byte) []uint32 {
	pageSize := int(binary.BigEndian.Uint32(wal[8:]))
	var commits []uint32
	for at := 32; at+24+pageSize <= len(wal) && bytes.Equal(wal[at+8:at+16], wal[16:24]); at += 24 + pageSize {
		commits = append(commits, binary.BigEndian.Uint32(wal[at+4:]))
	}
	return commits
}

func TestSQLiteWAL(t *testing.T) {
	rows := func(prefix string) []map[string]any {
		var rows []map[string]any
		for n := int64(1); n <= 100; n++ {
			rows = append(rows, map[string]any{"id": n, "s": fmt.Sprintf("%s %d", prefix, n)})
		}
		return rows
	}
	wal, err := os.ReadFile(fixture("wal.sqlite-wal"))
	if err != nil {
		t.Fatal(err)
	}
	frames := walFrames(wal)
	var commits []int
	for i, commit := range frames {
		if commit != 0 {
			commits = append(commits, i)
		}
	}
	if len(commits) != 3 || commits[2] == len(frames)-1 {
		t.Fatalf("wal.sqlite-wal has commit frames %v of %d: want 3 and uncommitted frames after them", commits, len(frames))
	}

	path := copyFixture(t, "wal.sqlite", "-wal")
	wantRows(t, readFixture(t, path), "t", rows("second"))
	if after, _ := os.ReadFile(path + "-wal"); !bytes.Equal(after, wal) {
		t.Fatal("wal.sqlite-wal changed")
	}
	// Every row lives in the WAL.
	if tables := readFixture(t, copyFixture(t, "wal.sqlite")); len(tables) != 0 {
		t.Fatalf("wal.sqlite alone has tables %v", tables)
	}

	// A last commit whose checksum or salt fails is not committed: the one before it wins.
	pageSize := int(binary.BigEndian.Uint32(wal[8:]))
	last := 32 + commits[2]*(24+pageSize)
	for name, at := range map[string]int{"checksum": last + 24 + 100, "salt": last + 8} {
		broken := slices.Clone(wal)
		broken[at] ^= 0xff
		if err := os.WriteFile(path+"-wal", broken, 0o600); err != nil {
			t.Fatal(err)
		}
		tables, err := readSQLite(path)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		wantRows(t, tables, "t", rows("first"))
	}
}

func TestSQLiteMalformed(t *testing.T) {
	dir := t.TempDir()
	if _, err := readSQLite(filepath.Join(dir, "none.sqlite")); codeOf(err) != "missing" {
		t.Fatalf("a missing file: %v", err)
	}

	types, err := os.ReadFile(fixture("types.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty.sqlite")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if tables, err := readSQLite(empty); err != nil || len(tables) != 0 {
		t.Fatalf("an empty file is an empty database: %v %v", tables, err)
	}

	root := func(table string) int {
		f, _ := openSQLite(types)
		var page int
		_ = f.walk(1, false, 0, func(_ int64, payload []byte) error {
			values, _ := f.record(payload)
			if values[0] == "table" && values[1] == table {
				page = int(values[3].(int64))
			}
			return nil
		})
		return page
	}
	big := (root("big") - 1) * 512
	notATree := slices.Clone(types)
	notATree[big] = 0
	loop := slices.Clone(types)
	binary.BigEndian.PutUint32(loop[big+8:], uint32(root("big")))
	cases := map[string][]byte{
		"text":      bytes.Repeat([]byte("not a database\n"), 100),
		"1 byte":    types[:1],
		"99 bytes":  types[:99],
		"100 bytes": types[:100],
		"511 bytes": types[:511],
		"one page":  types[:512],
		"two pages": types[:1024],
		"half":      types[:len(types)/2],
		"type 0":    notATree,
		"loop":      loop,
	}
	for name, data := range cases {
		path := filepath.Join(dir, "case.sqlite")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := readSQLite(path)
		if codeOf(err) != "malformed" || !strings.Contains(err.Error(), path) {
			t.Fatalf("%s: %v, want a malformed error naming the file", name, err)
		}
		t.Logf("%s: %v", name, err)
	}
}

func TestSQLiteRequest(t *testing.T) {
	h := newHarness(t)
	path, err := filepath.Abs(fixture("types.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	result := h.ok("sqlite.read", map[string]any{"path": sftpPath(path)})
	if !bytes.Contains(result, []byte(`{"id":13,"v":9e999}`)) || !bytes.HasPrefix(result, []byte(`{"tables":{`)) {
		t.Fatalf("sqlite.read answered %.300s", result)
	}
	h.fails("sqlite.read", map[string]any{"path": sftpPath(path + ".none")}, "missing")
	h.fails("sqlite.read", map[string]any{"path": sftpPath(fixture("make.sh"))}, "malformed")
}

// TestSQLiteFlutterSeed reads the Flutter app's databases of schema v1 to v3 (harness/flutter-seed) and, where the
// sqlite3 CLI is installed, compares every table with what it reads.
func TestSQLiteFlutterSeed(t *testing.T) {
	dir := filepath.Join("..", "harness", "flutter-seed", "fixtures")
	if _, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
		t.Skip("no harness/flutter-seed in this copy")
	}
	cli, cliErr := exec.LookPath("sqlite3")
	for _, version := range []string{"v1", "v2", "v3"} {
		path := filepath.Join(dir, "flutter-"+version+".sqlite")
		tables := readFixture(t, path)
		var summary []string
		for _, name := range slices.Sorted(maps.Keys(tables)) {
			summary = append(summary, fmt.Sprintf("%s %d", name, len(tables[name])))
		}
		if cliErr != nil {
			t.Logf("flutter-%s: %s (no sqlite3 to compare with)", version, strings.Join(summary, ", "))
			continue
		}
		out, err := exec.Command(cli, "-readonly", path, "SELECT name FROM sqlite_schema WHERE type = 'table'").Output()
		if err != nil {
			t.Fatal(err)
		}
		names := strings.Fields(string(out))
		if len(names) != len(tables) {
			t.Fatalf("flutter-%s: sqlite3 lists tables %v, sqlite.read %d", version, names, len(tables))
		}
		for _, name := range names {
			out, err := exec.Command(cli, "-readonly", "-json", path, `SELECT * FROM "`+name+`"`).Output()
			if err != nil {
				t.Fatal(err)
			}
			if got, want := canonicalRows(t, tables[name]), canonicalRows(t, out); !slices.Equal(got, want) {
				t.Fatalf("flutter-%s %s:\n got %q\nwant %q", version, name, got, want)
			}
		}
		t.Logf("flutter-%s: %s, each table the same as %s reads it", version, strings.Join(summary, ", "), cli)
	}
}

// canonicalRows returns rows (Go values, or sqlite3's JSON output) as sorted JSON objects.
func canonicalRows(t *testing.T, rows any) []string {
	t.Helper()
	data, ok := rows.([]byte)
	if !ok {
		var err error
		if data, err = json.Marshal(rows); err != nil {
			t.Fatal(err)
		}
	}
	var decoded []map[string]any
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &decoded); err != nil {
			t.Fatal(err)
		}
	}
	var out []string
	for _, row := range decoded {
		encoded, _ := json.Marshal(row)
		out = append(out, string(encoded))
	}
	slices.Sort(out)
	return out
}

// FuzzSQLite feeds databases, journals and WALs derived from the fixtures to the reader, which may only fail with a
// malformed error.
func FuzzSQLite(f *testing.F) {
	for _, name := range []string{"types.sqlite", "utf16le.sqlite", "hot.sqlite", "wal.sqlite"} {
		db, _ := os.ReadFile(fixture(name))
		journal, _ := os.ReadFile(fixture(name + "-journal"))
		wal, _ := os.ReadFile(fixture(name + "-wal"))
		f.Add(db, journal, wal)
	}
	f.Fuzz(func(t *testing.T, db, journal, wal []byte) {
		db = slices.Clone(db)
		var err error
		if len(journal) > 0 && len(db) > 0 {
			db, err = rollback(db, journal)
		}
		if err == nil && len(wal) > 0 && len(db) > 0 {
			db, err = applyWAL(db, wal)
		}
		if err == nil {
			_, err = sqliteTables(db)
		}
		if err != nil && codeOf(err) != "malformed" {
			t.Fatalf("an error without the malformed code: %v", err)
		}
	})
}

// FuzzCreateTable feeds CREATE TABLE statements to their parser, which may only fail with a malformed error.
func FuzzCreateTable(f *testing.F) {
	f.Add(`CREATE TABLE "odd ""name"""([a,b] TEXT /* c, d */, "x(y)" INTEGER -- z, (
  , ` + "`w``v`" + ` DEFAULT ('p,q'), CONSTRAINT pk PRIMARY KEY ("x(y)"))`)
	f.Add(`CREATE TABLE wr(b TEXT, a INTEGER, c, PRIMARY KEY(a, b)) WITHOUT ROWID`)
	f.Add(`CREATE TABLE quirk(id INTEGER PRIMARY KEY DESC, v TEXT)`)
	f.Fuzz(func(t *testing.T, sql string) {
		table, err := parseCreateTable(sql)
		if err != nil {
			if codeOf(err) != "malformed" {
				t.Fatalf("an error without the malformed code: %v", err)
			}
			return
		}
		if len(table.stored) != len(table.columns) || table.alias >= len(table.columns) {
			t.Fatalf("%q: %+v", sql, table)
		}
	})
}
