package core

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"slices"
	"strings"
	"unicode/utf16"
)

// sqlite.read reads every table of a SQLite database without SQLite (https://www.sqlite.org/fileformat2.html): the
// Flutter app's database, once, to import it. It reads the files and never writes or locks them; a hot rollback
// journal or a WAL next to the database is applied in memory, as SQLite would on opening it.

func sqliteRead(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Path string `json:"path"`
	}](params)
	if err != nil {
		return nil, err
	}
	tables, err := readSQLite(nativePath(p.Path))
	if err != nil {
		return nil, err
	}
	return map[string]any{"tables": tables}, nil
}

// readSQLite returns the rows of every table in the database at path, by table name.
func readSQLite(path string) (map[string][]map[string]any, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, withCode("missing", err)
	}
	if err != nil {
		return nil, err
	}
	journal, err := readIfExists(path + "-journal")
	if err != nil {
		return nil, err
	}
	// SQLite ignores the journal or WAL of an empty database.
	if len(journal) > 0 && len(data) > 0 {
		if data, err = rollback(data, journal); err != nil {
			return nil, fmt.Errorf("%s-journal: %w", path, err)
		}
	}
	wal, err := readIfExists(path + "-wal")
	if err != nil {
		return nil, err
	}
	if len(wal) > 0 && len(data) > 0 {
		if data, err = applyWAL(data, wal); err != nil {
			return nil, fmt.Errorf("%s-wal: %w", path, err)
		}
	}
	tables, err := sqliteTables(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return tables, nil
}

func readIfExists(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return data, err
}

func malformed(format string, args ...any) error {
	return withCode("malformed", fmt.Errorf(format, args...))
}

var journalMagic = []byte{0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7}

// rollback returns the database as it was before the transaction a hot journal belongs to: the journal's pages
// written back and the file cut to its size then. It follows SQLite's pager_playback: segments, each a header at a
// sector boundary and its page records, until a header without the magic; a record that fails its checksum ends the
// playback, as one SQLite never synced. A journal whose first header has no magic is not hot and changes nothing.
func rollback(data, journal []byte) ([]byte, error) {
	var pageSize, sectorSize int
	var originalPages uint32
	for offset := 0; offset+28 <= len(journal) && bytes.Equal(journal[offset:offset+8], journalMagic); {
		records := binary.BigEndian.Uint32(journal[offset+8:])
		nonce := binary.BigEndian.Uint32(journal[offset+12:])
		if offset == 0 {
			originalPages = binary.BigEndian.Uint32(journal[16:])
			sectorSize = int(binary.BigEndian.Uint32(journal[20:]))
			pageSize = int(binary.BigEndian.Uint32(journal[24:]))
			if !powerOfTwo(pageSize, 512, 65536) || !powerOfTwo(sectorSize, 32, 65536) {
				return nil, malformed("header: page size %d or sector size %d is not a power of two in range",
					pageSize, sectorSize)
			}
			if int64(originalPages)*int64(pageSize) > int64(len(data)+len(journal)) {
				return nil, malformed("header: the database had %d pages, more than the files hold", originalPages)
			}
			if size := int(originalPages) * pageSize; size <= len(data) {
				data = data[:size]
			} else {
				data = append(data, make([]byte, size-len(data))...)
			}
		}
		at := offset + sectorSize
		if records == 0xffffffff {
			records = uint32(max(0, len(journal)-at) / (pageSize + 8))
		}
		for range records {
			if at+pageSize+8 > len(journal) {
				return data, nil
			}
			page := binary.BigEndian.Uint32(journal[at:])
			content := journal[at+4 : at+4+pageSize]
			checksum := binary.BigEndian.Uint32(journal[at+4+pageSize:])
			at += pageSize + 8
			if page == 0 || journalChecksum(nonce, content) != checksum {
				return data, nil
			}
			if page <= originalPages {
				copy(data[int(page-1)*pageSize:], content)
			}
		}
		offset = (at + sectorSize - 1) / sectorSize * sectorSize
	}
	return data, nil
}

// journalChecksum is a journal record's checksum: the header's nonce plus every 200th byte of the page from its end.
func journalChecksum(nonce uint32, page []byte) uint32 {
	for i := len(page) - 200; i > 0; i -= 200 {
		nonce += uint32(page[i])
	}
	return nonce
}

func powerOfTwo(n, low, high int) bool {
	return n >= low && n <= high && n&(n-1) == 0
}

// applyWAL returns the database with the WAL's committed frames written over it, cut or grown to the size the last
// commit gives. Frames count while their salts match the header's and their running checksum holds; those after the
// last commit frame are a transaction that never committed. A WAL whose header is not valid holds nothing, as for
// SQLite.
func applyWAL(data, wal []byte) ([]byte, error) {
	if len(wal) < 32 {
		return data, nil
	}
	magic := binary.BigEndian.Uint32(wal)
	if magic&^1 != 0x377f0682 {
		return data, nil
	}
	if version := binary.BigEndian.Uint32(wal[4:]); version != 3007000 {
		return nil, malformed("WAL format version %d is not 3007000", version)
	}
	pageSize := int(binary.BigEndian.Uint32(wal[8:]))
	if !powerOfTwo(pageSize, 512, 65536) {
		return data, nil
	}
	var order binary.ByteOrder = binary.LittleEndian
	if magic&1 == 1 {
		order = binary.BigEndian
	}
	s0, s1 := walChecksum(order, 0, 0, wal[:24])
	if s0 != binary.BigEndian.Uint32(wal[24:]) || s1 != binary.BigEndian.Uint32(wal[28:]) {
		return data, nil
	}
	salts := wal[16:24]
	pending := map[uint32][]byte{}
	committed := map[uint32][]byte{}
	var pages uint32
	for at := 32; at+24+pageSize <= len(wal); at += 24 + pageSize {
		page := binary.BigEndian.Uint32(wal[at:])
		if page == 0 || !bytes.Equal(wal[at+8:at+16], salts) {
			break
		}
		content := wal[at+24 : at+24+pageSize]
		s0, s1 = walChecksum(order, s0, s1, wal[at:at+8])
		s0, s1 = walChecksum(order, s0, s1, content)
		if s0 != binary.BigEndian.Uint32(wal[at+16:]) || s1 != binary.BigEndian.Uint32(wal[at+20:]) {
			break
		}
		pending[page] = content
		if commit := binary.BigEndian.Uint32(wal[at+4:]); commit != 0 {
			for page, content := range pending {
				committed[page] = content
			}
			clear(pending)
			pages = commit
		}
	}
	if pages == 0 {
		return data, nil
	}
	size := int64(pages) * int64(pageSize)
	if size > int64(len(data)+len(wal)) {
		return nil, malformed("the last commit gives %d pages, more than the files hold", pages)
	}
	image := make([]byte, size)
	copy(image, data)
	for page, content := range committed {
		if page <= pages {
			copy(image[int(page-1)*pageSize:], content)
		}
	}
	return image, nil
}

// walChecksum continues the WAL's running checksum over b, read as 32-bit words in order.
func walChecksum(order binary.ByteOrder, s0, s1 uint32, b []byte) (uint32, uint32) {
	for i := 0; i+8 <= len(b); i += 8 {
		s0 += order.Uint32(b[i:]) + s1
		s1 += order.Uint32(b[i+4:]) + s0
	}
	return s0, s1
}

// sqliteFile is a database image: its pages back to back.
type sqliteFile struct {
	data     []byte
	pageSize int
	// usable is the page size less the bytes reserved at each page's end.
	usable int
	pages  uint32
	// utf16 is the byte order of the database's text, nil for UTF-8.
	utf16 binary.ByteOrder
	// used marks the pages read so far: a page belongs to one b-tree or overflow chain, so a second use is a loop.
	used []bool
}

// sqliteTables reads every table of the database image data. An empty file is an empty database.
func sqliteTables(data []byte) (map[string][]map[string]any, error) {
	tables := map[string][]map[string]any{}
	if len(data) == 0 {
		return tables, nil
	}
	f, err := openSQLite(data)
	if err != nil {
		return nil, err
	}
	type entry struct {
		name string
		root uint32
		sql  string
	}
	var entries []entry
	err = f.walk(1, false, 0, func(_ int64, payload []byte) error {
		values, err := f.record(payload)
		if err != nil {
			return err
		}
		if len(values) < 5 {
			return malformed("a row has %d values, not 5", len(values))
		}
		kind, _ := values[0].(string)
		name, nameOK := values[1].(string)
		root, rootOK := values[3].(int64)
		sql, _ := values[4].(string)
		if kind != "table" {
			return nil
		}
		if !nameOK || !rootOK || root < 0 || root > int64(f.pages) {
			return malformed("table %v has root page %v", values[1], values[3])
		}
		// A virtual table has no b-tree of its own.
		if root > 0 {
			entries = append(entries, entry{name, uint32(root), sql})
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("sqlite_schema: %w", err)
	}
	for _, e := range entries {
		table, err := parseCreateTable(e.sql)
		if err != nil {
			return nil, fmt.Errorf("table %s: %w", e.name, err)
		}
		rows := []map[string]any{}
		err = f.walk(e.root, table.withoutRowid, 0, func(rowid int64, payload []byte) error {
			values, err := f.record(payload)
			if err != nil {
				return err
			}
			if len(values) > len(table.stored) {
				return malformed("a row has %d values for %d columns", len(values), len(table.stored))
			}
			row := make(map[string]any, len(table.columns))
			for _, name := range table.columns {
				row[name] = nil
			}
			for i, value := range values {
				row[table.columns[table.stored[i]]] = value
			}
			if table.alias >= 0 {
				row[table.columns[table.alias]] = rowid
			}
			rows = append(rows, row)
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("table %s: %w", e.name, err)
		}
		tables[e.name] = rows
	}
	return tables, nil
}

func openSQLite(data []byte) (*sqliteFile, error) {
	if len(data) < 100 || string(data[:16]) != "SQLite format 3\x00" {
		return nil, malformed("not a SQLite database: no \"SQLite format 3\" header")
	}
	pageSize := int(binary.BigEndian.Uint16(data[16:]))
	if pageSize == 1 {
		pageSize = 65536
	}
	if !powerOfTwo(pageSize, 512, 65536) {
		return nil, malformed("header: page size %d is not a power of two from 512 to 65536", pageSize)
	}
	if data[19] > 2 {
		return nil, malformed("header: file format read version %d is newer than 2", data[19])
	}
	usable := pageSize - int(data[20])
	if usable < 480 {
		return nil, malformed("header: %d reserved bytes leave %d usable bytes a page", data[20], usable)
	}
	if data[21] != 64 || data[22] != 32 || data[23] != 32 {
		return nil, malformed("header: payload fractions %d/%d/%d are not 64/32/32", data[21], data[22], data[23])
	}
	if format := binary.BigEndian.Uint32(data[44:]); format > 4 {
		return nil, malformed("header: schema format %d is newer than 4", format)
	}
	if len(data) < pageSize {
		return nil, malformed("the file's %d bytes are less than one %d-byte page", len(data), pageSize)
	}
	f := &sqliteFile{data: data, pageSize: pageSize, usable: usable, pages: uint32(len(data) / pageSize)}
	switch encoding := binary.BigEndian.Uint32(data[56:]); encoding {
	case 0, 1: // 0: no text written yet
	case 2:
		f.utf16 = binary.LittleEndian
	case 3:
		f.utf16 = binary.BigEndian
	default:
		return nil, malformed("header: text encoding %d is not 1, 2 or 3", encoding)
	}
	f.used = make([]bool, f.pages+1)
	return f, nil
}

// page returns page n's usable bytes, once.
func (f *sqliteFile) page(n uint32) ([]byte, error) {
	if n == 0 || n > f.pages {
		return nil, malformed("page %d is outside the file's %d pages", n, f.pages)
	}
	if f.used[n] {
		return nil, malformed("page %d is used twice", n)
	}
	f.used[n] = true
	start := int(n-1) * f.pageSize
	return f.data[start : start+f.usable], nil
}

// maxDepth is SQLite's own limit on a b-tree's depth (BTCURSOR_MAX_DEPTH).
const maxDepth = 20

// walk calls visit with every entry of the b-tree rooted at page n in key order: a table b-tree's rows with their
// rowids, or an index b-tree's records (a WITHOUT ROWID table's rows), whose interior pages hold entries too.
func (f *sqliteFile) walk(n uint32, index bool, depth int, visit func(rowid int64, payload []byte) error) error {
	if depth > maxDepth {
		return malformed("page %d: the b-tree is deeper than %d pages", n, maxDepth)
	}
	data, err := f.page(n)
	if err != nil {
		return err
	}
	header := 0
	if n == 1 {
		header = 100
	}
	kind := data[header]
	leaf, interior, tree := byte(13), byte(5), "table"
	if index {
		leaf, interior, tree = 10, 2, "index"
	}
	pointers := header + 8
	if kind == interior {
		pointers = header + 12
	} else if kind != leaf {
		return malformed("page %d has type %d where a %s b-tree page belongs", n, kind, tree)
	}
	count := int(binary.BigEndian.Uint16(data[header+3:]))
	if pointers+2*count > len(data) {
		return malformed("page %d: its %d cells do not fit", n, count)
	}
	for i := range count {
		at := int(binary.BigEndian.Uint16(data[pointers+2*i:]))
		if at < pointers+2*count || at >= len(data) {
			return malformed("page %d: cell %d starts outside the cell area", n, i)
		}
		cell := data[at:]
		var rowid int64
		if kind == interior {
			if len(cell) < 4 {
				return malformed("page %d: cell %d runs past the page", n, i)
			}
			if err := f.walk(binary.BigEndian.Uint32(cell), index, depth+1, visit); err != nil {
				return err
			}
			if !index {
				continue
			}
			cell = cell[4:]
		}
		size, used := varint(cell)
		if used == 0 {
			return malformed("page %d: cell %d runs past the page", n, i)
		}
		cell = cell[used:]
		if !index {
			key, used := varint(cell)
			if used == 0 {
				return malformed("page %d: cell %d runs past the page", n, i)
			}
			rowid, cell = int64(key), cell[used:]
		}
		payload, err := f.payload(n, cell, size, index)
		if err != nil {
			return err
		}
		if err := visit(rowid, payload); err != nil {
			return err
		}
	}
	if kind == interior {
		return f.walk(binary.BigEndian.Uint32(data[header+8:]), index, depth+1, visit)
	}
	return nil
}

// payload returns a cell's payload of size bytes: what the cell holds on page n, then its overflow chain.
func (f *sqliteFile) payload(n uint32, cell []byte, size uint64, index bool) ([]byte, error) {
	maxLocal := f.usable - 35
	if index {
		maxLocal = (f.usable-12)*64/255 - 23
	}
	if size <= uint64(maxLocal) {
		if size > uint64(len(cell)) {
			return nil, malformed("page %d: a cell runs past the page", n)
		}
		return cell[:size], nil
	}
	minLocal := (f.usable-12)*32/255 - 23
	local := minLocal + int((size-uint64(minLocal))%uint64(f.usable-4))
	if local > maxLocal {
		local = minLocal
	}
	if local+4 > len(cell) {
		return nil, malformed("page %d: a cell runs past the page", n)
	}
	if size > uint64(local)+uint64(f.pages)*uint64(f.usable-4) {
		return nil, malformed("page %d: a cell's %d bytes are more than the file holds", n, size)
	}
	payload := make([]byte, 0, size)
	payload = append(payload, cell[:local]...)
	next := binary.BigEndian.Uint32(cell[local:])
	for uint64(len(payload)) < size {
		if next == 0 {
			return nil, malformed("page %d: a cell's overflow chain ends %d bytes short", n, size-uint64(len(payload)))
		}
		overflow, err := f.page(next)
		if err != nil {
			return nil, err
		}
		take := min(uint64(f.usable-4), size-uint64(len(payload)))
		payload = append(payload, overflow[4:4+take]...)
		next = binary.BigEndian.Uint32(overflow)
	}
	return payload, nil
}

// record decodes a record: INTEGER as int64, REAL as float64 (an infinity as SQLite's json() writes it, a NaN as
// nil), TEXT as string, BLOB as base64, NULL as nil.
func (f *sqliteFile) record(payload []byte) ([]any, error) {
	headerSize, used := varint(payload)
	if used == 0 || headerSize < uint64(used) || headerSize > uint64(len(payload)) {
		return nil, malformed("a record's %d-byte header does not fit its %d bytes", headerSize, len(payload))
	}
	header, body := payload[used:headerSize], payload[headerSize:]
	var values []any
	for len(header) > 0 {
		serial, used := varint(header)
		if used == 0 {
			return nil, malformed("a record's header ends inside a serial type")
		}
		header = header[used:]
		var size uint64
		switch {
		case serial <= 4:
			size = serial
		case serial == 5:
			size = 6
		case serial == 6 || serial == 7:
			size = 8
		case serial == 10 || serial == 11:
			return nil, malformed("a record holds reserved serial type %d", serial)
		case serial >= 12:
			size = (serial - 12) / 2
		}
		if size > uint64(len(body)) {
			return nil, malformed("a record's values run past its end")
		}
		value := body[:size]
		body = body[size:]
		switch {
		case serial == 0:
			values = append(values, nil)
		case serial <= 6:
			number := int64(int8(value[0]))
			for _, b := range value[1:] {
				number = number<<8 | int64(b)
			}
			values = append(values, number)
		case serial == 7:
			values = append(values, jsonFloat(math.Float64frombits(binary.BigEndian.Uint64(value))))
		case serial == 8 || serial == 9:
			values = append(values, int64(serial-8))
		case serial%2 == 0:
			values = append(values, base64.StdEncoding.EncodeToString(value))
		default:
			values = append(values, f.text(value))
		}
	}
	return values, nil
}

// jsonFloat is a REAL as JSON can carry it: an infinity as 9e999, which JSON.parse reads as Infinity (SQLite's json()
// writes it so), and a NaN, which SQLite never stores, as nil.
func jsonFloat(value float64) any {
	switch {
	case math.IsNaN(value):
		return nil
	case math.IsInf(value, 1):
		return json.RawMessage("9e999")
	case math.IsInf(value, -1):
		return json.RawMessage("-9e999")
	}
	return value
}

func (f *sqliteFile) text(b []byte) string {
	if f.utf16 == nil {
		return string(b)
	}
	// SQLite drops a trailing odd byte of UTF-16 text too.
	units := make([]uint16, len(b)/2)
	for i := range units {
		units[i] = f.utf16.Uint16(b[2*i:])
	}
	return string(utf16.Decode(units))
}

// varint decodes a SQLite varint and returns its length, 0 when b ends inside it.
func varint(b []byte) (uint64, int) {
	var value uint64
	for i := range min(len(b), 8) {
		value = value<<7 | uint64(b[i]&0x7f)
		if b[i] < 0x80 {
			return value, i + 1
		}
	}
	if len(b) < 9 {
		return 0, 0
	}
	return value<<8 | uint64(b[8]), 9
}

// sqliteTable is what reading a table's rows needs of its CREATE TABLE statement.
type sqliteTable struct {
	columns []string
	// alias is the index of the column that is the rowid (INTEGER PRIMARY KEY), or -1.
	alias int
	// stored lists the columns in the order a record holds them: the primary key first in a WITHOUT ROWID table.
	stored       []int
	withoutRowid bool
}

type sqlToken struct {
	text string
	// quoted: a quoted name or a string, never a keyword or punctuation.
	quoted bool
}

func (t sqlToken) is(word string) bool { return !t.quoted && strings.EqualFold(t.text, word) }

// columnConstraints are the keywords that end a column's type.
var columnConstraints = []string{"CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
	"REFERENCES", "GENERATED", "AS"}

// parseCreateTable reads just enough of a CREATE TABLE statement: its column names in order, the rowid alias, the
// primary key's columns and WITHOUT ROWID.
func parseCreateTable(sql string) (sqliteTable, error) {
	table := sqliteTable{alias: -1}
	tokens, err := sqlTokens(sql)
	if err != nil {
		return table, err
	}
	open := -1
	for i, t := range tokens {
		if t.is("(") {
			open = i
			break
		}
	}
	if open < 0 {
		return table, malformed("its SQL has no column list: %q", sql)
	}
	definitions, end := splitList(tokens[open+1:])
	if end < 0 {
		return table, malformed("its SQL's column list is not closed: %q", sql)
	}
	rest := tokens[open+1+end+1:]
	for i := 0; i+1 < len(rest); i++ {
		if rest[i].is("WITHOUT") && rest[i+1].is("ROWID") {
			table.withoutRowid = true
		}
	}
	var types []string
	var key []string
	columnKey := -1
	descending := false
	for _, definition := range definitions {
		if len(definition) == 0 {
			return table, malformed("its SQL has an empty column definition: %q", sql)
		}
		if definition[0].is("CONSTRAINT") && len(definition) > 2 {
			definition = definition[2:]
		}
		switch first := definition[0]; {
		case first.is("PRIMARY"):
			for i, t := range definition {
				if t.is("(") {
					items, _ := splitList(definition[i+1:])
					for _, item := range items {
						if len(item) > 0 {
							key = append(key, item[0].text)
						}
					}
					break
				}
			}
		case first.is("UNIQUE") || first.is("CHECK") || first.is("FOREIGN"):
		default:
			table.columns = append(table.columns, first.text)
			// The type runs up to the first constraint keyword outside parentheses: `INTEGER(8)` is not `INTEGER`.
			typeEnd, depth := len(definition), 0
			for i := 1; i < len(definition); i++ {
				t := definition[i]
				if t.is("(") {
					depth++
				} else if t.is(")") {
					depth--
				} else if depth == 0 && slices.ContainsFunc(columnConstraints, t.is) {
					typeEnd = min(typeEnd, i)
					if t.is("PRIMARY") {
						columnKey = len(table.columns) - 1
						key = []string{first.text}
						descending = i+2 < len(definition) && definition[i+2].is("DESC")
					}
				}
			}
			var typeWords []string
			for _, t := range definition[1:typeEnd] {
				typeWords = append(typeWords, t.text)
			}
			types = append(types, strings.Join(typeWords, " "))
		}
	}
	if len(table.columns) == 0 {
		return table, malformed("its SQL has no columns: %q", sql)
	}
	keyColumns := make([]int, 0, len(key))
	for _, name := range key {
		i := slices.IndexFunc(table.columns, func(column string) bool { return strings.EqualFold(column, name) })
		if i < 0 {
			return table, malformed("its primary key names no column %q", name)
		}
		if !slices.Contains(keyColumns, i) {
			keyColumns = append(keyColumns, i)
		}
	}
	if table.withoutRowid {
		if len(keyColumns) == 0 {
			return table, malformed("a WITHOUT ROWID table needs a primary key: %q", sql)
		}
		table.stored = keyColumns
		for i := range table.columns {
			if !slices.Contains(keyColumns, i) {
				table.stored = append(table.stored, i)
			}
		}
		return table, nil
	}
	// INTEGER PRIMARY KEY DESC on the column itself is not an alias: a quirk SQLite keeps.
	if len(keyColumns) == 1 && strings.EqualFold(types[keyColumns[0]], "INTEGER") &&
		!(columnKey == keyColumns[0] && descending) {
		table.alias = keyColumns[0]
	}
	for i := range table.columns {
		table.stored = append(table.stored, i)
	}
	return table, nil
}

// splitList splits tokens after an opening parenthesis at its top-level commas, up to the closing parenthesis, and
// returns that parenthesis's index, -1 when the list is not closed.
func splitList(tokens []sqlToken) (items [][]sqlToken, end int) {
	depth, start := 0, 0
	for i, t := range tokens {
		switch {
		case t.is("("):
			depth++
		case t.is(")") && depth > 0:
			depth--
		case t.is(")"):
			return append(items, tokens[start:i]), i
		case t.is(",") && depth == 0:
			items = append(items, tokens[start:i])
			start = i + 1
		}
	}
	return items, -1
}

// sqlTokens splits SQL into words, quoted names and strings (unquoted), and single punctuation characters, without
// whitespace and comments.
func sqlTokens(sql string) ([]sqlToken, error) {
	var tokens []sqlToken
	for i := 0; i < len(sql); {
		c := sql[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f':
			i++
		case strings.HasPrefix(sql[i:], "--"):
			end := strings.IndexByte(sql[i:], '\n')
			if end < 0 {
				end = len(sql) - i
			}
			i += end
		case strings.HasPrefix(sql[i:], "/*"):
			end := strings.Index(sql[i+2:], "*/")
			if end < 0 {
				end = len(sql) - i - 4
			}
			i += end + 4
		case c == '"' || c == '\'' || c == '`' || c == '[':
			closing := c
			if c == '[' {
				closing = ']'
			}
			var text strings.Builder
			j := i + 1
			for {
				k := strings.IndexByte(sql[j:], closing)
				if k < 0 {
					return nil, malformed("its SQL has an unclosed %c: %q", c, sql)
				}
				text.WriteString(sql[j : j+k])
				j += k + 1
				// A doubled quote is one quote character, except in brackets.
				if closing == ']' || j >= len(sql) || sql[j] != closing {
					break
				}
				text.WriteByte(closing)
				j++
			}
			tokens = append(tokens, sqlToken{text: text.String(), quoted: true})
			i = j
		case isWordByte(c):
			j := i
			for j < len(sql) && isWordByte(sql[j]) {
				j++
			}
			tokens = append(tokens, sqlToken{text: sql[i:j]})
			i = j
		default:
			tokens = append(tokens, sqlToken{text: sql[i : i+1]})
			i++
		}
	}
	return tokens, nil
}

func isWordByte(c byte) bool {
	return c == '_' || c == '$' || c >= 0x80 || '0' <= c && c <= '9' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z'
}
