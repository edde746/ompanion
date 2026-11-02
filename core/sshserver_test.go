//go:build darwin || linux

package core

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

// serverOptions say what a test SSH server accepts.
type serverOptions struct {
	password    string
	keys        []ssh.PublicKey
	questions   []question // keyboard-interactive, one round
	none        bool       // no authentication at all
	maxSessions int        // sshd's MaxSessions; 0 for no limit
	home        string     // the SFTP server's working directory
}

type question struct {
	text   string
	echo   bool
	answer string
}

// testServer is an SSH server in the test process: exec through /bin/sh, SFTP, direct-tcpip, keepalives.
type testServer struct {
	t       *testing.T
	port    int
	hostKey ssh.PublicKey

	muteKeepalives atomic.Bool

	mu      sync.Mutex
	conns   []*ssh.ServerConn // open connections
	methods []string          // auth methods clients tried, in order
	dials   []string          // direct-tcpip targets
}

func newKey(t *testing.T) (ed25519.PrivateKey, ssh.Signer) {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return private, signer
}

func startServer(t *testing.T, opts serverOptions) *testServer {
	t.Helper()
	_, hostKey := newKey(t)
	s := &testServer{t: t, hostKey: hostKey.PublicKey()}
	config := &ssh.ServerConfig{
		NoClientAuth: opts.none,
		AuthLogCallback: func(_ ssh.ConnMetadata, method string, _ error) {
			s.mu.Lock()
			s.methods = append(s.methods, method)
			s.mu.Unlock()
		},
	}
	if opts.password != "" {
		config.PasswordCallback = func(_ ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
			if string(password) == opts.password {
				return nil, nil
			}
			return nil, errors.New("wrong password")
		}
	}
	if len(opts.keys) > 0 {
		config.PublicKeyCallback = func(_ ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			for _, allowed := range opts.keys {
				if bytes.Equal(allowed.Marshal(), key.Marshal()) {
					return nil, nil
				}
			}
			return nil, errors.New("unknown key")
		}
	}
	if len(opts.questions) > 0 {
		config.KeyboardInteractiveCallback = func(_ ssh.ConnMetadata, challenge ssh.KeyboardInteractiveChallenge) (*ssh.Permissions, error) {
			texts := make([]string, len(opts.questions))
			echos := make([]bool, len(opts.questions))
			for i, q := range opts.questions {
				texts[i], echos[i] = q.text, q.echo
			}
			answers, err := challenge("login", "answer these", texts, echos)
			if err != nil {
				return nil, err
			}
			for i, q := range opts.questions {
				if i >= len(answers) || answers[i] != q.answer {
					return nil, errors.New("wrong answers")
				}
			}
			return nil, nil
		}
	}
	// An ECDSA host key as well, as OpenSSH servers hold: the client prefers ed25519 (hostKeyAlgorithms), so the key
	// it is shown is still s.hostKey.
	ecdsaKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ecdsaSigner, err := ssh.NewSignerFromKey(ecdsaKey)
	if err != nil {
		t.Fatal(err)
	}
	config.AddHostKey(ecdsaSigner)
	config.AddHostKey(hostKey)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.port = listener.Addr().(*net.TCPAddr).Port
	t.Cleanup(func() {
		listener.Close()
		s.dropAll()
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go s.serve(conn, config, opts)
		}
	}()
	return s
}

func (s *testServer) fingerprint() string { return ssh.FingerprintSHA256(s.hostKey) }

// dropAll hangs up on every client, the way a server that goes away does.
func (s *testServer) dropAll() {
	s.mu.Lock()
	conns := s.conns
	s.conns = nil
	s.mu.Unlock()
	for _, conn := range conns {
		conn.Close()
	}
}

func (s *testServer) connCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns)
}

func (s *testServer) triedMethods() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.methods...)
}

func (s *testServer) serve(raw net.Conn, config *ssh.ServerConfig, opts serverOptions) {
	conn, channels, requests, err := ssh.NewServerConn(raw, config)
	if err != nil {
		return // a client that failed to authenticate, which the test checks on its side
	}
	s.mu.Lock()
	s.conns = append(s.conns, conn)
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.conns = slices.DeleteFunc(s.conns, func(c *ssh.ServerConn) bool { return c == conn })
		s.mu.Unlock()
	}()
	sessions := 0 // as sshd's MaxSessions, per connection; guarded by s.mu
	go func() {
		for request := range requests {
			if request.Type == "keepalive@openssh.com" && s.muteKeepalives.Load() {
				continue // never answered
			}
			if request.WantReply {
				request.Reply(false, nil) // as OpenSSH answers keepalive@openssh.com
			}
		}
	}()
	for channel := range channels {
		switch channel.ChannelType() {
		case "session":
			s.mu.Lock()
			full := opts.maxSessions > 0 && sessions >= opts.maxSessions
			if !full {
				sessions++
			}
			s.mu.Unlock()
			if full {
				channel.Reject(ssh.Prohibited, "too many sessions")
				continue
			}
			ch, reqs, err := channel.Accept()
			if err != nil {
				continue
			}
			go func() {
				s.session(ch, reqs, opts.home)
				s.mu.Lock()
				sessions--
				s.mu.Unlock()
			}()
		case "direct-tcpip":
			var target struct {
				Host       string
				Port       uint32
				OriginHost string
				OriginPort uint32
			}
			if err := ssh.Unmarshal(channel.ExtraData(), &target); err != nil {
				channel.Reject(ssh.ConnectionFailed, err.Error())
				continue
			}
			address := net.JoinHostPort(target.Host, strconv.Itoa(int(target.Port)))
			s.mu.Lock()
			s.dials = append(s.dials, address)
			s.mu.Unlock()
			remote, err := net.Dial("tcp", address)
			if err != nil {
				channel.Reject(ssh.ConnectionFailed, err.Error())
				continue
			}
			ch, reqs, err := channel.Accept()
			if err != nil {
				remote.Close()
				continue
			}
			go ssh.DiscardRequests(reqs)
			go func() {
				done := make(chan struct{})
				go func() {
					io.Copy(remote, ch)
					remote.(*net.TCPConn).CloseWrite()
					close(done)
				}()
				io.Copy(ch, remote)
				ch.CloseWrite()
				<-done
				ch.Close()
				remote.Close()
			}()
		default:
			channel.Reject(ssh.UnknownChannelType, "unknown channel type")
		}
	}
}

// session runs one session channel: exec and shell through /bin/sh (no real PTY), the sftp subsystem, signals.
func (s *testServer) session(ch ssh.Channel, requests <-chan *ssh.Request, home string) {
	defer ch.Close()
	var cmd *exec.Cmd
	exited := make(chan struct{})
	env := os.Environ()
	run := func(command string) {
		cmd = exec.Command("/bin/sh", "-c", command)
		cmd.Env = env
		cmd.Dir = home
		cmd.Stdout, cmd.Stderr = ch, ch.Stderr()
		stdin, err := cmd.StdinPipe()
		if err != nil {
			s.t.Error(err)
			return
		}
		if err := cmd.Start(); err != nil {
			s.t.Error(err)
			return
		}
		go func() {
			io.Copy(stdin, ch)
			stdin.Close()
		}()
		go func() {
			err := cmd.Wait()
			var exit *exec.ExitError
			switch {
			case err == nil:
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
			case errors.As(err, &exit) && exit.ExitCode() >= 0:
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(exit.ExitCode())}))
			case errors.As(err, &exit):
				signal := exit.Sys().(syscall.WaitStatus).Signal()
				name := map[syscall.Signal]string{syscall.SIGKILL: "KILL", syscall.SIGTERM: "TERM"}[signal]
				ch.SendRequest("exit-signal", false, ssh.Marshal(struct {
					Signal     string
					CoreDumped bool
					Message    string
					Language   string
				}{name, false, "", ""}))
			}
			ch.Close()
			close(exited)
		}()
	}
	for request := range requests {
		switch request.Type {
		case "exec":
			var payload struct{ Command string }
			ssh.Unmarshal(request.Payload, &payload)
			request.Reply(true, nil)
			run(payload.Command)
		case "shell":
			request.Reply(true, nil)
			run("exec /bin/sh")
		case "env":
			var payload struct{ Name, Value string }
			ssh.Unmarshal(request.Payload, &payload)
			env = append(env, payload.Name+"="+payload.Value)
			request.Reply(true, nil)
		case "pty-req":
			var payload struct {
				Term string
				Rest []byte `ssh:"rest"`
			}
			ssh.Unmarshal(request.Payload, &payload)
			env = append(env, "TERM="+payload.Term)
			request.Reply(true, nil)
		case "window-change":
			request.Reply(true, nil)
		case "signal":
			if cmd != nil && cmd.Process != nil {
				cmd.Process.Kill()
			}
		case "subsystem":
			var payload struct{ Name string }
			ssh.Unmarshal(request.Payload, &payload)
			if payload.Name != "sftp" {
				request.Reply(false, nil)
				continue
			}
			request.Reply(true, nil)
			server, err := sftp.NewServer(ch, sftp.WithServerWorkingDirectory(home))
			if err != nil {
				s.t.Error(err)
				return
			}
			go func() {
				server.Serve()
				server.Close()
				close(exited)
			}()
		default:
			if request.WantReply {
				request.Reply(false, nil)
			}
		}
	}
	// The client closed the channel: end what still runs.
	if cmd != nil && cmd.Process != nil {
		cmd.Process.Kill()
		<-exited
	}
}

// startAgent serves an ssh-agent holding keys on a Unix socket and returns its path.
func startAgent(t *testing.T, keys ...ed25519.PrivateKey) string {
	t.Helper()
	keyring := agent.NewKeyring()
	for i, key := range keys {
		if err := keyring.Add(agent.AddedKey{PrivateKey: key, Comment: fmt.Sprintf("agent-key-%d", i)}); err != nil {
			t.Fatal(err)
		}
	}
	// macOS limits a socket path to 104 bytes, which t.TempDir() can exceed.
	dir, err := os.MkdirTemp("/tmp", "ompcore-agent")
	if err != nil {
		t.Fatal(err)
	}
	path := dir + "/agent.sock"
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		listener.Close()
		os.RemoveAll(dir)
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				agent.ServeAgent(keyring, conn)
				conn.Close()
			}()
		}
	}()
	return path
}

// privatePEM is key as an OpenSSH private key, encrypted when passphrase is not empty.
func privatePEM(t *testing.T, key crypto.PrivateKey, comment, passphrase string) string {
	t.Helper()
	var block *pem.Block
	var err error
	if passphrase == "" {
		block, err = ssh.MarshalPrivateKey(key, comment)
	} else {
		block, err = ssh.MarshalPrivateKeyWithPassphrase(key, comment, []byte(passphrase))
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(block))
}

func publicOf(t *testing.T, key ed25519.PrivateKey) ssh.PublicKey {
	t.Helper()
	public, err := ssh.NewPublicKey(key.Public())
	if err != nil {
		t.Fatal(err)
	}
	return public
}

func blob(public ssh.PublicKey) string { return base64.StdEncoding.EncodeToString(public.Marshal()) }
