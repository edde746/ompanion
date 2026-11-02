package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func dial(ctx context.Context, t *testing.T, url, origin string) (*websocket.Conn, error) {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: http.Header{"Origin": {origin}}})
	return conn, err
}

func TestBridge(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	server := httptest.NewServer(newBridge().handler(""))
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/bridge"

	if _, err := dial(ctx, t, url, "https://example.com"); err == nil {
		t.Fatal("a page from another site connected")
	}
	first, err := dial(ctx, t, url, "http://localhost:5173")
	if err != nil {
		t.Fatal(err)
	}
	defer first.CloseNow()
	// A round trip on the first connection makes sure it took over before the next one connects.
	if err := first.Write(ctx, websocket.MessageText, []byte(`{"id":0,"method":"core.echo"}`)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := first.Read(ctx); err != nil {
		t.Fatal(err)
	}
	// The latest connection takes over the core.
	conn, err := dial(ctx, t, url, "http://127.0.0.1:5173")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	send := func(text string) {
		if err := conn.Write(ctx, websocket.MessageText, []byte(text)); err != nil {
			t.Fatal(err)
		}
	}
	read := func() map[string]any {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(data, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	send(`{"id":1,"method":"core.info"}`)
	if m := read(); m["id"] != 1.0 || m["result"].(map[string]any)["goos"] != runtime.GOOS {
		t.Fatalf("core.info answered %v", m)
	}
	if runtime.GOOS == "windows" {
		send(`{"id":2,"method":"local.exec","params":{"argv":["cmd","/c","echo bridge-ok"]}}`)
	} else {
		send(`{"id":2,"method":"local.exec","params":{"argv":["sh","-c","echo bridge-ok"]}}`)
	}
	m := read()
	stream := m["result"].(map[string]any)["stream"]
	var out strings.Builder
	for {
		m := read()
		params := m["params"].(map[string]any)
		if params["stream"] != stream {
			t.Fatalf("event of another stream: %v", m)
		}
		if m["event"] == "stream.exit" {
			if params["code"] != 0.0 || strings.TrimSpace(out.String()) != "bridge-ok" {
				t.Fatalf("local.exec printed %q and exited %v", out.String(), m)
			}
			break
		}
		out.WriteString(params["data"].(string))
	}

	// shell.* never reaches the core.
	send(`{"id":3,"method":"shell.info"}`)
	if m := read(); m["id"] != 3.0 || m["result"].(map[string]any)["platform"] != platform() ||
		m["result"].(map[string]any)["push"] != false {
		t.Fatalf("shell.info answered %v", m)
	}
	send(`{"id":4,"method":"shell.secretSet","params":{"key":"k","value":"wert ü"}}`)
	read()
	send(`{"id":5,"method":"shell.secretGet","params":{"key":"k"}}`)
	if m := read(); m["result"].(map[string]any)["value"] != "wert ü" {
		t.Fatalf("shell.secretGet answered %v", m)
	}
	send(`{"id":6,"method":"shell.secretDelete","params":{"key":"k"}}`)
	read()
	send(`{"id":7,"method":"shell.secretGet","params":{"key":"k"}}`)
	if m := read(); m["result"].(map[string]any)["value"] != nil {
		t.Fatalf("shell.secretGet after delete answered %v", m)
	}
	send(`{"id":8,"method":"shell.insets"}`)
	if m := read(); m["result"].(map[string]any)["keyboard"] != 0.0 {
		t.Fatalf("shell.insets answered %v", m)
	}
	send(`{"id":9,"method":"shell.nope"}`)
	if m := read(); m["error"] == nil {
		t.Fatalf("an unknown shell method answered %v", m)
	}
}

func TestFlutterData(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ompanion.sqlite")
	secrets := filepath.Join(dir, "secrets.json")
	t.Setenv("OMPCORE_FLUTTER_DB", db)
	t.Setenv("OMPCORE_FLUTTER_SECRETS", secrets)
	b := newBridge()
	answer := func(method string) string {
		var m map[string]any
		if err := json.Unmarshal(b.shell(1, method, nil), &m); err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(m["result"])
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}

	if got := answer("shell.flutterData"); got != `{"database":null,"secrets":{}}` {
		t.Fatalf("without files shell.flutterData answered %s", got)
	}
	for _, name := range []string{"ompanion.sqlite", "ompanion.sqlite-journal"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(secrets, []byte(`{"password.m1":"Pässwörd"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	want, err := json.Marshal(map[string]any{"database": db, "secrets": map[string]string{"password.m1": "Pässwörd"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := answer("shell.flutterData"); got != string(want) {
		t.Fatalf("shell.flutterData answered %s, want %s", got, want)
	}

	if got := answer("shell.flutterDataClear"); got != "{}" {
		t.Fatalf("shell.flutterDataClear answered %s", got)
	}
	for name, want := range map[string]string{
		"ompanion.sqlite.imported":         "ompanion.sqlite",
		"ompanion.sqlite-journal.imported": "ompanion.sqlite-journal",
	} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || string(data) != want {
			t.Fatalf("%s: %q, %v", name, data, err)
		}
	}
	if got := answer("shell.flutterData"); got != `{"database":null,"secrets":{}}` {
		t.Fatalf("after shell.flutterDataClear shell.flutterData answered %s", got)
	}
}

func TestPush(t *testing.T) {
	b := newBridge()
	answer := func(method, params string) map[string]any {
		var m map[string]any
		if err := json.Unmarshal(b.shell(1, method, json.RawMessage(params)), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	if m := answer("shell.pushEnable", `{"deviceId":"d1"}`); m["error"].(map[string]any)["code"] != "unavailable" {
		t.Fatalf("shell.pushEnable without push answered %v", m)
	}
	t.Setenv("OMPCORE_DEVBRIDGE_PUSH", "1")
	if m := answer("shell.info", ""); m["result"].(map[string]any)["push"] != true {
		t.Fatalf("shell.info with push answered %v", m)
	}
	if m := answer("shell.pushStatus", ""); m["result"].(map[string]any)["available"] != true {
		t.Fatalf("shell.pushStatus answered %v", m)
	}
	enabled := answer("shell.pushEnable", `{"deviceId":"d1"}`)["result"].(map[string]any)
	if enabled["platform"] != "android" || enabled["fid"] == "" || len(enabled["key"].(string)) != 44 {
		t.Fatalf("shell.pushEnable answered %v", enabled)
	}
	if m := answer("shell.pushRegistration", ""); m["result"].(map[string]any)["key"] != enabled["key"] {
		t.Fatalf("shell.pushRegistration answered %v, enable %v", m, enabled)
	}
	answer("shell.pushDisable", "")
	if m := answer("shell.pushRegistration", ""); m["result"] != nil {
		t.Fatalf("shell.pushRegistration after disable answered %v", m)
	}
}

// Shots and e2e tests drive the shell's side through the page: shell.devEmit sends a shell event, shell.devAnswer sets
// the next answer to a shell method.
func TestDevShell(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	server := httptest.NewServer(newBridge().handler(""))
	defer server.Close()
	conn, err := dial(ctx, t, "ws"+strings.TrimPrefix(server.URL, "http")+"/bridge", "http://localhost:5173")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	read := func() string {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	exchange := func(request string) string {
		if err := conn.Write(ctx, websocket.MessageText, []byte(request)); err != nil {
			t.Fatal(err)
		}
		return read()
	}

	drop := `{"event":"shell.drop","params":{"paths":["/tmp/a b"]}}`
	if got := exchange(`{"id":1,"method":"shell.devEmit","params":` + drop + `}`); got != drop {
		t.Fatalf("shell.devEmit sent %s first, not the event", got)
	}
	if got := read(); got != `{"id":1,"result":{}}` {
		t.Fatalf("shell.devEmit answered %s", got)
	}
	if got := exchange(`{"id":3,"method":"shell.devEmit","params":{"event":"stream.exit","params":{}}}`); !strings.Contains(got, `"error"`) {
		t.Fatalf("shell.devEmit of a core event answered %s", got)
	}

	if got := exchange(`{"id":4,"method":"shell.pickFiles","params":{"multiple":true}}`); got != `{"id":4,"result":{"paths":[]}}` {
		t.Fatalf("shell.pickFiles answered %s", got)
	}
	exchange(`{"id":5,"method":"shell.devAnswer","params":{"method":"shell.pickFiles","result":{"paths":["/tmp/a"]}}}`)
	if got := exchange(`{"id":6,"method":"shell.pickFiles"}`); got != `{"id":6,"result":{"paths":["/tmp/a"]}}` {
		t.Fatalf("shell.pickFiles after shell.devAnswer answered %s", got)
	}
	if got := exchange(`{"id":7,"method":"shell.pickFiles"}`); got != `{"id":7,"result":{"paths":[]}}` {
		t.Fatalf("a second shell.pickFiles answered %s", got)
	}
}

func TestStaticAndCache(t *testing.T) {
	static := t.TempDir()
	cache := t.TempDir()
	t.Setenv("OMPCORE_CACHE_DIR", cache)
	t.Setenv("OMPCORE_DATA_DIR", t.TempDir())
	if err := os.WriteFile(filepath.Join(static, "index.html"), []byte("<p>page</p>"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{"abc.png": "png bytes", ".abc.png.123.tmp": "in flight"} {
		if err := os.WriteFile(filepath.Join(cache, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(newBridge().handler(static))
	defer server.Close()
	get := func(path string) (int, string) {
		response, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		return response.StatusCode, string(body)
	}
	for _, tc := range []struct {
		path   string
		status int
		body   string
	}{
		{"/", 200, "<p>page</p>"},
		{"/cache/abc.png", 200, "png bytes"},
		{"/cache/.abc.png.123.tmp", 404, ""},
		{"/cache/", 404, ""},
		{"/cache/missing.png", 404, ""},
	} {
		status, body := get(tc.path)
		if status != tc.status || (tc.body != "" && body != tc.body) {
			t.Errorf("GET %s: %d %q", tc.path, status, body)
		}
	}

	// The page served from the bridge connects to it: same origin.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := dial(ctx, t, "ws"+strings.TrimPrefix(server.URL, "http")+"/bridge", server.URL)
	if err != nil {
		t.Fatal(err)
	}
	conn.CloseNow()
}

// TestMainProcess runs main when TestListenPort starts this test binary as the devbridge.
func TestMainProcess(t *testing.T) {
	if os.Getenv("DEVBRIDGE_MAIN") != "1" {
		t.Skip("only as TestListenPort's child")
	}
	os.Args = []string{"devbridge", "-listen", "127.0.0.1:0"}
	main()
}

func TestListenPort(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestMainProcess$")
	cmd.Env = append(os.Environ(), "DEVBRIDGE_MAIN=1")
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cmd.Process.Kill()
		cmd.Wait()
	}()
	line, err := bufio.NewReader(stderr).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`devbridge: serving the core at (ws://127\.0\.0\.1:(\d+)/bridge)`).FindStringSubmatch(line)
	if match == nil || match[2] == "0" {
		t.Fatalf("stderr line %q", line)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := dial(ctx, t, match[1], "http://localhost:5173")
	if err != nil {
		t.Fatalf("connecting to %s: %v", match[1], err)
	}
	conn.CloseNow()
}
