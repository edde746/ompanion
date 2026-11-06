package core

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

func TestFraming(t *testing.T) {
	h := newHarness(t)
	linked := Version
	Version = "1.2.1+4"
	t.Cleanup(func() { Version = linked })

	var info struct {
		Version string `json:"version"`
		Goos    string `json:"goos"`
		Local   *bool  `json:"local"`
		Smoke   *bool  `json:"smoke"`
		Bench   *bool  `json:"bench"`
	}
	if err := json.Unmarshal(h.ok("core.info", nil), &info); err != nil {
		t.Fatal(err)
	}
	if info.Version != "1.2.1" || info.Goos == "" || info.Local == nil || info.Smoke == nil || info.Bench == nil {
		t.Fatalf("core.info = %+v", info)
	}

	params := map[string]any{"a": []any{1.0, "ü", nil}, "b": map[string]any{"c": true}}
	var echoed map[string]any
	if err := json.Unmarshal(h.ok("core.echo", params), &echoed); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(echoed) != fmt.Sprint(params) {
		t.Fatalf("core.echo = %v, want %v", echoed, params)
	}
	if got := string(h.ok("core.echo", nil)); got != "null" {
		t.Fatalf("core.echo without params = %s, want null", got)
	}

	for _, tc := range []struct {
		method string
		params any
		want   string
	}{
		{"no.such", nil, `unknown method "no.such"`},
		{"core.log", nil, "missing params"},
		{"core.log", "a string", "bad params"},
		{"core.flood", map[string]int{"bytes": 1, "chunk": 0}, "chunk > 0"},
		{"local.exec", map[string]any{"argv": []string{}}, "needs argv or command"},
		{"local.exec", map[string]any{"argv": []string{"true"}, "encoding": "utf16"}, `unknown encoding "utf16"`},
		{"stream.write", map[string]string{"stream": "s999", "data": "x"}, `unknown stream "s999"`},
		{"stream.kill", map[string]string{"stream": "s999"}, `unknown stream "s999"`},
		{"stream.pause", map[string]string{"stream": "s999"}, `unknown stream "s999"`},
		{"stream.resume", map[string]string{"stream": "s999"}, `unknown stream "s999"`},
		{"pty.resize", map[string]any{"stream": "s999", "cols": 80, "rows": 24}, `unknown stream "s999"`},
		{"ssh.exec", map[string]string{"machine": "m999", "command": "true"}, `unknown machine "m999"`},
		{"ssh.close", map[string]string{"machine": "m999"}, `unknown machine "m999"`},
		{"ssh.connect", map[string]any{"host": "127.0.0.1", "user": "x"}, "x@127.0.0.1: needs auth"},
		{"ssh.answer", map[string]any{"prompt": "p999", "accept": true}, `unknown prompt "p999"`},
		{"store.read", map[string]string{"name": "../x"}, "bad store name"},
		{"fs.stat", map[string]string{"machine": "local"}, "fs.stat needs path"},
		{"net.forwardClose", map[string]string{"forward": "f999"}, `unknown forward "f999"`},
		{"net.fetch", map[string]string{"url": "file:///etc/passwd"}, "takes http and https URLs"},
		{"keys.generate", map[string]any{"type": "dsa"}, `unknown key type "dsa"`},
		{"keys.generate", map[string]any{"type": "ecdsa", "bits": 512}, "256, 384 or 521"},
		{"pty.open", map[string]any{"cols": 0, "rows": 24}, "cols > 0"},
	} {
		m := h.call(tc.method, tc.params)
		if m.Error == nil || !strings.Contains(m.Error.Message, tc.want) || m.Result != nil {
			t.Errorf("%s(%v) = %s, want an error containing %q", tc.method, tc.params, m.raw, tc.want)
		}
	}

	// Messages that are not requests have no id to answer: the core drops them. The harness fails on a response
	// nobody waits for.
	for _, text := range []string{`not json`, `{"method":"core.info"}`, `{"id":7}`, `[]`} {
		h.core.Handle(text)
	}

	// Concurrent requests: each gets exactly one response, with its own params.
	var pending []<-chan message
	for i := range 100 {
		pending = append(pending, h.send("core.echo", i))
	}
	for i, ch := range pending {
		if m := h.wait(ch, "core.echo"); string(m.Result) != fmt.Sprint(i) {
			t.Fatalf("echo %d = %s", i, m.raw)
		}
	}
}

func TestFlood(t *testing.T) {
	h := newHarness(t)
	for _, tc := range []struct{ bytes, chunk int }{
		{1_000_003, 65_536},
		{20_000, 7},
		{100, 1_000},
		{0, 10},
	} {
		stream := h.open("core.flood", map[string]int{"bytes": tc.bytes, "chunk": tc.chunk})
		o := h.drain(stream)
		if o.exit.Params.Code == nil || *o.exit.Params.Code != 0 {
			t.Fatalf("flood exit = %s", o.exit.raw)
		}
		total := 0
		for i, chunk := range o.chunks {
			if len(chunk) > tc.chunk || (i < len(o.chunks)-1 && len(chunk) != tc.chunk) {
				t.Fatalf("flood %+v: chunk %d of %d has %d bytes", tc, i, len(o.chunks), len(chunk))
			}
			total += len(chunk)
		}
		if total != tc.bytes || o.stdout.Len() != tc.bytes {
			t.Fatalf("flood %+v: got %d bytes", tc, total)
		}
		for _, r := range o.stdout.String() {
			if r != '\n' && (r < ' ' || r > '~') {
				t.Fatalf("flood %+v: not printable ASCII: %q", tc, r)
			}
		}
	}
}

// TestFloodEndsWithItsPage checks that core.flood, which no process backs, stops once its page went away: the next
// page gets none of its events.
func TestFloodEndsWithItsPage(t *testing.T) {
	h := newHarness(t)
	// Far more than it sends before the reload.
	stream := h.open("core.flood", map[string]int{"bytes": 1 << 30, "chunk": 1 << 16})
	h.next(stream)
	var leaked atomic.Int32
	h.core.SetEmit(func(string) { leaked.Add(1) })
	time.Sleep(300 * time.Millisecond)
	if n := leaked.Load(); n > 0 {
		t.Fatalf("the next page got %d events of the old page's flood", n)
	}
}

// TestExitOfAPageThatWentAway checks that a core.exit whose page went away before it took effect does not end the core
// under the next page.
func TestExitOfAPageThatWentAway(t *testing.T) {
	h := newHarness(t)
	h.ok("core.exit", map[string]int{"code": 3}) // an exit ends the test binary with 3
	h.core.SetEmit(h.receive)
	time.Sleep(300 * time.Millisecond)
}

func TestCompleteUTF8(t *testing.T) {
	euro := "€"  // E2 82 AC
	smile := "😀" // F0 9F 98 80
	for _, tc := range []struct {
		in   string
		want int
	}{
		{"", 0},
		{"abc", 3},
		{"a" + euro, 4},
		{"a" + euro[:1], 1},
		{"a" + euro[:2], 1},
		{smile[:3], 0},
		{"ab" + smile, 6},
		{"\x80\x80\x80\x80", 4}, // stray continuation bytes: invalid, nothing to wait for
		{"a\xe2a", 3},           // a lead byte followed by ASCII: invalid
		{"\xff", 1},             // never valid
		{"é" + smile[:1], 2},
	} {
		if got := completeUTF8([]byte(tc.in)); got != tc.want {
			t.Errorf("completeUTF8(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestOutputCarriesSplitSequences(t *testing.T) {
	h := newHarness(t)
	text := strings.Repeat("ascii é € 😀 日本語 ", 200)
	for _, size := range []int{1, 2, 3, 5, 7, 4096} {
		s := h.core.newStream(false)
		h.mu.Lock()
		h.streams[s.id] = make(chan message, 1<<14)
		h.mu.Unlock()
		close(s.started)
		o := h.core.output(s, "stdout")
		for rest := text; rest != ""; {
			n := min(size, len(rest))
			if _, err := o.Write([]byte(rest[:n])); err != nil {
				t.Fatal(err)
			}
			rest = rest[n:]
		}
		o.flush()
		h.core.exit(s, ending{code: 0})
		got := h.drain(s.id)
		for _, chunk := range got.chunks {
			if strings.ContainsRune(chunk, utf8.RuneError) {
				t.Fatalf("writes of %d bytes: a chunk split a sequence: %q", size, chunk)
			}
		}
		if got.stdout.String() != text {
			t.Fatalf("writes of %d bytes: output differs", size)
		}
	}

	// A sequence the process never finishes still comes out, as U+FFFD.
	s := h.core.newStream(false)
	h.mu.Lock()
	h.streams[s.id] = make(chan message, 16)
	h.mu.Unlock()
	close(s.started)
	o := h.core.output(s, "stdout")
	if _, err := o.Write([]byte("ok\xe2\x82")); err != nil {
		t.Fatal(err)
	}
	o.flush()
	h.core.exit(s, ending{code: 0})
	if got := h.drain(s.id).stdout.String(); got != "ok\uFFFD" && got != "ok\uFFFD\uFFFD" {
		t.Fatalf("unfinished sequence came out as %q", got)
	}
}

func TestOutputCoalesces(t *testing.T) {
	h := newHarness(t)
	s := h.core.newStream(false)
	h.mu.Lock()
	h.streams[s.id] = make(chan message, 1<<14)
	h.mu.Unlock()
	close(s.started)
	o := h.core.output(s, "stdout")
	write := func(text string) {
		if _, err := o.Write([]byte(text)); err != nil {
			t.Fatal(err)
		}
	}
	// The first output after a quiet window goes out before its write returns: typing echoes at once.
	write("x")
	select {
	case m := <-h.events(s.id):
		if m.Params.Data != "x" {
			t.Fatalf("first event %s", m.raw)
		}
	default:
		t.Fatal("the first output did not go out at once")
	}
	// A flood in PTY-sized pieces right after it is gathered: an event per window, or per coalesceMax bytes.
	flood := strings.Repeat("y\n", 100_000)
	start := time.Now()
	for i := 0; i < len(flood); i += 37 {
		write(flood[i:min(i+37, len(flood))])
	}
	elapsed := time.Since(start)
	o.flush()
	h.core.exit(s, ending{code: 0})
	got := h.drain(s.id)
	if got.stdout.String() != flood {
		t.Fatalf("the flood came out as %d bytes, want %d", got.stdout.Len(), len(flood))
	}
	if most := int(elapsed/coalesceWindow) + len(flood)/coalesceMax + 2; len(got.chunks) > most {
		t.Fatalf("%d events for %d writes in %v, want at most %d", len(got.chunks), len(flood)/37, elapsed, most)
	}
	for _, chunk := range got.chunks {
		if len(chunk) > coalesceMax+37 {
			t.Fatalf("an event of %d bytes", len(chunk))
		}
	}
}

// TestPauseAfterThePageWentAway checks that a stream.pause run after the next page took over, such as the old page's
// queued behind its other flow requests, does not hold back the stream's end: no page would resume it.
func TestPauseAfterThePageWentAway(t *testing.T) {
	h := newHarness(t)
	s := h.core.newStream(false)
	s.kill = func() error { return nil }
	h.core.register(s)
	h.core.SetEmit(h.receive)
	h.ok("stream.pause", map[string]string{"stream": s.id})
	exited := make(chan struct{})
	go func() {
		h.core.exit(s, ending{code: 0})
		close(exited)
	}()
	select {
	case <-exited:
	case <-time.After(testTimeout):
		t.Fatal("a stream paused after its page went away never ended")
	}
}

// TestNetConnectDeliversItsTail checks that what a TCP peer sends right before it closes comes out before the stream's
// end, though it arrives within the coalescing window of the previous event.
func TestNetConnectDeliversItsTail(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	seen := make(chan struct{})
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		if _, err := conn.Write([]byte("first")); err != nil {
			t.Error(err)
			return
		}
		<-seen
		if _, err := conn.Write([]byte("tail")); err != nil {
			t.Error(err)
		}
	}()
	h := newHarness(t)
	stream := h.open("net.connect", map[string]any{"machine": "local", "host": "127.0.0.1",
		"port": listener.Addr().(*net.TCPAddr).Port})
	if m := h.next(stream); m.Params.Data != base64.StdEncoding.EncodeToString([]byte("first")) {
		t.Fatalf("first event %s", m.raw)
	}
	close(seen)
	if got, exit := h.drainBytes(stream); string(got) != "tail" || exit.Params.Code == nil || *exit.Params.Code != 0 {
		t.Fatalf("after the first event: %q (%s)", got, exit.raw)
	}
}

func TestSSHHandshakeTimeout(t *testing.T) {
	timeout := sshDialTimeout
	sshDialTimeout = 300 * time.Millisecond
	t.Cleanup(func() { sshDialTimeout = timeout })
	// A server that takes connections and never says a word.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	h := newHarness(t)
	port := listener.Addr().(*net.TCPAddr).Port
	start := time.Now()
	m := h.call("ssh.connect", map[string]any{"host": "127.0.0.1", "port": port, "user": "x",
		"auth": map[string]any{"password": "y"}})
	if m.Error == nil || m.Error.Code != "timeout" || m.Error.Hop == nil || *m.Error.Hop != 0 ||
		!strings.Contains(m.Error.Message, "no answer during key exchange within 300ms") || time.Since(start) > 5*time.Second {
		t.Fatalf("ssh.connect to a silent server answered %s after %v", m.raw, time.Since(start))
	}
	(<-accepted).Close()
}
