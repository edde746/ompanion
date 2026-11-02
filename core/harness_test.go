package core

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

const testTimeout = 20 * time.Second

// message is any message the core emits.
type message struct {
	ID     *int64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message      string           `json:"message"`
		Code         string           `json:"code"`
		Hop          *int             `json:"hop"`
		Offered      []map[string]any `json:"offered"`
		AgentProblem string           `json:"agentProblem"`
	} `json:"error"`
	Event  string `json:"event"`
	Params struct {
		Stream string `json:"stream"`
		Fd     string `json:"fd"`
		Data   string `json:"data"`
		Code   *int   `json:"code"`
		Signal string `json:"signal"`
		Error  string `json:"error"`
	} `json:"params"`
	raw    string
	params map[string]any // an event's params, for events of no stream
}

// harness drives a core the way a page does. It routes each response to its caller, each stream event to its
// stream and every other event (ssh.prompt, ssh.closed) to events, and fails the test when a stream event arrives
// before the response that named its stream.
type harness struct {
	t    *testing.T
	core *Core

	mu      sync.Mutex
	nextID  int64
	waiting map[int64]chan message
	streams map[string]chan message
	other   chan message
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t, waiting: map[int64]chan message{}, streams: map[string]chan message{},
		other: make(chan message, 1<<10)}
	h.core = New(h.receive)
	return h
}

func (h *harness) receive(text string) {
	var m message
	if err := json.Unmarshal([]byte(text), &m); err != nil {
		h.t.Errorf("core emitted bad JSON %q: %v", text, err)
		return
	}
	m.raw = text
	h.mu.Lock()
	defer h.mu.Unlock()
	if m.ID != nil {
		var r struct {
			Stream string `json:"stream"`
		}
		if json.Unmarshal(m.Result, &r) == nil && r.Stream != "" {
			h.streams[r.Stream] = make(chan message, 1<<14)
		}
		ch, ok := h.waiting[*m.ID]
		if !ok {
			h.t.Errorf("response nobody waits for: %s", text)
			return
		}
		delete(h.waiting, *m.ID)
		ch <- m
		return
	}
	if !strings.HasPrefix(m.Event, "stream.") {
		var e struct {
			Params map[string]any `json:"params"`
		}
		if err := json.Unmarshal([]byte(text), &e); err != nil {
			h.t.Errorf("event params %q: %v", text, err)
		}
		m.params = e.Params
		h.other <- m
		return
	}
	ch, ok := h.streams[m.Params.Stream]
	if !ok {
		h.t.Errorf("event before the response that names its stream: %s", text)
		return
	}
	ch <- m
}

// send hands the core one raw request with a fresh id and returns where its response arrives.
func (h *harness) send(method string, params any) <-chan message {
	h.mu.Lock()
	h.nextID++
	id := h.nextID
	ch := make(chan message, 1)
	h.waiting[id] = ch
	h.mu.Unlock()
	request := map[string]any{"id": id, "method": method}
	if params != nil {
		request["params"] = params
	}
	data, err := json.Marshal(request)
	if err != nil {
		h.t.Fatal(err)
	}
	h.core.Handle(string(data))
	return ch
}

func (h *harness) wait(ch <-chan message, what string) message {
	h.t.Helper()
	select {
	case m := <-ch:
		return m
	case <-time.After(testTimeout):
		h.t.Fatalf("no response to %s", what)
		return message{}
	}
}

func (h *harness) call(method string, params any) message {
	h.t.Helper()
	return h.wait(h.send(method, params), method)
}

// ok calls method and fails the test on an error response.
func (h *harness) ok(method string, params any) json.RawMessage {
	h.t.Helper()
	m := h.call(method, params)
	if m.Error != nil {
		h.t.Fatalf("%s: %s", method, m.Error.Message)
	}
	return m.Result
}

// okInto calls method and decodes its result into T.
func okInto[T any](h *harness, method string, params any) T {
	h.t.Helper()
	var result T
	if err := json.Unmarshal(h.ok(method, params), &result); err != nil {
		h.t.Fatalf("%s: %v", method, err)
	}
	return result
}

// fails calls method, expects an error with code, and returns its message.
func (h *harness) fails(method string, params any, code string) message {
	h.t.Helper()
	m := h.call(method, params)
	if m.Error == nil || m.Error.Code != code {
		h.t.Fatalf("%s answered %s, want an error with code %q", method, m.raw, code)
	}
	return m
}

// open calls a method that starts a stream and returns the stream.
func (h *harness) open(method string, params any) string {
	h.t.Helper()
	var r struct {
		Stream string `json:"stream"`
	}
	if err := json.Unmarshal(h.ok(method, params), &r); err != nil || r.Stream == "" {
		h.t.Fatalf("%s returned no stream", method)
	}
	return r.Stream
}

func (h *harness) events(stream string) chan message {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.streams[stream]
}

func (h *harness) next(stream string) message {
	h.t.Helper()
	select {
	case m := <-h.events(stream):
		return m
	case <-time.After(testTimeout):
		h.t.Fatalf("%s: no event", stream)
		return message{}
	}
}

// event returns the next event of no stream.
func (h *harness) event() message {
	h.t.Helper()
	select {
	case m := <-h.other:
		return m
	case <-time.After(testTimeout):
		h.t.Fatal("no event")
		return message{}
	}
}

// collected is a stream's output up to its stream.exit.
type collected struct {
	stdout, stderr strings.Builder
	chunks         []string
	exit           message
}

func (h *harness) drain(stream string) *collected {
	h.t.Helper()
	var o collected
	for {
		m := h.next(stream)
		switch m.Event {
		case "stream.data":
			o.chunks = append(o.chunks, m.Params.Data)
			if m.Params.Fd == "stderr" {
				o.stderr.WriteString(m.Params.Data)
			} else {
				o.stdout.WriteString(m.Params.Data)
			}
		case "stream.exit":
			o.exit = m
			return &o
		default:
			h.t.Fatalf("unexpected event %s", m.raw)
		}
	}
}

// drainBytes is drain for a base64 stream: its stdout bytes.
func (h *harness) drainBytes(stream string) ([]byte, message) {
	h.t.Helper()
	o := h.drain(stream)
	var out []byte
	for _, chunk := range o.chunks {
		data, err := base64.StdEncoding.DecodeString(chunk)
		if err != nil {
			h.t.Fatalf("%s: not base64: %q", stream, chunk)
		}
		out = append(out, data...)
	}
	return out, o.exit
}

// until reads a stream's stdout until it contains want, and returns what it read.
func (h *harness) until(stream, want string) string {
	h.t.Helper()
	var seen strings.Builder
	for !strings.Contains(seen.String(), want) {
		m := h.next(stream)
		if m.Event == "stream.exit" {
			h.t.Fatalf("%s exited before printing %q; it printed %q (%s)", stream, want, seen.String(), m.raw)
		}
		seen.WriteString(m.Params.Data)
	}
	return seen.String()
}

func exitCodeOf(t *testing.T, o *collected) int {
	t.Helper()
	if o.exit.Params.Code == nil {
		t.Fatalf("no exit code: %s", o.exit.raw)
	}
	return *o.exit.Params.Code
}
