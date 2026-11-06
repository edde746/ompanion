package core

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
	"unicode/utf8"
)

// stream is one running process, local or remote, plain or on a PTY, or one TCP connection.
type stream struct {
	id string
	// machine is the SSH machine the stream runs on; "" or "local" for this device.
	machine string

	// started is closed once the response naming the stream was emitted; output waits for it.
	started chan struct{}

	// order chains stream.write and stream.closeStdin in the order the requests arrived: the core answers requests
	// concurrently, and keystrokes must not overtake each other. flowOrder chains stream.pause and stream.resume the
	// same way, apart, so a write blocked on a full stdin does not hold up a pause. Guarded by Core.mu.
	order, flowOrder chan struct{}

	// binary streams carry base64 in stream.data and stream.write instead of UTF-8 text.
	binary bool

	stdin  io.WriteCloser
	kill   func() error
	resize func(cols, rows int) error // nil when the stream is not a PTY

	// flowMu is held while the stream emits an event, so none is emitted after a pause's response. Guards paused
	// and quiet.
	flowMu sync.Mutex
	// paused is open while the stream is paused; resume closes it.
	paused chan struct{}
	// quiet is set once stream.exit was emitted, or the page that opened the stream went away: nothing more is
	// emitted for it, such as output a copy still delivers.
	quiet bool
}

// silence drops the stream's events from now on and resumes it, so it can end: the page that opened it went away.
func (s *stream) silence() {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	s.quiet = true
	if s.paused != nil {
		close(s.paused)
		s.paused = nil
	}
}

// pause stops the stream's events: its outputs wait in Write, so the reads stop, until resume. A quiet stream emits
// nothing more, and no page would resume it: it runs on to its end.
func (s *stream) pause() {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	if s.paused == nil && !s.quiet {
		s.paused = make(chan struct{})
	}
}

func (s *stream) resume() {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	if s.paused != nil {
		close(s.paused)
		s.paused = nil
	}
}

// whenRunning runs emit holding flowMu, once the stream is not paused.
func (s *stream) whenRunning(emit func()) {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	for s.paused != nil {
		paused := s.paused
		s.flowMu.Unlock()
		<-paused
		s.flowMu.Lock()
	}
	emit()
}

// pausedUntil returns a channel closed by the next resume, or nil when the stream is not paused.
func (s *stream) pausedUntil() chan struct{} {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	return s.paused
}

// ending is how a stream ended: an exit code (-1 when there is none), the signal that ended it, and why there is no
// code.
type ending struct {
	code   int
	signal string
	err    error
}

// newStream returns a stream with a fresh id; the caller fills in its process and then registers it.
func (c *Core) newStream(binary bool) *stream {
	order, flowOrder := make(chan struct{}), make(chan struct{})
	close(order)
	close(flowOrder)
	return &stream{id: c.newID("s"), started: make(chan struct{}), order: order, flowOrder: flowOrder, binary: binary}
}

// streamEncoding reads the encoding param of a method that starts a stream: false for "utf8" (the default), true for
// "base64".
func streamEncoding(encoding string) (binary bool, err error) {
	switch encoding {
	case "", "utf8":
		return false, nil
	case "base64":
		return true, nil
	default:
		return false, fmt.Errorf("unknown encoding %q: use utf8 or base64", encoding)
	}
}

func (c *Core) register(s *stream) {
	c.mu.Lock()
	c.streams[s.id] = s
	c.mu.Unlock()
}

func (c *Core) stream(id string) (*stream, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s, ok := c.streams[id]
	if !ok {
		return nil, fmt.Errorf("unknown stream %q", id)
	}
	return s, nil
}

// exit emits a stream's last event, once it is not paused, and then forgets it: a request that crosses the end is
// answered `unknown stream` only after the page has the end (whileOpen in ui/src/core/transport/bridge_link.ts).
func (c *Core) exit(s *stream, end ending) {
	params := map[string]any{"stream": s.id, "code": nil}
	if end.code >= 0 {
		params["code"] = end.code
	}
	if end.signal != "" {
		params["signal"] = end.signal
	}
	if end.err != nil {
		params["error"] = end.err.Error()
	}
	s.whenRunning(func() {
		if !s.quiet {
			s.quiet = true
			c.Event("stream.exit", params)
		}
		c.mu.Lock()
		delete(c.streams, s.id)
		c.mu.Unlock()
	})
}

// resumeStreamsOf resumes the streams that ran on machine, once it is gone: they end, and their stream.exit comes.
func (c *Core) resumeStreamsOf(machine string) {
	c.mu.Lock()
	var gone []*stream
	for _, s := range c.streams {
		if s.machine == machine {
			gone = append(gone, s)
		}
	}
	c.mu.Unlock()
	for _, s := range gone {
		s.resume()
	}
}

// orderedStream returns the stream an ordered method names and whether it is a flow method (stream.pause,
// stream.resume) rather than an input one (stream.write, stream.closeStdin); "" for any other request.
func orderedStream(method string, params json.RawMessage) (id string, flow bool) {
	switch method {
	case "stream.write", "stream.closeStdin":
	case "stream.pause", "stream.resume":
		flow = true
	default:
		return "", false
	}
	var p struct {
		Stream string `json:"stream"`
	}
	if json.Unmarshal(params, &p) != nil {
		return "", false
	}
	return p.Stream, flow
}

// takeTurn reserves the next turn among a stream's input or flow requests. The request runs after wait is closed
// and closes done when it finished.
func (c *Core) takeTurn(id string, flow bool) (wait, done chan struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s, ok := c.streams[id]
	if !ok {
		return nil, nil
	}
	done = make(chan struct{})
	if flow {
		wait, s.flowOrder = s.flowOrder, done
	} else {
		wait, s.order = s.order, done
	}
	return wait, done
}

type streamParams struct {
	Stream string `json:"stream"`
}

func (c *Core) streamWrite(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Stream string `json:"stream"`
		Data   string `json:"data"`
	}](params)
	if err != nil {
		return nil, err
	}
	s, err := c.stream(p.Stream)
	if err != nil {
		return nil, err
	}
	data := []byte(p.Data)
	if s.binary {
		if data, err = base64.StdEncoding.DecodeString(p.Data); err != nil {
			return nil, fmt.Errorf("%s takes base64 data: %w", s.id, err)
		}
	}
	if _, err := s.stdin.Write(data); err != nil {
		return nil, fmt.Errorf("writing to %s: %w", s.id, err)
	}
	return struct{}{}, nil
}

func (c *Core) streamCloseStdin(params json.RawMessage) (any, error) {
	p, err := decode[streamParams](params)
	if err != nil {
		return nil, err
	}
	s, err := c.stream(p.Stream)
	if err != nil {
		return nil, err
	}
	// Already closed is closed: a local pipe the process's exit closed (os.ErrClosed), or an SSH channel the server
	// closed (io.EOF).
	if err := s.stdin.Close(); err != nil && !errors.Is(err, os.ErrClosed) && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("closing the stdin of %s: %w", s.id, err)
	}
	return struct{}{}, nil
}

// streamKill kills the stream's process, resuming the stream first: its last output and stream.exit come even
// when the page that paused it is gone.
func (c *Core) streamKill(params json.RawMessage) (any, error) {
	p, err := decode[streamParams](params)
	if err != nil {
		return nil, err
	}
	s, err := c.stream(p.Stream)
	if err != nil {
		return nil, err
	}
	s.resume()
	if err := s.kill(); err != nil {
		return nil, fmt.Errorf("killing %s: %w", s.id, err)
	}
	return struct{}{}, nil
}

// streamFlow runs stream.pause (pause true) or stream.resume.
func (c *Core) streamFlow(params json.RawMessage, pause bool) (any, error) {
	p, err := decode[streamParams](params)
	if err != nil {
		return nil, err
	}
	s, err := c.stream(p.Stream)
	if err != nil {
		return nil, err
	}
	if pause {
		s.pause()
	} else {
		s.resume()
	}
	return struct{}{}, nil
}

func (c *Core) ptyResize(params json.RawMessage) (any, func(), error) {
	p, err := decode[struct {
		Stream string `json:"stream"`
		Cols   int    `json:"cols"`
		Rows   int    `json:"rows"`
	}](params)
	if err != nil {
		return nil, nil, err
	}
	if p.Cols <= 0 || p.Rows <= 0 {
		return nil, nil, errors.New("pty.resize needs cols > 0 and rows > 0")
	}
	s, err := c.stream(p.Stream)
	if err != nil {
		return nil, nil, err
	}
	if s.resize == nil {
		return nil, nil, fmt.Errorf("%s is not a PTY", s.id)
	}
	if err := s.resize(p.Cols, p.Rows); err != nil {
		return nil, nil, fmt.Errorf("resizing %s: %w", s.id, err)
	}
	return struct{}{}, nil, nil
}

// Output that arrives within coalesceWindow of a stream.data event goes out gathered in the next one, which carries at
// most coalesceMax bytes before it is sent at once: a PTY hands out a flood a few bytes per read, and every event
// costs the page far more than its bytes. The first output after a quiet window goes out at once, so typing echoes
// without delay.
const (
	coalesceWindow = 4 * time.Millisecond
	coalesceMax    = 64 << 10
)

// output turns the bytes of one fd into stream.data events. For a text stream it holds back an unfinished UTF-8
// sequence at the end of what it sends until more bytes complete it. Its first event waits for the stream's response,
// and every event for the stream to resume: a write that has to send then waits, so what copies into it stops reading.
// One goroutine writes to it at a time.
type output struct {
	core *Core
	s    *stream
	fd   string

	// mu guards pending, spare, scheduled, last and closed.
	mu        sync.Mutex
	pending   []byte    // written, not sent yet
	spare     []byte    // the buffer pending swaps with
	scheduled bool      // a timer sends pending
	last      time.Time // when pending was last taken to be sent
	closed    bool      // flush ran: later writes fail

	// sendMu orders sends: pending is taken and emitted holding it. It guards buf and carry.
	sendMu sync.Mutex
	buf    []byte
	carry  int // bytes at the start of buf: an unfinished UTF-8 sequence from the previous send
}

func (c *Core) output(s *stream, fd string) *output {
	return &output{core: c, s: s, fd: fd}
}

func (o *output) Write(p []byte) (int, error) {
	<-o.s.started
	if len(p) == 0 {
		return 0, nil
	}
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return 0, os.ErrClosed
	}
	o.pending = append(o.pending, p...)
	wait := coalesceWindow - time.Since(o.last)
	now := len(o.pending) >= coalesceMax || (wait <= 0 && !o.scheduled)
	if !now && !o.scheduled {
		o.scheduled = true
		time.AfterFunc(wait, o.send)
	}
	o.mu.Unlock()
	if now {
		o.send()
	}
	return len(p), nil
}

// send emits what is pending, once the stream is not paused.
func (o *output) send() {
	o.sendMu.Lock()
	defer o.sendMu.Unlock()
	o.mu.Lock()
	chunk := o.pending
	o.pending, o.spare = o.spare[:0], nil
	o.scheduled = false
	if len(chunk) > 0 {
		o.last = time.Now()
	}
	o.mu.Unlock()
	if len(chunk) == 0 {
		return
	}
	o.s.whenRunning(func() {
		switch {
		case o.s.quiet:
		case o.s.binary:
			o.core.data(o.s.id, o.fd, base64.StdEncoding.EncodeToString(chunk))
		default:
			o.buf = append(o.buf[:o.carry], chunk...)
			end := completeUTF8(o.buf)
			if end > 0 {
				o.core.data(o.s.id, o.fd, string(o.buf[:end]))
			}
			o.carry = copy(o.buf, o.buf[end:])
		}
	})
	o.mu.Lock()
	o.spare = chunk
	o.mu.Unlock()
}

// flush sends what is pending, then emits a held-back sequence that never completed (it becomes U+FFFD). Writes after
// it fail.
func (o *output) flush() {
	o.mu.Lock()
	o.closed = true
	o.mu.Unlock()
	o.send()
	o.sendMu.Lock()
	defer o.sendMu.Unlock()
	o.s.whenRunning(func() {
		if o.carry > 0 && !o.s.quiet {
			o.core.data(o.s.id, o.fd, string(o.buf[:o.carry]))
			o.carry = 0
		}
	})
}

func (c *Core) data(id, fd, data string) {
	c.Event("stream.data", map[string]string{"stream": id, "fd": fd, "data": data})
}

// completeUTF8 returns the length of b without a trailing UTF-8 sequence that more bytes could still complete.
// Invalid bytes count as complete: JSON encoding turns them into U+FFFD.
func completeUTF8(b []byte) int {
	for i := len(b) - 1; i >= 0 && i > len(b)-utf8.UTFMax; i-- {
		switch {
		case b[i] < utf8.RuneSelf:
			return len(b)
		case utf8.RuneStart(b[i]):
			if utf8.FullRune(b[i:]) {
				return len(b)
			}
			return i
		}
	}
	return len(b)
}
