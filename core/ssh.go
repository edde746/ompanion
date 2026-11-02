package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

// The target gets a keepalive every keepAliveSec (default 15) and is closed as dead after keepAliveMax (default 3)
// unanswered in a row, as SshLiveness. An extra connection to the target closes after idleClose without sessions.
// Variables so a test can shorten them.
var (
	keepaliveUnit = time.Second
	idleClose     = 30 * time.Second
)

// machine is one SSH connection to a target, possibly through jump hosts. Session channels (exec, PTY, SFTP) spread
// over extra connections to the target when sshd's MaxSessions (default 10) refuses one, as SshLink does.
type machine struct {
	id     string
	label  string // the target's
	key    string // every hop, for names of downloaded files
	core   *Core
	dialer *dialer
	jumps  []*ssh.Client

	primary *targetConn // the first connection to the target, never retired: keepalives and direct-tcpip go there

	mu      sync.Mutex
	conns   []*targetConn // the primary, then the extra connections
	adding  chan struct{} // closed when the dial of an extra connection in flight ends
	closed  chan struct{} // closed when close starts; reason is set before
	reason  error
	closing sync.Once

	sftpMu sync.Mutex
	sftp   *sftp.Client
}

// targetConn is one SSH connection to the target, with its session channel accounting.
type targetConn struct {
	client  *ssh.Client
	open    int  // session channels in use
	setups  int  // session channel opens in flight
	full    bool // refused a session channel while others were open (MaxSessions); cleared when one closes
	retired bool
	idle    *time.Timer
}

func (c *Core) sshConnect(page uint64, params json.RawMessage) (any, error) {
	p, err := decode[struct {
		sshHop
		ProxyCommand string          `json:"proxyCommand"`
		Jump         []sshHop        `json:"jump"`
		KeepAliveSec float64         `json:"keepAliveSec"`
		KeepAliveMax int             `json:"keepAliveMax"`
		TimeoutSec   float64         `json:"timeoutSec"`
		Tag          json.RawMessage `json:"tag"`
	}](params)
	if err != nil {
		return nil, err
	}
	hops := append(slices.Clone(p.Jump), p.sshHop)
	timeout := sshDialTimeout
	if p.TimeoutSec > 0 {
		timeout = time.Duration(p.TimeoutSec * float64(time.Second))
	}
	every := 15 * keepaliveUnit
	if p.KeepAliveSec > 0 {
		every = time.Duration(p.KeepAliveSec * float64(keepaliveUnit))
	}
	maxMissed := 3
	if p.KeepAliveMax > 0 {
		maxMissed = p.KeepAliveMax
	}
	d, err := newDialer(c, page, hops, p.Tag, timeout, p.ProxyCommand)
	if err != nil {
		return nil, err
	}
	var clients []*ssh.Client
	for i, hop := range hops {
		var via *ssh.Client
		if i > 0 {
			via = clients[i-1]
		}
		client, err := d.dial(i, via)
		if err != nil {
			for j := len(clients) - 1; j >= 0; j-- {
				err = errors.Join(err, notClosedConn(clients[j].Close()))
			}
			return nil, hopError(i, hop, err)
		}
		clients = append(clients, client)
	}
	labels := make([]string, len(hops))
	for i, hop := range hops {
		labels[i] = hop.label()
	}
	last := len(clients) - 1
	primary := &targetConn{client: clients[last]}
	m := &machine{
		id:      c.newID("m"),
		label:   hops[last].label(),
		key:     strings.Join(labels, " > "),
		core:    c,
		dialer:  d,
		jumps:   clients[:last],
		primary: primary,
		conns:   []*targetConn{primary},
		closed:  make(chan struct{}),
	}
	c.mu.Lock()
	c.machines[m.id] = m
	c.mu.Unlock()
	for i, jump := range m.jumps {
		go m.watch(jump, hops[i].label(), nil)
	}
	go m.watch(clients[last], m.label, primary)
	go m.keepalive(every, maxMissed)
	return map[string]any{"machine": m.id, "hostKeys": d.hostKeys()}, nil
}

func (c *Core) machine(id string) (*machine, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	m, ok := c.machines[id]
	if !ok {
		return nil, withCode("closed", fmt.Errorf("unknown machine %q", id))
	}
	return m, nil
}

// close closes the machine's connections, the target's first, and the forwards through it; reason says why, for the
// streams it ends and, unless the page asked for it, for ssh.closed.
func (m *machine) close(reason error, asked bool) {
	m.closing.Do(func() {
		m.core.mu.Lock()
		delete(m.core.machines, m.id)
		m.core.mu.Unlock()
		m.mu.Lock()
		m.reason = reason
		close(m.closed)
		conns := m.conns
		for _, conn := range conns {
			if conn.idle != nil {
				conn.idle.Stop()
			}
		}
		m.mu.Unlock()
		var errs []error
		for _, conn := range conns {
			errs = append(errs, notClosedConn(conn.client.Close()))
		}
		for i := len(m.jumps) - 1; i >= 0; i-- {
			errs = append(errs, notClosedConn(m.jumps[i].Close()))
		}
		if err := errors.Join(errs...); err != nil {
			m.core.writeLog(fmt.Sprintf("ssh: closing %s: %v", m.id, err))
		}
		m.core.closeForwardsOf(m.id)
		m.core.resumeStreamsOf(m.id)
		if !asked {
			m.core.Event("ssh.closed", map[string]string{"machine": m.id, "error": reason.Error()})
		}
	})
}

// notClosedConn drops what closing an SSH connection that already ended reports.
func notClosedConn(err error) error {
	if errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// lost explains err, a failure on m, when m was closed meanwhile.
func (m *machine) lost(err error) error {
	select {
	case <-m.closed:
		return withCode("closed", fmt.Errorf("%s is closed: %v", m.label, m.reason))
	default:
		return err
	}
}

// ended explains err, the end of a session on m without an exit status, when m was closed.
func (m *machine) ended(err error) error {
	var missing *ssh.ExitMissingError
	if !errors.As(err, &missing) {
		return err
	}
	select {
	case <-m.closed:
		return m.reason
	default:
		return err
	}
}

// watch closes the machine when one of its connections ends, unless it was an idle extra connection retired on
// purpose; conn is nil for a jump host.
func (m *machine) watch(client *ssh.Client, label string, conn *targetConn) {
	err := client.Wait()
	if conn != nil {
		m.mu.Lock()
		retired := conn.retired
		m.mu.Unlock()
		if retired {
			return
		}
	}
	reason := fmt.Errorf("%s: connection closed", label)
	if err != nil {
		reason = fmt.Errorf("%s: connection closed: %w", label, err)
	}
	m.close(reason, false)
}

// keepalive closes the machine as dead when the target leaves maxMissed keepalives in a row unanswered.
func (m *machine) keepalive(every time.Duration, maxMissed int) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	client := m.primary.client
	var unanswered atomic.Int32
	for {
		select {
		case <-m.closed:
			return
		case <-ticker.C:
		}
		if n := unanswered.Load(); int(n) >= maxMissed {
			m.core.writeLog(fmt.Sprintf("ssh: %s did not answer %d keepalives", m.id, n))
			m.close(fmt.Errorf("%s did not answer %d keepalives", m.label, n), false)
			return
		}
		unanswered.Add(1)
		go func() {
			if _, _, err := client.SendRequest("keepalive@openssh.com", true, nil); err != nil {
				m.close(fmt.Errorf("%s: connection lost: %w", m.label, err), false)
				return
			}
			unanswered.Store(0)
		}()
	}
}

// session opens a session channel on a target connection with room, dialing another connection when every one
// refuses it. release must run once the session closed.
func (m *machine) session() (session *ssh.Session, release func(), err error) {
	for retry := 0; ; {
		conn, err := m.roomyConn()
		if err != nil {
			return nil, nil, err
		}
		session, err := conn.client.NewSession()
		m.mu.Lock()
		conn.setups--
		if err == nil {
			conn.open++
			m.mu.Unlock()
			var once sync.Once
			return session, func() { once.Do(func() { m.release(conn) }) }, nil
		}
		var refusal *ssh.OpenChannelError
		if !errors.As(err, &refusal) {
			m.retireWhenIdle(conn)
			m.mu.Unlock()
			return nil, nil, m.lost(err)
		}
		// sshd refuses session channels past MaxSessions. With none open or opening here, either sessions closed
		// just now still count on the server, which frees them only once it handled their close, or it refuses
		// sessions altogether: try again a little later, then give up.
		if conn.open == 0 && conn.setups == 0 {
			m.retireWhenIdle(conn)
			m.mu.Unlock()
			if retry == 3 {
				return nil, nil, fmt.Errorf("%s refused a session channel: %w", m.label, err)
			}
			time.Sleep(50 * time.Millisecond << retry)
			retry++
			continue
		}
		conn.full = true
		m.mu.Unlock()
	}
}

// roomyConn returns a target connection that has not refused a session channel, with a setup counted on it.
func (m *machine) roomyConn() (*targetConn, error) {
	m.mu.Lock()
	for {
		select {
		case <-m.closed:
			m.mu.Unlock()
			return nil, m.lost(nil)
		default:
		}
		for _, conn := range m.conns {
			if !conn.full && !conn.retired {
				conn.setups++
				if conn.idle != nil {
					conn.idle.Stop()
				}
				m.mu.Unlock()
				return conn, nil
			}
		}
		if wait := m.adding; wait != nil {
			m.mu.Unlock()
			<-wait
			m.mu.Lock()
			continue
		}
		adding := make(chan struct{})
		m.adding = adding
		m.mu.Unlock()
		var via *ssh.Client
		if len(m.jumps) > 0 {
			via = m.jumps[len(m.jumps)-1]
		}
		target := len(m.dialer.hops) - 1
		client, err := m.dialer.dial(target, via)
		m.mu.Lock()
		m.adding = nil
		close(adding)
		if err != nil {
			m.mu.Unlock()
			return nil, hopError(target, m.dialer.hops[target].hop, err)
		}
		select {
		case <-m.closed:
			m.mu.Unlock()
			return nil, errors.Join(m.lost(nil), notClosedConn(client.Close()))
		default:
		}
		conn := &targetConn{client: client}
		m.conns = append(m.conns, conn)
		go m.watch(client, m.label, conn)
	}
}

func (m *machine) release(conn *targetConn) {
	m.mu.Lock()
	defer m.mu.Unlock()
	conn.open--
	conn.full = false
	m.retireWhenIdle(conn)
}

// retireWhenIdle closes an extra connection after idleClose without sessions. m.mu is held.
func (m *machine) retireWhenIdle(conn *targetConn) {
	if conn == m.primary || conn.open > 0 || conn.setups > 0 || conn.retired {
		return
	}
	if conn.idle != nil {
		conn.idle.Stop()
	}
	conn.idle = time.AfterFunc(idleClose, func() {
		m.mu.Lock()
		if conn.open > 0 || conn.setups > 0 || conn.retired {
			m.mu.Unlock()
			return
		}
		conn.retired = true
		m.conns = slices.DeleteFunc(m.conns, func(c *targetConn) bool { return c == conn })
		m.mu.Unlock()
		if err := notClosedConn(conn.client.Close()); err != nil {
			m.core.writeLog(fmt.Sprintf("ssh: closing an idle connection of %s: %v", m.id, err))
		}
	})
}

// files returns the machine's SFTP client, opening it on first use and again after it broke.
func (m *machine) files() (fileSystem, error) {
	m.sftpMu.Lock()
	defer m.sftpMu.Unlock()
	if m.sftp != nil {
		return sftpFiles{m.sftp}, nil
	}
	session, release, err := m.session()
	if err != nil {
		return nil, err
	}
	fail := func(err error) (fileSystem, error) {
		err = errors.Join(fmt.Errorf("%s: sftp: %w", m.label, m.lost(err)), notEOF(session.Close()))
		release()
		return nil, err
	}
	stdin, err := session.StdinPipe()
	if err != nil {
		return fail(err)
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return fail(err)
	}
	if err := session.RequestSubsystem("sftp"); err != nil {
		return fail(err)
	}
	client, err := sftp.NewClientPipe(stdout, stdin)
	if err != nil {
		return fail(err)
	}
	m.sftp = client
	go func() {
		err := client.Wait()
		m.sftpMu.Lock()
		if m.sftp == client {
			m.sftp = nil
		}
		m.sftpMu.Unlock()
		if err := errors.Join(notEOF(err), notEOF(session.Close())); err != nil {
			select {
			case <-m.closed:
			default:
				m.core.writeLog(fmt.Sprintf("ssh: the SFTP client of %s ended: %v", m.id, err))
			}
		}
		release()
	}()
	return sftpFiles{client}, nil
}

func (c *Core) sshClose(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		Machine string `json:"machine"`
	}](params)
	if err != nil {
		return nil, err
	}
	m, err := c.machine(p.Machine)
	if err != nil {
		return nil, err
	}
	// Closing the connections ends every session on them, so each stream emits its stream.exit.
	m.close(errors.New("ssh.close closed the machine"), true)
	return struct{}{}, nil
}

func (c *Core) sshExec(params json.RawMessage) (any, func(), error) {
	p, err := decode[struct {
		Machine  string `json:"machine"`
		Command  string `json:"command"`
		Encoding string `json:"encoding"`
	}](params)
	if err != nil {
		return nil, nil, err
	}
	if p.Command == "" {
		return nil, nil, errors.New("ssh.exec needs command")
	}
	binary, err := streamEncoding(p.Encoding)
	if err != nil {
		return nil, nil, err
	}
	m, err := c.machine(p.Machine)
	if err != nil {
		return nil, nil, err
	}
	session, release, err := m.session()
	if err != nil {
		return nil, nil, err
	}
	return c.runSession(m, session, release, binary, nil, func() error { return session.Start(p.Command) })
}

func (c *Core) sshPTY(p ptyParams, binary bool) (any, func(), error) {
	m, err := c.machine(p.Machine)
	if err != nil {
		return nil, nil, err
	}
	session, release, err := m.session()
	if err != nil {
		return nil, nil, err
	}
	fail := func(err error) (any, func(), error) {
		err = errors.Join(err, notEOF(session.Close()))
		release()
		return nil, nil, err
	}
	for key, value := range p.Env {
		if key == "TERM" {
			continue
		}
		if err := session.Setenv(key, value); err != nil {
			return fail(fmt.Errorf("setting %s (sshd takes only what its AcceptEnv lists): %w", key, err))
		}
	}
	if err := session.RequestPty(p.term(), p.Rows, p.Cols, nil); err != nil {
		return fail(err)
	}
	resize := func(cols, rows int) error { return session.WindowChange(rows, cols) }
	start := session.Shell
	if p.Command != "" {
		start = func() error { return session.Start(p.Command) }
	}
	return c.runSession(m, session, release, binary, resize, start)
}

// runSession starts session on m as a stream; resize is nil when it has no PTY. release runs once it ended.
func (c *Core) runSession(m *machine, session *ssh.Session, release func(), binary bool,
	resize func(cols, rows int) error, start func() error) (any, func(), error) {
	fail := func(err error) (any, func(), error) {
		err = errors.Join(m.lost(err), notEOF(session.Close()))
		release()
		return nil, nil, err
	}
	stdin, err := session.StdinPipe()
	if err != nil {
		return fail(err)
	}
	s := c.newStream(binary)
	s.machine = m.id
	stdout, stderr := c.output(s, "stdout"), c.output(s, "stderr")
	session.Stdout, session.Stderr = stdout, stderr
	if err := start(); err != nil {
		return fail(err)
	}
	s.stdin = stdin
	s.kill = func() error {
		// Not every server delivers signals; closing the channel ends the session either way.
		return errors.Join(notEOF(session.Signal(ssh.SIGKILL)), notEOF(session.Close()))
	}
	s.resize = resize
	c.register(s)
	return map[string]string{"stream": s.id}, func() {
		close(s.started)
		err := session.Wait()
		stdout.flush()
		stderr.flush()
		end := sessionEnding(m.ended(err))
		end.err = errors.Join(end.err, notEOF(session.Close()))
		release()
		c.exit(s, end)
	}, nil
}

// notEOF drops io.EOF: a channel the server already closed answers it, when the command already ended.
func notEOF(err error) error {
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// sessionEnding turns what Session.Wait returned into how the stream ended.
func sessionEnding(err error) ending {
	if err == nil {
		return ending{code: 0}
	}
	var exit *ssh.ExitError
	if errors.As(err, &exit) {
		if exit.Signal() == "" {
			return ending{code: exit.ExitStatus()}
		}
		return ending{code: -1, signal: exit.Signal(), err: err}
	}
	return ending{code: -1, err: err}
}
