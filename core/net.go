package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"
)

// dialFrom opens a TCP connection to host:port as machine sees it: directly for "local", else with SSH direct-tcpip.
func (c *Core) dialFrom(ctx context.Context, machine, host string, port int) (net.Conn, error) {
	address := net.JoinHostPort(host, strconv.Itoa(port))
	if machine == "local" {
		var dialer net.Dialer
		conn, err := dialer.DialContext(ctx, "tcp", address)
		if err != nil {
			return nil, withCode("unreachable", err)
		}
		return conn, nil
	}
	m, err := c.machine(machine)
	if err != nil {
		return nil, err
	}
	conn, err := m.primary.client.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, withCode("unreachable", fmt.Errorf("%s cannot reach %s: %w", m.label, address, m.lost(err)))
	}
	return conn, nil
}

// forward is one net.forward listener with the connections it carries.
type forward struct {
	id       string
	machine  string
	listener net.Listener

	mu     sync.Mutex
	conns  map[net.Conn]struct{}
	closed bool
}

func (c *Core) netForward(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Machine   string `json:"machine"`
		Host      string `json:"host"`
		Port      int    `json:"port"`
		LocalPort int    `json:"localPort"`
	}](params)
	if err != nil {
		return nil, err
	}
	if p.Host == "" || p.Port <= 0 {
		return nil, errors.New("net.forward needs host and port")
	}
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(p.LocalPort)))
	if err != nil {
		return nil, err
	}
	f := &forward{id: c.newID("f"), machine: p.Machine, listener: listener, conns: map[net.Conn]struct{}{}}
	// Checked with the forward's registration: a machine that closes meanwhile must find the forward to close it.
	c.mu.Lock()
	_, open := c.machines[p.Machine]
	open = open || p.Machine == "local"
	if open {
		c.forwards[f.id] = f
	}
	c.mu.Unlock()
	if !open {
		return nil, errors.Join(unknownMachine(p.Machine), notClosed(listener.Close()))
	}
	go c.serveForward(f, p.Host, p.Port)
	return map[string]any{"forward": f.id, "localPort": listener.Addr().(*net.TCPAddr).Port}, nil
}

func (c *Core) serveForward(f *forward, host string, port int) {
	for {
		local, err := f.listener.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) {
				c.writeLog(fmt.Sprintf("net: forward %s stopped: %v", f.id, err))
			}
			c.closeForward(f)
			return
		}
		go func() {
			if !f.track(local) {
				return
			}
			defer f.untrack(local)
			ctx, cancel := context.WithTimeout(context.Background(), sshDialTimeout)
			remote, err := c.dialFrom(ctx, f.machine, host, port)
			cancel()
			if err != nil {
				c.writeLog(fmt.Sprintf("net: forward %s: %v", f.id, err))
				return
			}
			if !f.track(remote) {
				return
			}
			defer f.untrack(remote)
			if err := pipe(local, remote); err != nil {
				c.writeLog(fmt.Sprintf("net: forward %s: %v", f.id, err))
			}
		}()
	}
}

// track registers conn so closing the forward closes it; false (with conn closed) when the forward is closed.
func (f *forward) track(conn net.Conn) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		_ = conn.Close() // never used; the forward that wanted it is gone
		return false
	}
	f.conns[conn] = struct{}{}
	return true
}

func (f *forward) untrack(conn net.Conn) {
	f.mu.Lock()
	delete(f.conns, conn)
	f.mu.Unlock()
	_ = conn.Close() // both directions already ended; a second close only reports that
}

// pipe copies both ways until both directions ended, passing each direction's end on as a half close.
func pipe(a, b net.Conn) error {
	errs := make(chan error, 2)
	carry := func(to, from net.Conn) {
		_, err := io.Copy(to, from)
		if closer, ok := to.(interface{ CloseWrite() error }); ok {
			err = errors.Join(err, notEOF(closer.CloseWrite()))
		}
		errs <- err
	}
	go carry(a, b)
	go carry(b, a)
	err := errors.Join(<-errs, <-errs)
	if errors.Is(err, net.ErrClosed) {
		return nil // the forward was closed
	}
	return err
}

func (c *Core) netForwardClose(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Forward string `json:"forward"`
	}](params)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	f, ok := c.forwards[p.Forward]
	c.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("unknown forward %q", p.Forward)
	}
	c.closeForward(f)
	return struct{}{}, nil
}

// closeForward stops the listener and every connection it carries.
func (c *Core) closeForward(f *forward) {
	c.mu.Lock()
	delete(c.forwards, f.id)
	c.mu.Unlock()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return
	}
	f.closed = true
	if err := f.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
		c.writeLog(fmt.Sprintf("net: closing forward %s: %v", f.id, err))
	}
	for conn := range f.conns {
		_ = conn.Close() // ends its pipe, which reports what happened
	}
}

// closeForwardsOf closes the forwards that run through machine, once it is gone.
func (c *Core) closeForwardsOf(machine string) {
	c.mu.Lock()
	var gone []*forward
	for _, f := range c.forwards {
		if f.machine == machine {
			gone = append(gone, f)
		}
	}
	c.mu.Unlock()
	for _, f := range gone {
		c.closeForward(f)
	}
}

func (c *Core) netConnect(params json.RawMessage) (any, func(), error) {
	p, err := decode[struct {
		Machine string `json:"machine"`
		Host    string `json:"host"`
		Port    int    `json:"port"`
	}](params)
	if err != nil {
		return nil, nil, err
	}
	if p.Host == "" || p.Port <= 0 {
		return nil, nil, errors.New("net.connect needs host and port")
	}
	ctx, cancel := context.WithTimeout(context.Background(), sshDialTimeout)
	conn, err := c.dialFrom(ctx, p.Machine, p.Host, p.Port)
	cancel()
	if err != nil {
		return nil, nil, err
	}
	s := c.newStream(true)
	s.machine = p.Machine
	s.stdin = halfCloser{conn}
	s.kill = conn.Close
	c.register(s)
	out := c.output(s, "stdout")
	return map[string]string{"stream": s.id}, func() {
		close(s.started)
		_, err := io.Copy(out, conn)
		if errors.Is(err, net.ErrClosed) {
			err = errors.New("killed")
		}
		end := ending{code: 0}
		if err != nil {
			end = ending{code: -1, err: err}
		}
		end.err = errors.Join(end.err, notClosed(conn.Close()))
		out.flush()
		c.exit(s, end)
	}, nil
}

// halfCloser is a connection's write side: Close sends EOF and keeps reading.
type halfCloser struct{ conn net.Conn }

func (h halfCloser) Write(p []byte) (int, error) { return h.conn.Write(p) }

func (h halfCloser) Close() error {
	if closer, ok := h.conn.(interface{ CloseWrite() error }); ok {
		return closer.CloseWrite()
	}
	return errors.New("this connection cannot close only its write side")
}

// notClosed drops net.ErrClosed: closing a connection that a kill already closed.
func notClosed(err error) error {
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

// fetchLimit is net.fetch's default maxBytes and fetchMax the most it allows; fetchStall is how long a download may
// go without a byte before it fails. Variables so a test can lower them.
var (
	fetchLimit int64 = 50 << 20
	fetchMax   int64 = 1 << 30
	fetchStall       = time.Minute
)

func (c *Core) netFetch(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		URL      string `json:"url"`
		MaxBytes int64  `json:"maxBytes"`
	}](params)
	if err != nil {
		return nil, err
	}
	limit := fetchLimit
	if p.MaxBytes != 0 {
		if p.MaxBytes < 0 || p.MaxBytes > fetchMax {
			return nil, fmt.Errorf("net.fetch takes maxBytes up to %d, not %d", fetchMax, p.MaxBytes)
		}
		limit = p.MaxBytes
	}
	parsed, err := url.Parse(p.URL)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, fmt.Errorf("net.fetch takes http and https URLs, not %q", parsed.Scheme)
	}
	// A large download takes as long as it takes; one that stops moving fails.
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	stall := time.AfterFunc(fetchStall, func() { cancel(fmt.Errorf("no data for %v", fetchStall)) })
	defer stall.Stop()
	failed := func(err error) error {
		if cause := context.Cause(ctx); cause != nil {
			err = cause
		}
		return fmt.Errorf("GET %s: %w", p.URL, err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, p.URL, nil)
	if err != nil {
		return nil, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, withCode("unreachable", failed(err))
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, fmt.Errorf("GET %s: %s", p.URL, response.Status)
	}
	if response.ContentLength > limit {
		return nil, fmt.Errorf("GET %s: %d bytes is over the limit of %d", p.URL, response.ContentLength, limit)
	}
	mimeType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil {
		mimeType = "application/octet-stream" // absent or malformed: the page sniffs or refuses it
	}
	ext := extension(parsed.Path)
	if ext == "" {
		if known, err := mime.ExtensionsByType(mimeType); err == nil && len(known) > 0 {
			ext = extension(known[0])
		}
	}
	digest := sha256.New()
	body := io.TeeReader(&fetchBody{r: response.Body, left: limit, limit: limit, stall: stall}, digest)
	name, size, err := toCache(p.URL, ext, body)
	if err != nil {
		return nil, failed(err)
	}
	return map[string]any{"url": "cache/" + name, "name": name, "size": size, "mimeType": mimeType,
		"sha256": hex.EncodeToString(digest.Sum(nil))}, nil
}

// fetchBody fails once the body yields more than limit bytes (io.LimitReader would end quietly), and keeps the stall
// timer from firing while bytes arrive.
type fetchBody struct {
	r     io.Reader
	left  int64
	limit int64
	stall *time.Timer
}

func (b *fetchBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	if n > 0 {
		b.stall.Reset(fetchStall)
	}
	b.left -= int64(n)
	if b.left < 0 {
		return n, fmt.Errorf("the download is over the limit of %d bytes", b.limit)
	}
	return n, err
}
