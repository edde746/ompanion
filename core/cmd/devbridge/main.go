// Command devbridge serves the core over a WebSocket so the UI runs in a desktop browser against it
// (docs/contracts/bridge.md, Dev bridge). Development only: whoever reaches it can run commands as you, so it listens
// on loopback and accepts pages from localhost only.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"ompanion.app/core"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8787", "loopback address to serve ws://<address>/bridge on; port 0 picks one")
	static := flag.String("static", "", "a built ui/dist to serve at /")
	flag.Parse()
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		log.Fatalf("devbridge: -listen %q: %v", *listen, err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		log.Fatalf("devbridge: -listen %q is not a loopback address", *listen)
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("devbridge: %v", err)
	}
	b := newBridge()
	// Tests parse the port from this line.
	log.Printf("devbridge: serving the core at ws://%s/bridge", listener.Addr())
	log.Fatal(http.Serve(listener, b.handler(*static)))
}

// bridge connects the process's one core to the latest WebSocket connection, and answers shell.* itself.
type bridge struct {
	core *core.Core

	mu      sync.Mutex
	current *websocket.Conn
	count   int
	secrets map[string]string
	// push is the registration shell.pushEnable made, until shell.pushDisable; nil while push is off.
	push map[string]string
	// answers holds the result shell.devAnswer set for the next request of a method.
	answers map[string]json.RawMessage
}

func newBridge() *bridge {
	return &bridge{core: core.New(nil), secrets: map[string]string{}, answers: map[string]json.RawMessage{}}
}

// shellError is a shell.* error with the machine-readable code the contract names (e.g. push's "unavailable").
type shellError struct {
	code    string
	message string
}

func (e *shellError) Error() string { return e.message }

// handler serves the bridge at /bridge, the core's cache directory at /cache/ and, when static is set, that
// directory at /.
func (b *bridge) handler(static string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/bridge", b.serve)
	mux.HandleFunc("/cache/", serveCache)
	if static != "" {
		mux.Handle("/", http.FileServer(http.Dir(static)))
	}
	return mux
}

// serveCache serves one file of the cache directory: no listings, and no temporary files of downloads in flight.
func serveCache(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/cache/")
	if name == "" || strings.ContainsAny(name, `/\`) || strings.HasPrefix(name, ".") {
		http.NotFound(w, r)
		return
	}
	dir, err := core.CacheDir()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.ServeFile(w, r, filepath.Join(dir, name))
}

func (b *bridge) serve(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// The page comes from Vite's dev server on another port, or from -static on this one.
		OriginPatterns: []string{"localhost:*", "127.0.0.1:*", "[::1]:*"},
	})
	if err != nil {
		log.Printf("devbridge: refused a connection from %s: %v", r.RemoteAddr, err)
		return
	}
	conn.SetReadLimit(64 << 20)

	write := func(n int, message []byte) {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := conn.Write(ctx, websocket.MessageText, message); err != nil {
			log.Printf("devbridge: connection %d: writing: %v", n, errors.Join(err, conn.CloseNow()))
		}
	}
	b.mu.Lock()
	b.count++
	n := b.count
	b.current = conn
	b.core.SetEmit(func(message string) { write(n, []byte(message)) })
	b.mu.Unlock()
	log.Printf("devbridge: connection %d from %s took over the core", n, r.Header.Get("Origin"))

	defer func() {
		b.mu.Lock()
		if b.current == conn {
			b.current = nil
			b.core.SetEmit(nil)
		}
		b.mu.Unlock()
	}()
	for {
		kind, data, err := conn.Read(r.Context())
		if err != nil {
			status := websocket.CloseStatus(err)
			if status == websocket.StatusNormalClosure || status == websocket.StatusGoingAway || errors.Is(err, context.Canceled) {
				log.Printf("devbridge: connection %d closed", n)
			} else {
				log.Printf("devbridge: connection %d: reading: %v", n, err)
			}
			return
		}
		if kind != websocket.MessageText {
			log.Printf("devbridge: connection %d sent a binary frame; closing it: %v", n,
				conn.Close(websocket.StatusUnsupportedData, "one bridge message per text frame"))
			return
		}
		var request struct {
			ID     *int64          `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(data, &request) == nil && request.ID != nil && strings.HasPrefix(request.Method, "shell.") {
			if request.Method == "shell.devEmit" {
				event, err := devEvent(request.Params)
				// The event goes out first, so the page has handled it by the time its call returns.
				if err == nil {
					write(n, event)
				}
				write(n, response(*request.ID, struct{}{}, err))
				continue
			}
			write(n, b.shell(*request.ID, request.Method, request.Params))
			continue
		}
		b.core.Handle(string(data))
	}
}

// shell answers a shell.* request the way a shell would (docs/contracts/bridge.md, Shell services), with in-memory
// secrets and logged notifications, or with what shell.devAnswer set for it.
func (b *bridge) shell(id int64, method string, params json.RawMessage) []byte {
	result, err := b.shellResult(method, params)
	return response(id, result, err)
}

// response is the message answering request id with result, or with err (and its code, when it has one).
func response(id int64, result any, err error) []byte {
	response := map[string]any{"id": id, "result": result}
	if err != nil {
		failure := map[string]string{"message": err.Error()}
		var coded *shellError
		if errors.As(err, &coded) {
			failure["code"] = coded.code
		}
		response = map[string]any{"id": id, "error": failure}
	}
	data, err := json.Marshal(response)
	if err != nil {
		panic(fmt.Sprintf("devbridge: encoding a response: %v", err)) // built from plain values: a bug
	}
	return data
}

// devEvent is the shell event shell.devEmit's params name, `{event, params}`, as the message the page receives.
func devEvent(params json.RawMessage) ([]byte, error) {
	var event struct {
		Event  string          `json:"event"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(params, &event); err != nil {
		return nil, fmt.Errorf("bad params: %w", err)
	}
	if !strings.HasPrefix(event.Event, "shell.") {
		return nil, fmt.Errorf("%q is not a shell event", event.Event)
	}
	if len(event.Params) == 0 {
		event.Params = json.RawMessage("{}")
	}
	return json.Marshal(event)
}

// shellResult is shell's answer to method.
func (b *bridge) shellResult(method string, params json.RawMessage) (any, error) {
	var p struct {
		Key      string          `json:"key"`
		Value    string          `json:"value"`
		DeviceID string          `json:"deviceId"`
		Method   string          `json:"method"`
		Result   json.RawMessage `json:"result"`
	}
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, fmt.Errorf("bad params: %w", err)
		}
	}
	b.mu.Lock()
	answer, answered := b.answers[method]
	delete(b.answers, method)
	b.mu.Unlock()
	if answered {
		log.Printf("devbridge: %s %s answered %s", method, params, answer)
		return answer, nil
	}
	switch method {
	case "shell.devAnswer":
		if !strings.HasPrefix(p.Method, "shell.") || len(p.Result) == 0 {
			return nil, fmt.Errorf("shell.devAnswer needs a shell method and a result, got %s", params)
		}
		b.mu.Lock()
		b.answers[p.Method] = p.Result
		b.mu.Unlock()
		return struct{}{}, nil
	case "shell.pickFiles", "shell.clipboardFiles":
		// No open panel and no clipboard in the dev bridge: cancelled, nothing copied.
		log.Printf("devbridge: %s %s", method, params)
		return map[string][]string{"paths": {}}, nil
	case "shell.info":
		device, err := os.Hostname()
		if err != nil {
			return nil, err
		}
		version, build, _ := strings.Cut(core.Version, "+")
		return map[string]any{"platform": platform(), "osVersion": osVersion(), "appVersion": version,
			"build": build, "device": device, "push": pushOn()}, nil
	case "shell.secretGet":
		b.mu.Lock()
		defer b.mu.Unlock()
		if value, ok := b.secrets[p.Key]; ok {
			return map[string]string{"value": value}, nil
		}
		return map[string]any{"value": nil}, nil
	case "shell.secretSet":
		b.mu.Lock()
		b.secrets[p.Key] = p.Value
		b.mu.Unlock()
		return struct{}{}, nil
	case "shell.secretDelete":
		b.mu.Lock()
		delete(b.secrets, p.Key)
		b.mu.Unlock()
		return struct{}{}, nil
	case "shell.openUrl", "shell.clipboardWrite", "shell.notify", "shell.notifySchedule", "shell.notifyCancel",
		"shell.timing", "shell.pushSetVisible", "shell.pushClear", "shell.backEnabled":
		log.Printf("devbridge: %s %s", method, params)
		return struct{}{}, nil
	case "shell.notifyPermission":
		return map[string]bool{"granted": true}, nil
	case "shell.saveFile":
		log.Printf("devbridge: %s %s (no save panel in the dev bridge)", method, params)
		return map[string]bool{"saved": false}, nil
	case "shell.insets":
		return map[string]int{"top": 0, "right": 0, "bottom": 0, "left": 0, "keyboard": 0}, nil
	case "shell.titleBar":
		// A browser window has no title bar to draw under.
		return map[string]any{"height": 0, "leadingInset": 0, "fullScreen": false}, nil
	case "shell.dragRegions":
		return struct{}{}, nil
	case "shell.flutterData":
		return flutterData()
	case "shell.flutterDataClear":
		return struct{}{}, flutterDataClear()
	case "shell.pushStatus":
		if !pushOn() {
			return map[string]any{"available": false, "reason": "the dev bridge has no push"}, nil
		}
		return map[string]any{"available": true, "reason": nil}, nil
	case "shell.pushEnable":
		if !pushOn() {
			return nil, &shellError{"unavailable", "the dev bridge has no push"}
		}
		if p.DeviceID == "" {
			return nil, &shellError{"failed", "shell.pushEnable needs a deviceId"}
		}
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, &shellError{"failed", err.Error()}
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		b.push = map[string]string{"platform": "android", "fid": "devbridge-fid", "key": base64.StdEncoding.EncodeToString(key)}
		return b.push, nil
	case "shell.pushRegistration":
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.push == nil {
			return nil, nil
		}
		return b.push, nil
	case "shell.pushDisable":
		b.mu.Lock()
		b.push = nil
		b.mu.Unlock()
		return struct{}{}, nil
	case "shell.pushTakeLaunchTap":
		return nil, nil
	default:
		return nil, fmt.Errorf("unknown method %q", method)
	}
}

// pushOn is whether this dev bridge pretends to be a phone build with push: OMPCORE_DEVBRIDGE_PUSH=1. Its registration
// names no real installation, so nothing ever arrives.
func pushOn() bool {
	return os.Getenv("OMPCORE_DEVBRIDGE_PUSH") == "1"
}

// flutterData answers shell.flutterData from $OMPCORE_FLUTTER_DB, the path of a Flutter app's ompanion.sqlite, and
// $OMPCORE_FLUTTER_SECRETS, a JSON object file of its secrets by key, read on every call: an unset variable or a
// missing file is none.
func flutterData() (any, error) {
	var database any
	if path := os.Getenv("OMPCORE_FLUTTER_DB"); path != "" {
		if _, err := os.Stat(path); err == nil {
			database = path
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}
	secrets := map[string]string{}
	if path := os.Getenv("OMPCORE_FLUTTER_SECRETS"); path != "" {
		data, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		if err == nil {
			if err := json.Unmarshal(data, &secrets); err != nil {
				return nil, fmt.Errorf("%s: %w", path, err)
			}
		}
	}
	return map[string]any{"database": database, "secrets": secrets}, nil
}

// flutterDataClear sets the Flutter data aside as the shells do: the database and its journal, WAL and shared-memory
// files get the suffix .imported, and the secrets go.
func flutterDataClear() error {
	if path := os.Getenv("OMPCORE_FLUTTER_DB"); path != "" {
		for _, suffix := range []string{"", "-journal", "-wal", "-shm"} {
			if err := os.Rename(path+suffix, path+suffix+".imported"); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
		}
	}
	if path := os.Getenv("OMPCORE_FLUTTER_SECRETS"); path != "" {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	return nil
}

// platform is shell.info's name for this OS.
func platform() string {
	if runtime.GOOS == "darwin" {
		return "macos"
	}
	return runtime.GOOS
}

// osVersion is the OS release as uname reports it; Windows has no uname and gets "".
var osVersion = sync.OnceValue(func() string {
	if runtime.GOOS == "windows" {
		return ""
	}
	out, err := exec.Command("uname", "-r").Output()
	if err != nil {
		log.Printf("devbridge: uname -r: %v", err)
		return ""
	}
	return strings.TrimSpace(string(out))
})
