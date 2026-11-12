// Package core is the spike's native core. The web UI sends it one JSON request per message and gets back one JSON
// response or event per message; docs/contracts/bridge.md is the contract.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"os"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Version is the root VERSION file, `<semver>+<build>`, which every build script sets at link time
// (-X ompanion.app/core.Version=…); core.info reports its semver.
var Version string

// Core answers requests. Its emit function is called one message at a time.
type Core struct {
	emitMu sync.Mutex
	emit   func(string)
	// page counts the listeners SetEmit installed: a request answers only the page it came from.
	page atomic.Uint64

	idMu   sync.Mutex
	nextID int

	mu       sync.Mutex
	streams  map[string]*stream
	machines map[string]*machine
	prompts  map[string]chan promptReply
	forwards map[string]*forward
}

// New returns a core that hands every outgoing message to emit; emit may be nil until SetEmit.
func New(emit func(string)) *Core {
	return &Core{
		emit:     emit,
		streams:  map[string]*stream{},
		machines: map[string]*machine{},
		prompts:  map[string]chan promptReply{},
		forwards: map[string]*forward{},
	}
}

// SetEmit replaces the outgoing message handler: a reloaded page or a restarted shell takes over the same core. The
// core outlives the page; what the previous page opened does not, as the next one never knew its ids. Its streams are
// killed and its forwards and machines closed, without an event for them; its prompts fail their connects, and its
// requests still running get no response.
func (c *Core) SetEmit(emit func(string)) {
	c.page.Add(1)
	c.mu.Lock()
	streams := slices.Collect(maps.Values(c.streams))
	forwards := slices.Collect(maps.Values(c.forwards))
	machines := slices.Collect(maps.Values(c.machines))
	c.mu.Unlock()
	// Before the next page listens: an event a stream is emitting finishes first, and none follows.
	for _, s := range streams {
		s.silence()
	}
	c.emitMu.Lock()
	c.emit = emit
	c.emitMu.Unlock()
	c.failPrompts()
	c.release(streams, forwards, machines)
}

// release kills streams and closes forwards and machines, without an event: the page that opened them went away.
func (c *Core) release(streams []*stream, forwards []*forward, machines []*machine) {
	for _, s := range streams {
		s.silence()
		if err := s.kill(); err != nil && !errors.Is(err, os.ErrProcessDone) && !errors.Is(err, net.ErrClosed) {
			c.writeLog(fmt.Sprintf("core: killing %s of a page that went away: %v", s.id, err))
		}
	}
	for _, f := range forwards {
		c.closeForward(f)
	}
	for _, m := range machines {
		m.close(errors.New("the page went away"), true)
	}
}

// releaseOpened releases the stream, forward or machine that result, the answer to a request of a page that went
// away, names.
func (c *Core) releaseOpened(result any) {
	named := func(key string) string {
		switch r := result.(type) {
		case map[string]string:
			return r[key]
		case map[string]any:
			id, _ := r[key].(string)
			return id
		}
		return ""
	}
	c.mu.Lock()
	s, sOK := c.streams[named("stream")]
	f, fOK := c.forwards[named("forward")]
	m, mOK := c.machines[named("machine")]
	c.mu.Unlock()
	var streams []*stream
	var forwards []*forward
	var machines []*machine
	if sOK {
		streams = append(streams, s)
	}
	if fOK {
		forwards = append(forwards, f)
	}
	if mOK {
		machines = append(machines, m)
	}
	c.release(streams, forwards, machines)
}

type request struct {
	ID     *int64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type errorBody struct {
	Message      string       `json:"message"`
	Code         string       `json:"code,omitempty"`
	Hop          *int         `json:"hop,omitempty"`
	Offered      []offeredKey `json:"offered,omitempty"`
	AgentProblem string       `json:"agentProblem,omitempty"`
}

// codedError is an error the page tells apart by its code (docs/contracts/bridge.md, Full app additions). An
// ssh.connect failure also names the hop it happened on, the keys that hop refused and why the agent had none.
type codedError struct {
	code         string
	err          error
	hop          *int
	offered      []offeredKey
	agentProblem string
}

func (e *codedError) Error() string { return e.err.Error() }
func (e *codedError) Unwrap() error { return e.err }

func withCode(code string, err error) error { return &codedError{code: code, err: err} }

func errorResponse(err error) errorBody {
	body := errorBody{Message: err.Error()}
	var coded *codedError
	if errors.As(err, &coded) {
		body.Code, body.Hop, body.Offered, body.AgentProblem = coded.code, coded.hop, coded.offered, coded.agentProblem
	}
	return body
}

// Handle answers one request on its own goroutine. A message that is not a request is logged and dropped: it has no
// id to answer. A request whose page went away meanwhile (SetEmit) gets no response, which would reach the next page
// under an id of its own, and what it opened is released.
func (c *Core) Handle(message string) {
	var req request
	if err := json.Unmarshal([]byte(message), &req); err != nil || req.ID == nil || req.Method == "" {
		c.writeLog(fmt.Sprintf("core: dropped a message that is not a request: %.200s", message))
		return
	}
	page := c.page.Load()
	var wait, done chan struct{}
	if id, flow := orderedStream(req.Method, req.Params); id != "" {
		wait, done = c.takeTurn(id, flow)
	}
	go func() {
		if wait != nil {
			<-wait
			defer close(done)
		}
		result, after, err := c.dispatch(page, req.Method, req.Params)
		response := map[string]any{"id": *req.ID, "result": result}
		if err != nil {
			response = map[string]any{"id": *req.ID, "error": errorResponse(err)}
		}
		// SetEmit counts the page before it releases what is open: what this request opened is released there, or
		// here.
		if !c.sendTo(page, response) && err == nil {
			c.releaseOpened(result)
		}
		// A stream, or the watch of a machine, starts only after the response that names it, so its first event finds
		// it known. A released one still runs to its end, silent.
		if after != nil {
			after()
		}
	}()
}

// dispatch runs one method for the page that sent it. after, when not nil, runs once the response has been emitted.
func (c *Core) dispatch(page uint64, method string, params json.RawMessage) (result any, after func(), err error) {
	switch method {
	case "core.info":
		return c.info(), nil, nil
	case "core.echo":
		if len(params) == 0 {
			return nil, nil, nil
		}
		return params, nil, nil
	case "core.log":
		p, err := decode[struct {
			Line string `json:"line"`
		}](params)
		if err != nil {
			return nil, nil, err
		}
		c.writeLog(p.Line)
		return struct{}{}, nil, nil
	case "core.exit":
		p, err := decode[struct {
			Code int `json:"code"`
		}](params)
		if err != nil {
			return nil, nil, err
		}
		return struct{}{}, func() {
			time.Sleep(100 * time.Millisecond)
			// A page that went away meanwhile asked for it: the core serves the next one now.
			if c.page.Load() == page {
				os.Exit(p.Code)
			}
		}, nil
	case "core.flood":
		return c.flood(page, params)
	case "core.paths":
		return noAfter(c.corePaths())
	case "core.env":
		p, err := decode[struct {
			Names []string `json:"names"`
		}](params)
		if err != nil {
			return nil, nil, err
		}
		env := map[string]string{}
		for _, name := range p.Names {
			if value, ok := os.LookupEnv(name); ok {
				env[name] = value
			}
		}
		return map[string]any{"env": env}, nil, nil
	case "local.exec":
		return c.localExec(params)
	case "pty.open":
		return c.ptyOpen(params)
	case "pty.resize":
		return c.ptyResize(params)
	case "ssh.connect":
		return c.sshConnect(page, params)
	case "ssh.answer":
		return noAfter(c.sshAnswer(params))
	case "ssh.exec":
		return c.sshExec(params)
	case "ssh.close":
		return noAfter(c.sshClose(params))
	case "ssh.check":
		return noAfter(c.sshCheck(params))
	case "stream.write":
		return noAfter(c.streamWrite(params))
	case "stream.closeStdin":
		return noAfter(c.streamCloseStdin(params))
	case "stream.kill":
		return noAfter(c.streamKill(params))
	case "stream.pause":
		return noAfter(c.streamFlow(params, true))
	case "stream.resume":
		return noAfter(c.streamFlow(params, false))
	case "fs.home", "fs.stat", "fs.list", "fs.read", "fs.write", "fs.mkdir", "fs.remove", "fs.removeDir", "fs.rename",
		"fs.touch", "fs.download", "fs.upload":
		return noAfter(c.fs(method, params))
	case "net.forward":
		return noAfter(c.netForward(params))
	case "net.forwardClose":
		return noAfter(c.netForwardClose(params))
	case "net.connect":
		return c.netConnect(params)
	case "net.fetch":
		return noAfter(c.netFetch(params))
	case "keys.generate":
		return noAfter(keysGenerate(params))
	case "keys.inspect":
		return noAfter(keysInspect(params))
	case "store.read":
		return noAfter(storeRead(params))
	case "store.write":
		return noAfter(storeWrite(params))
	case "store.delete":
		return noAfter(storeDelete(params))
	case "sqlite.read":
		return noAfter(sqliteRead(params))
	default:
		return nil, nil, fmt.Errorf("unknown method %q", method)
	}
}

// noAfter is the result of a method that starts nothing once its response went out.
func noAfter(result any, err error) (any, func(), error) {
	return result, nil, err
}

// local reports whether this platform can run local processes and PTYs: the desktops.
func local() bool {
	goos := runtime.GOOS
	return goos == "darwin" || goos == "linux" || goos == "windows"
}

func (c *Core) info() map[string]any {
	// The page expands OpenSSH's %l and %L with it; a failure leaves it empty, as ssh does.
	hostname, _ := os.Hostname()
	semver, _, _ := strings.Cut(Version, "+")
	return map[string]any{
		"version":  semver,
		"goos":     runtime.GOOS,
		"goarch":   runtime.GOARCH,
		"local":    local(),
		"smoke":    os.Getenv("OMPCORE_SMOKE") == "1",
		"bench":    os.Getenv("OMPCORE_BENCH") == "1",
		"hostname": hostname,
	}
}

// flood is a stream of no process, which SetEmit does not know of: it stops at the first event its page no longer gets.
func (c *Core) flood(page uint64, params json.RawMessage) (any, func(), error) {
	p, err := decode[struct {
		Bytes int `json:"bytes"`
		Chunk int `json:"chunk"`
	}](params)
	if err != nil {
		return nil, nil, err
	}
	if p.Bytes < 0 || p.Chunk <= 0 {
		return nil, nil, errors.New("core.flood needs bytes >= 0 and chunk > 0")
	}
	id := c.newID("s")
	event := func(name string, params any) bool {
		return c.sendTo(page, map[string]any{"event": name, "params": params})
	}
	data := func(chunk []byte) bool {
		return event("stream.data", map[string]string{"stream": id, "fd": "stdout", "data": string(chunk)})
	}
	return map[string]string{"stream": id}, func() {
		var line strings.Builder
		pending := make([]byte, 0, p.Chunk)
		for n, left := 0, p.Bytes; left > 0; n++ {
			line.Reset()
			line.WriteString("flood ")
			line.WriteString(strconv.Itoa(n))
			line.WriteString(" abcdefghijklmnopqrstuvwxyz0123456789\n")
			text := line.String()
			if len(text) > left {
				text = text[:left]
			}
			left -= len(text)
			for len(text) > 0 {
				room := p.Chunk - len(pending)
				take := min(room, len(text))
				pending = append(pending, text[:take]...)
				text = text[take:]
				if len(pending) == p.Chunk {
					if !data(pending) {
						return
					}
					pending = pending[:0]
				}
			}
		}
		if len(pending) > 0 && !data(pending) {
			return
		}
		event("stream.exit", map[string]any{"stream": id, "code": 0})
	}, nil
}

// newID returns the next id with prefix: "s1", "m2", …
func (c *Core) newID(prefix string) string {
	c.idMu.Lock()
	defer c.idMu.Unlock()
	c.nextID++
	return prefix + strconv.Itoa(c.nextID)
}

// Event emits one event.
func (c *Core) Event(name string, params any) {
	c.send(map[string]any{"event": name, "params": params})
}

func (c *Core) send(message any) {
	c.emitTo(message, func() bool { return true })
}

// sendTo sends message if page is still the listener's page, and reports whether it did.
func (c *Core) sendTo(page uint64, message any) bool {
	return c.emitTo(message, func() bool { return c.page.Load() == page })
}

// emitTo emits message if current, asked holding emitMu, holds: SetEmit swaps the listener holding it.
func (c *Core) emitTo(message any, current func() bool) bool {
	data, err := json.Marshal(message)
	if err != nil {
		// Every message is built here from plain values: a failure is a bug, not input.
		panic(fmt.Sprintf("core: encoding a message: %v", err))
	}
	c.emitMu.Lock()
	defer c.emitMu.Unlock()
	if !current() {
		return false
	}
	if c.emit != nil {
		c.emit(string(data))
	}
	return true
}

// writeLog writes line to stderr and appends it to $OMPCORE_LOG when set: a Windows GUI app has no stderr.
func (c *Core) writeLog(line string) {
	fmt.Fprintln(os.Stderr, line)
	path := os.Getenv("OMPCORE_LOG")
	if path == "" {
		return
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "core: opening OMPCORE_LOG %s: %v\n", path, err)
		return
	}
	defer file.Close()
	if _, err := fmt.Fprintln(file, line); err != nil {
		fmt.Fprintf(os.Stderr, "core: writing OMPCORE_LOG %s: %v\n", path, err)
	}
}

func decode[T any](params json.RawMessage) (T, error) {
	var value T
	if len(params) == 0 {
		return value, errors.New("missing params")
	}
	if err := json.Unmarshal(params, &value); err != nil {
		return value, fmt.Errorf("bad params: %w", err)
	}
	return value, nil
}
