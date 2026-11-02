//go:build darwin || linux

package core

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

func b64(text string) string { return base64.StdEncoding.EncodeToString([]byte(text)) }

type statResult struct {
	Size        int64  `json:"size"`
	IsDirectory bool   `json:"isDirectory"`
	IsLink      bool   `json:"isLink"`
	ModifiedMs  *int64 `json:"modifiedMs"`
	Mode        uint32 `json:"mode"`
}

func TestFiles(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("OMPCORE_CACHE_DIR", cache)
	t.Setenv("OMPCORE_DATA_DIR", t.TempDir())
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := newHarness(t)
	fileSuite(t, h, "local", filepath.Join(home, "local"), cache)

	server := startServer(t, serverOptions{password: "pw", home: home})
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)
	if got := okInto[struct{ Path string }](h, "fs.home", map[string]string{"machine": machine}); got.Path != home {
		t.Fatalf("fs.home over SFTP = %q, want %q", got.Path, home)
	}
	fileSuite(t, h, machine, filepath.Join(home, "sftp"), cache)

	// A broken SFTP client is opened again.
	m, err := h.core.machine(machine)
	if err != nil {
		t.Fatal(err)
	}
	m.sftpMu.Lock()
	broken := m.sftp
	m.sftpMu.Unlock()
	if err := broken.Close(); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		m.sftpMu.Lock()
		gone := m.sftp == nil
		m.sftpMu.Unlock()
		if gone {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the closed SFTP client was not dropped")
		}
	}
	if got := okInto[struct{ Stat *statResult }](h, "fs.stat", map[string]string{"machine": machine, "path": home}); got.Stat == nil || !got.Stat.IsDirectory {
		t.Fatalf("fs.stat after the SFTP client broke: %+v", got.Stat)
	}
	h.ok("ssh.close", map[string]string{"machine": machine})
	h.fails("fs.stat", map[string]string{"machine": machine, "path": home}, "closed")
}

// fileSuite checks fs.* on machine in root, a directory it creates; cache is the core's cache directory.
func fileSuite(t *testing.T, h *harness, machine, root, cache string) {
	t.Helper()
	at := func(params map[string]any) map[string]any {
		params["machine"] = machine
		return params
	}
	read := func(path string, extra map[string]any) string {
		t.Helper()
		extra["path"] = path
		got := okInto[struct{ Data string }](h, "fs.read", at(extra))
		data, err := base64.StdEncoding.DecodeString(got.Data)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	stat := func(path string, follow bool) *statResult {
		t.Helper()
		return okInto[struct{ Stat *statResult }](h, "fs.stat", at(map[string]any{"path": path, "followLinks": follow})).Stat
	}

	h.ok("fs.mkdir", at(map[string]any{"path": root}))
	file := root + "/a.txt"
	h.ok("fs.write", at(map[string]any{"path": file, "data": b64("hello")}))
	h.ok("fs.write", at(map[string]any{"path": file, "data": b64(" world"), "append": true}))
	if got := read(file, map[string]any{}); got != "hello world" {
		t.Fatalf("%s: read %q", machine, got)
	}
	if got := read(file, map[string]any{"offset": 6, "length": 3}); got != "wor" {
		t.Fatalf("%s: read at 6 for 3: %q", machine, got)
	}
	if got := read(file, map[string]any{"offset": 6}); got != "world" {
		t.Fatalf("%s: read from 6: %q", machine, got)
	}
	if got := read(file, map[string]any{"offset": 50}); got != "" {
		t.Fatalf("%s: read past the end: %q", machine, got)
	}
	if s := stat(file, true); s == nil || s.Size != 11 || s.IsDirectory || s.Mode&0o170000 != 0o100000 ||
		s.ModifiedMs == nil || time.Since(time.UnixMilli(*s.ModifiedMs)) > time.Hour {
		t.Fatalf("%s: stat %+v", machine, s)
	}

	// mode applies on creation only.
	secret := root + "/secret"
	h.ok("fs.write", at(map[string]any{"path": secret, "data": b64("one"), "mode": 0o600}))
	h.ok("fs.write", at(map[string]any{"path": secret, "data": b64("two"), "mode": 0o644}))
	if s := stat(secret, true); s.Mode&0o777 != 0o600 || read(secret, map[string]any{}) != "two" {
		t.Fatalf("%s: secret mode %o", machine, s.Mode)
	}

	// mkdir is an atomic lock.
	dir := root + "/d"
	h.ok("fs.mkdir", at(map[string]any{"path": dir, "mode": 0o700}))
	if s := stat(dir, true); !s.IsDirectory || s.Mode != 0o040700 {
		t.Fatalf("%s: dir %+v", machine, s)
	}
	if m := h.fails("fs.mkdir", at(map[string]any{"path": dir}), "exists"); m.Error.Message != "already exists: "+dir {
		t.Fatalf("%s: mkdir of an existing dir: %s", machine, m.Error.Message)
	}

	// Links describe themselves unless followed.
	link := root + "/link"
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	if s := stat(link, false); !s.IsLink || s.IsDirectory {
		t.Fatalf("%s: lstat of a link %+v", machine, s)
	}
	if s := stat(link, true); s.IsLink || !s.IsDirectory {
		t.Fatalf("%s: stat through a link %+v", machine, s)
	}
	entries := okInto[struct {
		Entries []struct {
			Name string     `json:"name"`
			Stat statResult `json:"stat"`
		}
	}](h, "fs.list", at(map[string]any{"path": root})).Entries
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name)
		if entry.Name == "link" && (!entry.Stat.IsLink || entry.Stat.IsDirectory) {
			t.Fatalf("%s: list followed the link: %+v", machine, entry.Stat)
		}
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"a.txt", "d", "link", "secret"}) {
		t.Fatalf("%s: list %v", machine, names)
	}

	// Missing paths.
	missing := root + "/missing"
	if s := stat(missing, true); s != nil {
		t.Fatalf("%s: stat of a missing file %+v", machine, s)
	}
	h.fails("fs.read", at(map[string]any{"path": missing}), "missing")
	h.fails("fs.remove", at(map[string]any{"path": missing}), "missing")
	h.fails("fs.write", at(map[string]any{"path": missing + "/x", "data": b64("x")}), "missing")

	// touch sets the modification time; SFTP carries whole seconds.
	h.ok("fs.touch", at(map[string]any{"path": file, "modifiedMs": 1_700_000_000_000}))
	if s := stat(file, true); s.ModifiedMs == nil || *s.ModifiedMs != 1_700_000_000_000 {
		t.Fatalf("%s: modifiedMs after touch: %v", machine, s.ModifiedMs)
	}
	h.fails("fs.touch", at(map[string]any{"path": missing, "modifiedMs": 0}), "missing")

	// rename replaces the target.
	h.ok("fs.write", at(map[string]any{"path": root + "/b.txt", "data": b64("old")}))
	h.ok("fs.rename", at(map[string]any{"from": file, "to": root + "/b.txt"}))
	if read(root+"/b.txt", map[string]any{}) != "hello world" || stat(file, false) != nil {
		t.Fatalf("%s: rename over an existing file", machine)
	}

	// Removing a link leaves its target.
	h.ok("fs.remove", at(map[string]any{"path": link}))
	if stat(link, false) != nil || stat(dir, true) == nil {
		t.Fatalf("%s: removing the link", machine)
	}
	h.ok("fs.removeDir", at(map[string]any{"path": dir}))
	if stat(dir, true) != nil {
		t.Fatalf("%s: removeDir left %s", machine, dir)
	}

	// download copies into the cache under a stable name keeping the extension.
	type downloaded struct {
		URL  string `json:"url"`
		Size int64  `json:"size"`
	}
	first := okInto[downloaded](h, "fs.download", at(map[string]any{"path": root + "/b.txt"}))
	again := okInto[downloaded](h, "fs.download", at(map[string]any{"path": root + "/b.txt"}))
	if !regexp.MustCompile(`^cache/[0-9a-f]{24}\.txt$`).MatchString(first.URL) || first.Size != 11 || again != first {
		t.Fatalf("%s: download %+v, again %+v", machine, first, again)
	}
	if data, err := os.ReadFile(filepath.Join(cache, strings.TrimPrefix(first.URL, "cache/"))); err != nil ||
		string(data) != "hello world" {
		t.Fatalf("%s: the cached file holds %q (%v)", machine, data, err)
	}
	h.fails("fs.download", at(map[string]any{"path": missing}), "missing")

	// upload streams a cache file onto the machine: created with mode, or truncated.
	big := make([]byte, 5<<20+123)
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cache, "upload.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	uploaded := root + "/uploaded.bin"
	type sized struct {
		Size int64 `json:"size"`
	}
	got := okInto[sized](h, "fs.upload", at(map[string]any{"path": uploaded, "cache": "upload.bin", "mode": 0o600}))
	if data, err := os.ReadFile(uploaded); got.Size != int64(len(big)) || err != nil || !bytes.Equal(data, big) {
		t.Fatalf("%s: upload of %d bytes answered %+v and wrote %d bytes (%v)", machine, len(big), got, len(data), err)
	}
	if s := stat(uploaded, true); s.Mode&0o777 != 0o600 {
		t.Fatalf("%s: uploaded file mode %o, want 600", machine, s.Mode&0o777)
	}
	if err := os.WriteFile(filepath.Join(cache, "short.txt"), []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := okInto[sized](h, "fs.upload", at(map[string]any{"path": uploaded, "cache": "short.txt"})); got.Size != 5 ||
		read(uploaded, map[string]any{}) != "short" {
		t.Fatalf("%s: upload over a longer file: %+v, file %q", machine, got, read(uploaded, map[string]any{}))
	}
	h.fails("fs.upload", at(map[string]any{"path": uploaded, "cache": "absent.bin"}), "missing")
	h.fails("fs.upload", at(map[string]any{"path": missing + "/x", "cache": "short.txt"}), "missing")
	for _, name := range []string{"../upload.bin", "a/short.txt", ""} {
		if m := h.call("fs.upload", at(map[string]any{"path": uploaded, "cache": name})); m.Error == nil {
			t.Fatalf("%s: upload of cache %q answered %s", machine, name, m.raw)
		}
	}
}

// echoServer echoes each connection's bytes and closes once the client's side ended.
func echoServer(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				io.Copy(conn, conn)
				conn.Close()
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func TestNet(t *testing.T) {
	echo := echoServer(t)
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)

	for _, from := range []string{"local", machine} {
		stream := h.open("net.connect", map[string]any{"machine": from, "host": "127.0.0.1", "port": echo})
		sent := []byte{0, 0xff, 'p', 'i', 'n', 'g'}
		h.ok("stream.write", map[string]string{"stream": stream, "data": base64.StdEncoding.EncodeToString(sent)})
		h.ok("stream.closeStdin", map[string]string{"stream": stream})
		if got, exit := h.drainBytes(stream); !bytes.Equal(got, sent) || exit.Params.Code == nil || *exit.Params.Code != 0 {
			t.Fatalf("net.connect from %s: %q (%s)", from, got, exit.raw)
		}

		forward := okInto[struct {
			Forward   string `json:"forward"`
			LocalPort int    `json:"localPort"`
		}](h, "net.forward", map[string]any{"machine": from, "host": "127.0.0.1", "port": echo})
		conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", forward.LocalPort))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Write([]byte("forwarded")); err != nil {
			t.Fatal(err)
		}
		conn.(*net.TCPConn).CloseWrite()
		if got, err := io.ReadAll(conn); err != nil || string(got) != "forwarded" {
			t.Fatalf("net.forward from %s: %q (%v)", from, got, err)
		}
		conn.Close()
		h.ok("net.forwardClose", map[string]string{"forward": forward.Forward})
		if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", forward.LocalPort)); err == nil {
			conn.Close()
			t.Fatalf("net.forward from %s still listens after net.forwardClose", from)
		}
	}

	// A forward ends with its machine.
	forward := okInto[struct {
		LocalPort int `json:"localPort"`
	}](h, "net.forward", map[string]any{"machine": machine, "host": "127.0.0.1", "port": echo})
	h.ok("ssh.close", map[string]string{"machine": machine})
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", forward.LocalPort)); err == nil {
		conn.Close()
		t.Fatal("the forward outlived its machine")
	}

	h.fails("net.connect", map[string]any{"machine": "local", "host": "127.0.0.1", "port": 1}, "unreachable")
}

func TestFetch(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("OMPCORE_CACHE_DIR", cache)
	t.Setenv("OMPCORE_DATA_DIR", t.TempDir())
	limit, most, stall := fetchLimit, fetchMax, fetchStall
	fetchLimit, fetchMax, fetchStall = 1000, 5000, 200*time.Millisecond
	t.Cleanup(func() { fetchLimit, fetchMax, fetchStall = limit, most, stall })
	png := []byte("\x89PNG\r\n\x1a\nnot really")
	web := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/pic.png":
			w.Header().Set("Content-Type", "image/png")
			w.Write(png)
		case "/data":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.Write([]byte(`{}`))
		case "/big":
			w.Header().Set("Content-Type", "application/octet-stream")
			// Streamed without a length, so only reading it finds it too big.
			w.(http.Flusher).Flush()
			w.Write(bytes.Repeat([]byte("x"), 2000))
		case "/stall":
			w.Write([]byte("a start"))
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(web.Close)
	h := newHarness(t)
	type fetched struct {
		URL      string `json:"url"`
		Name     string `json:"name"`
		Size     int64  `json:"size"`
		MimeType string `json:"mimeType"`
		SHA256   string `json:"sha256"`
	}
	digest := func(data []byte) string {
		sum := sha256.Sum256(data)
		return hex.EncodeToString(sum[:])
	}
	got := okInto[fetched](h, "net.fetch", map[string]string{"url": web.URL + "/pic.png"})
	data, err := os.ReadFile(filepath.Join(cache, got.Name))
	if !strings.HasSuffix(got.Name, ".png") || got.URL != "cache/"+got.Name || got.MimeType != "image/png" ||
		got.Size != int64(len(png)) || got.SHA256 != digest(png) || err != nil || !bytes.Equal(data, png) {
		t.Fatalf("net.fetch: %+v (%v)", got, err)
	}
	if got := okInto[fetched](h, "net.fetch", map[string]string{"url": web.URL + "/data"}); got.MimeType != "application/json" ||
		!strings.HasSuffix(got.URL, ".json") || got.SHA256 != digest([]byte(`{}`)) {
		t.Fatalf("net.fetch without an extension: %+v", got)
	}
	for _, path := range []string{"/big", "/missing"} {
		if m := h.call("net.fetch", map[string]string{"url": web.URL + path}); m.Error == nil {
			t.Fatalf("net.fetch %s answered %s", path, m.raw)
		}
	}
	// maxBytes raises the limit, up to fetchMax.
	if got := okInto[fetched](h, "net.fetch", map[string]any{"url": web.URL + "/big", "maxBytes": 3000}); got.Size != 2000 ||
		got.SHA256 != digest(bytes.Repeat([]byte("x"), 2000)) {
		t.Fatalf("net.fetch with maxBytes: %+v", got)
	}
	for _, maxBytes := range []int{1500, 6000, -1} {
		if m := h.call("net.fetch", map[string]any{"url": web.URL + "/big", "maxBytes": maxBytes}); m.Error == nil {
			t.Fatalf("net.fetch with maxBytes %d answered %s", maxBytes, m.raw)
		}
	}
	// A download that stops moving fails.
	if m := h.call("net.fetch", map[string]string{"url": web.URL + "/stall"}); m.Error == nil ||
		!strings.Contains(m.Error.Message, "no data for 200ms") {
		t.Fatalf("a stalled net.fetch answered %s", m.raw)
	}
	entries, err := os.ReadDir(cache)
	if err != nil || len(entries) != 3 {
		t.Fatalf("the cache holds %v (%v), want the three fetched files only", entries, err)
	}
}
