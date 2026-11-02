package core

import (
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestPaths(t *testing.T) {
	base := t.TempDir()
	t.Setenv("OMPCORE_DATA_DIR", filepath.Join(base, "data", "nested"))
	t.Setenv("OMPCORE_CACHE_DIR", filepath.Join(base, "cache"))
	h := newHarness(t)
	paths := okInto[map[string]string](h, "core.paths", nil)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"data": sftpPath(filepath.Join(base, "data", "nested")),
		"cache": sftpPath(filepath.Join(base, "cache")), "home": sftpPath(home)}
	if !maps.Equal(paths, want) {
		t.Fatalf("core.paths = %v, want %v", paths, want)
	}
	for _, dir := range []string{paths["data"], paths["cache"]} {
		// Windows has no POSIX permissions: Go reports a directory's as 0777.
		info, err := os.Stat(nativePath(dir))
		if err != nil || !info.IsDir() || runtime.GOOS != "windows" && info.Mode().Perm() != 0o700 {
			t.Fatalf("%s: %v %v", dir, info, err)
		}
	}
	t.Setenv("ENV_TEST_SET", "ü")
	env := okInto[struct{ Env map[string]string }](h, "core.env", map[string][]string{"names": {"ENV_TEST_SET", "ENV_TEST_UNSET"}})
	if len(env.Env) != 1 || env.Env["ENV_TEST_SET"] != "ü" {
		t.Fatalf("core.env = %v", env.Env)
	}
}

func TestSFTPPathSpace(t *testing.T) {
	for _, tc := range []struct{ native, sftp string }{
		{`C:\Users\me`, "/C:/Users/me"},
		{`C:\`, "/C:/"},
		{`d:\x y\z`, "/d:/x y/z"},
		{`\\server\share`, "//server/share"},
	} {
		if got := toSFTPPath(tc.native, true); got != tc.sftp {
			t.Errorf("toSFTPPath(%q) = %q, want %q", tc.native, got, tc.sftp)
		}
		if got := fromSFTPPath(tc.sftp, true); got != tc.native {
			t.Errorf("fromSFTPPath(%q) = %q, want %q", tc.sftp, got, tc.native)
		}
	}
	if got := fromSFTPPath("/C:", true); got != `C:\` {
		t.Errorf("fromSFTPPath(/C:) = %q", got)
	}
	if got := fromSFTPPath("/home/me", false); got != "/home/me" {
		t.Errorf("POSIX paths changed: %q", got)
	}
}

func TestStore(t *testing.T) {
	data := t.TempDir()
	t.Setenv("OMPCORE_DATA_DIR", data)
	t.Setenv("OMPCORE_CACHE_DIR", t.TempDir())
	h := newHarness(t)
	type read struct {
		Text *string `json:"text"`
	}
	if got := okInto[read](h, "store.read", map[string]string{"name": "machines"}); got.Text != nil {
		t.Fatalf("a missing document reads %q", *got.Text)
	}
	h.ok("store.write", map[string]string{"name": "machines", "text": `[{"name":"ü"}]`})
	if got := okInto[read](h, "store.read", map[string]string{"name": "machines"}); got.Text == nil || *got.Text != `[{"name":"ü"}]` {
		t.Fatalf("read back %v", got.Text)
	}

	// Writers racing on one document: it ends as one of them wrote it, and no temporary file is left.
	var texts []string
	var wg sync.WaitGroup
	for i := range 50 {
		text := fmt.Sprintf(`{"writer":%d,"pad":%q}`, i, strings.Repeat("x", 10_000*(i%5)))
		texts = append(texts, text)
		wg.Go(func() { h.ok("store.write", map[string]string{"name": "settings", "text": text}) })
	}
	wg.Wait()
	if got := okInto[read](h, "store.read", map[string]string{"name": "settings"}); got.Text == nil || !slices.Contains(texts, *got.Text) {
		t.Fatal("racing writes left a document none of them wrote")
	}
	entries, err := os.ReadDir(filepath.Join(data, "store"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if !slices.Equal(names, []string{"machines.json", "settings.json"}) {
		t.Fatalf("store holds %v", names)
	}

	h.ok("store.delete", map[string]string{"name": "machines"})
	h.ok("store.delete", map[string]string{"name": "machines"})
	if got := okInto[read](h, "store.read", map[string]string{"name": "machines"}); got.Text != nil {
		t.Fatal("a deleted document still reads")
	}
	for _, name := range []string{"", "../x", "a/b", ".hidden", strings.Repeat("n", 101)} {
		if m := h.call("store.write", map[string]string{"name": name, "text": "x"}); m.Error == nil {
			t.Fatalf("store.write accepted the name %q", name)
		}
	}
}
