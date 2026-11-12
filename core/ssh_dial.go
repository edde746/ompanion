package core

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

// sshDialTimeout is the default of ssh.connect's timeoutSec, as SshLink's: each hop connects, opens its channel
// through the previous hop and finishes its handshake within it, not counting the time the user spends on prompts.
// A variable so a test can shorten it.
var sshDialTimeout = 15 * time.Second

// hostKeyAlgorithms is the Flutter app's host key preference (dartssh2 4.1.0's), so a server presents the key type
// that app recorded in known_hosts: Go's default puts ECDSA first, and a server holding both (OpenSSH's default) then
// presents a key the imported known_hosts lacks. `ssh-rsa` (SHA-1), which Go's default also offers, comes last.
var hostKeyAlgorithms = []string{
	ssh.KeyAlgoED25519,
	ssh.KeyAlgoRSASHA512,
	ssh.KeyAlgoRSASHA256,
	ssh.KeyAlgoECDSA521,
	ssh.KeyAlgoECDSA384,
	ssh.KeyAlgoECDSA256,
	ssh.KeyAlgoRSA,
}

type sshAuth struct {
	Password            *string       `json:"password"`
	PrivateKeys         []sshKeyEntry `json:"privateKeys"`
	Agent               string        `json:"agent"`
	IdentitiesOnly      bool          `json:"identitiesOnly"`
	KeyboardInteractive bool          `json:"keyboardInteractive"`
	None                bool          `json:"none"`
}

// sshKeyEntry is a private key, its public half (an authorized_keys line), or both: an identity file of
// ~/.ssh/config may have only the public half, for a key the agent holds.
type sshKeyEntry struct {
	Key        string `json:"key"`
	PublicKey  string `json:"publicKey"`
	Passphrase string `json:"passphrase"`
}

type sshHop struct {
	Host string  `json:"host"`
	Port int     `json:"port"`
	User string  `json:"user"`
	Auth sshAuth `json:"auth"`
}

func (h sshHop) port() int {
	if h.Port == 0 {
		return 22
	}
	return h.Port
}

func (h sshHop) address() string { return net.JoinHostPort(h.Host, strconv.Itoa(h.port())) }

// label is how errors name the hop: user@host, with :port when it is not 22.
func (h sshHop) label() string {
	if h.port() == 22 {
		return h.User + "@" + h.Host
	}
	return h.User + "@" + h.Host + ":" + strconv.Itoa(h.port())
}

// offeredKey is a key offered to a hop, for the prompts that follow a refusal and for the auth error.
type offeredKey struct {
	KeyType     string `json:"keyType"`
	PublicKey   string `json:"publicKey"` // base64 of the wire blob
	Fingerprint string `json:"fingerprint"`
	Comment     string `json:"comment"`
	Agent       bool   `json:"agent"`
	Key         *int   `json:"key,omitempty"` // index into the hop's auth.privateKeys
}

func offer(public ssh.PublicKey, comment string, fromAgent bool, key *int) offeredKey {
	return offeredKey{
		KeyType:     public.Type(),
		PublicKey:   base64.StdEncoding.EncodeToString(public.Marshal()),
		Fingerprint: ssh.FingerprintSHA256(public),
		Comment:     comment,
		Agent:       fromAgent,
		Key:         key,
	}
}

// identity is one entry of a hop's auth.privateKeys, unlocked at most once per ssh.connect.
type identity struct {
	index   int
	pem     []byte        // nil: only the public half, for a key the agent holds
	public  ssh.PublicKey // nil: an encrypted PEM key, whose public half is unknown until it is unlocked
	comment string
	signer  ssh.Signer // nil until unlocked
	wrong   bool       // the passphrase given did not decrypt it
}

func newIdentity(index int, entry sshKeyEntry) (*identity, error) {
	id := &identity{index: index}
	if entry.PublicKey != "" {
		public, comment, _, _, err := ssh.ParseAuthorizedKey([]byte(entry.PublicKey))
		if err != nil {
			return nil, withCode("key", fmt.Errorf("auth.privateKeys[%d].publicKey: %w", index, err))
		}
		id.public, id.comment = public, comment
	}
	if entry.Key == "" {
		if id.public == nil {
			return nil, fmt.Errorf("auth.privateKeys[%d] has neither key nor publicKey", index)
		}
		return id, nil
	}
	id.pem = []byte(entry.Key)
	signer, err := ssh.ParsePrivateKey(id.pem)
	var missing *ssh.PassphraseMissingError
	switch {
	case err == nil:
		id.signer, id.public = signer, signer.PublicKey()
		if id.comment == "" {
			if id.comment, err = openSSHComment(id.pem, ""); err != nil {
				return nil, withCode("key", fmt.Errorf("auth.privateKeys[%d]: %w", index, err))
			}
		}
	case errors.As(err, &missing):
		if id.public == nil {
			id.public = missing.PublicKey
		}
		if entry.Passphrase != "" {
			if err := id.unlock(entry.Passphrase); err != nil {
				return nil, fmt.Errorf("auth.privateKeys[%d]: %w", index, err)
			}
			id.wrong = id.signer == nil
		}
	default:
		return nil, withCode("key", fmt.Errorf("auth.privateKeys[%d]: not a usable private key: %w", index, err))
	}
	return id, nil
}

// unlock decrypts the key with passphrase; a wrong passphrase leaves it locked without an error.
func (id *identity) unlock(passphrase string) error {
	signer, err := ssh.ParsePrivateKeyWithPassphrase(id.pem, []byte(passphrase))
	if err != nil {
		if errors.Is(err, x509.IncorrectPasswordError) {
			return nil
		}
		return withCode("key", fmt.Errorf("not a usable private key: %w", err))
	}
	id.signer, id.public = signer, signer.PublicKey()
	return nil
}

// dialer dials the hops of one ssh.connect, and the target again for extra connections, remembering per hop the
// accepted host key and the unlocked keys. page is the page that asked: only it is prompted.
type dialer struct {
	core         *Core
	page         uint64
	hops         []*hopState
	tag          json.RawMessage
	timeout      time.Duration
	proxyCommand string
	heard        atomic.Int64 // when a connection to the target last read anything (heardConn)
}

type hopState struct {
	index      int
	hop        sshHop
	identities []*identity

	mu      sync.Mutex // guards hostKey and the identities' signer and wrong
	hostKey string     // the accepted fingerprint, "" until the user accepted one
}

func newDialer(c *Core, page uint64, hops []sshHop, tag json.RawMessage, timeout time.Duration,
	proxyCommand string) (*dialer, error) {
	d := &dialer{core: c, page: page, tag: tag, timeout: timeout, proxyCommand: proxyCommand}
	for i, hop := range hops {
		state := &hopState{index: i, hop: hop}
		fail := func(err error) (*dialer, error) { return nil, hopError(i, hop, err) }
		if hop.Host == "" || hop.User == "" {
			return fail(errors.New("needs host and user"))
		}
		auth := hop.Auth
		if auth.Password == nil && len(auth.PrivateKeys) == 0 && auth.Agent == "" && !auth.KeyboardInteractive &&
			!auth.None {
			return fail(errors.New("needs auth: password, privateKeys, agent, keyboardInteractive or none"))
		}
		for j, entry := range auth.PrivateKeys {
			id, err := newIdentity(j, entry)
			if err != nil {
				return fail(err)
			}
			state.identities = append(state.identities, id)
		}
		d.hops = append(d.hops, state)
	}
	return d, nil
}

// hopError names the hop an ssh.connect failure happened on, keeping the code, offered keys and agent problem of err.
func hopError(index int, hop sshHop, err error) error {
	failure := &codedError{err: fmt.Errorf("%s: %w", hop.label(), err), hop: &index}
	var inner *codedError
	if errors.As(err, &inner) {
		failure.code, failure.offered, failure.agentProblem = inner.code, inner.offered, inner.agentProblem
	}
	return failure
}

func (d *dialer) hostKeys() []string {
	keys := make([]string, len(d.hops))
	for i, state := range d.hops {
		state.mu.Lock()
		keys[i] = state.hostKey
		state.mu.Unlock()
	}
	return keys
}

// dial connects hop index: through via, the previous hop, when there is one; else through the proxy command or
// directly.
func (d *dialer) dial(index int, via *ssh.Client) (*ssh.Client, error) {
	state := d.hops[index]
	address := state.hop.address()
	var conn net.Conn
	var err error
	switch {
	case via != nil:
		ctx, cancel := context.WithTimeout(context.Background(), d.timeout)
		conn, err = via.DialContext(ctx, "tcp", address)
		cancel()
		previous := d.hops[index-1].hop.label()
		if errors.Is(err, context.DeadlineExceeded) {
			return nil, withCode("timeout", fmt.Errorf("%s did not reach %s within %v", previous, address, d.timeout))
		}
		if err != nil {
			return nil, withCode("unreachable", fmt.Errorf("%s cannot reach %s: %w", previous, address, err))
		}
	case d.proxyCommand != "":
		conn, err = d.core.startProxy(expandProxyCommand(d.proxyCommand, state.hop))
		if err != nil {
			return nil, withCode("unreachable", fmt.Errorf("proxyCommand: %w", err))
		}
	default:
		conn, err = net.DialTimeout("tcp", address, d.timeout)
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return nil, withCode("timeout", fmt.Errorf("cannot connect to %s within %v", address, d.timeout))
		}
		if err != nil {
			return nil, withCode("unreachable", fmt.Errorf("cannot connect to %s: %w", address, err))
		}
	}
	if index == len(d.hops)-1 {
		conn = heardConn{Conn: conn, heard: &d.heard}
	}
	a := &attempt{dialer: d, state: state, conn: conn, phase: "key exchange"}
	config := &ssh.ClientConfig{
		User:              state.hop.User,
		Auth:              a.methods(),
		HostKeyCallback:   a.checkHostKey,
		HostKeyAlgorithms: hostKeyAlgorithms,
	}
	// The handshake then fails and reports it; an agent call that hangs in an auth callback needs its own close.
	a.deadline = newDeadline(d.timeout, func() {
		_ = conn.Close()
		a.closeAgent()
	})
	clientConn, channels, requests, err := ssh.NewClientConn(conn, address, config)
	expired := a.deadline.stop()
	a.closeAgent()
	if err != nil {
		return nil, a.classify(err, expired) // NewClientConn closed conn
	}
	return ssh.NewClient(clientConn, channels, requests), nil
}

// heardConn is a connection to the target that notes in heard when it last read anything, on monotonicNow's clock:
// any byte the target sends shows that it is still there (machine.check).
type heardConn struct {
	net.Conn
	heard *atomic.Int64
}

func (c heardConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.heard.Store(int64(monotonicNow()))
	}
	return n, err
}

// expandProxyCommand replaces ssh_config's tokens %h, %p, %r and %% with the hop's.
func expandProxyCommand(command string, hop sshHop) string {
	return strings.NewReplacer("%%", "%", "%h", hop.Host, "%p", strconv.Itoa(hop.port()), "%r", hop.User).
		Replace(command)
}

// errCannotAnswer ends keyboard-interactive when only the user could answer and auth.keyboardInteractive is off.
var errCannotAnswer = errors.New("the server asked a keyboard-interactive question that only the user can answer")

// attempt is one handshake with one hop.
type attempt struct {
	dialer   *dialer
	state    *hopState
	conn     net.Conn
	deadline *deadline

	mu           sync.Mutex
	phase        string // "key exchange", then "authentication": tells a hung key exchange from a mute server
	abort        error  // a prompt's cancel or another error that ends the attempt, whatever methods remain
	verdict      error  // the host key's rejection
	offered      []offeredKey
	agentProblem string
	agentConn    io.Closer
	agentClosed  bool // closeAgent ran: an agent connection opened later is closed at once
	typed        bool // the password went into a keyboard-interactive password prompt once
}

func (a *attempt) fail(err error) {
	a.mu.Lock()
	if a.abort == nil {
		a.abort = err
	}
	a.mu.Unlock()
	// x/crypto goes on with the next method after a failed one; a closed connection ends the handshake instead.
	_ = a.conn.Close() // the handshake reports the closed connection, and classify reports abort instead
}

func (a *attempt) classify(err error, expired bool) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	switch {
	// The deadline closed the connection and the agent's: what failed since failed for it.
	case expired:
		return withCode("timeout", fmt.Errorf("no answer during %s within %v", a.phase, a.dialer.timeout))
	case a.abort != nil:
		return a.abort
	case a.verdict != nil:
		return a.verdict
	case errors.Is(err, errCannotAnswer) || strings.Contains(err.Error(), "unable to authenticate") ||
		// SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE, e.g. "Too many authentication failures"; x/crypto's
		// disconnect error type is unexported.
		strings.Contains(err.Error(), "disconnect, reason 14:"):
		message := "authentication failed"
		if len(a.offered) > 0 {
			keys := make([]string, len(a.offered))
			for i, key := range a.offered {
				keys[i] = strings.TrimSpace(key.KeyType + " " + key.Fingerprint + " " + key.Comment)
			}
			message += "; offered " + strings.Join(keys, ", ")
		}
		if a.agentProblem != "" {
			message += "; " + a.agentProblem
		}
		return &codedError{code: "auth", err: fmt.Errorf("%s: %w", message, err), offered: a.offered,
			agentProblem: a.agentProblem}
	case errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || isNetError(err):
		return withCode("unreachable", fmt.Errorf("connection lost during %s: %w", a.phase, err))
	default:
		return fmt.Errorf("SSH handshake failed: %w", err)
	}
}

func isNetError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr)
}

// ask puts a prompt to the page and waits for its answer; the handshake's deadline stops meanwhile. A cancel ends
// the attempt with code; a page that went away or never answered ends it with "closed" or "timeout".
func (a *attempt) ask(kind, code string, fields map[string]any) (answer, error) {
	resume := a.deadline.pause()
	defer resume()
	fields["tag"] = a.dialer.tag
	fields["hop"] = a.state.index
	fields["kind"] = kind
	reply, err := a.dialer.core.prompt(a.dialer.page, fields)
	if err == nil && reply.Cancel {
		err = withCode(code, fmt.Errorf("the %s prompt was cancelled", kind))
	}
	if err != nil {
		a.fail(err)
		return answer{}, err
	}
	return reply, nil
}

// askText asks a prompt that needs exactly count answers.
func (a *attempt) askText(kind, code string, count int, fields map[string]any) ([]string, error) {
	reply, err := a.ask(kind, code, fields)
	if err != nil {
		return nil, err
	}
	if len(reply.Answers) != count {
		err := fmt.Errorf("the %s prompt needs %d answers, not %d", kind, count, len(reply.Answers))
		a.fail(err)
		return nil, err
	}
	return reply.Answers, nil
}

func (a *attempt) checkHostKey(_ string, _ net.Addr, key ssh.PublicKey) error {
	fingerprint := ssh.FingerprintSHA256(key)
	a.state.mu.Lock()
	accepted := a.state.hostKey
	a.state.mu.Unlock()
	if accepted == "" {
		hop := a.state.hop
		reply, err := a.ask("hostKey", "hostKey", map[string]any{
			"host":        hop.Host,
			"port":        hop.port(),
			"keyType":     key.Type(),
			"key":         base64.StdEncoding.EncodeToString(key.Marshal()),
			"fingerprint": fingerprint,
		})
		if err != nil {
			return err
		}
		if !reply.Accept {
			return a.reject(fmt.Errorf("host key %s is not trusted", fingerprint))
		}
		a.state.mu.Lock()
		a.state.hostKey = fingerprint
		a.state.mu.Unlock()
	} else if accepted != fingerprint {
		// Extra connections to a hop must present the key accepted for the first one.
		return a.reject(fmt.Errorf("host key changed from %s to %s", accepted, fingerprint))
	}
	a.mu.Lock()
	a.phase = "authentication"
	a.mu.Unlock()
	return nil
}

func (a *attempt) reject(err error) error {
	err = withCode("hostKey", err)
	a.mu.Lock()
	a.verdict = err
	a.mu.Unlock()
	return err
}

// methods are the hop's auth methods in OpenSSH's order; x/crypto tries none before them.
func (a *attempt) methods() []ssh.AuthMethod {
	auth := a.state.hop.Auth
	var methods []ssh.AuthMethod
	// One publickey method: x/crypto tries each method name once.
	if len(auth.PrivateKeys) > 0 || auth.Agent != "" {
		methods = append(methods, ssh.PublicKeysCallback(a.signers))
	}
	if auth.KeyboardInteractive || auth.Password != nil {
		methods = append(methods, ssh.KeyboardInteractive(a.keyboardInteractive))
	}
	switch {
	case auth.Password != nil:
		methods = append(methods, ssh.Password(*auth.Password))
	case auth.KeyboardInteractive:
		// As ssh's NumberOfPasswordPrompts.
		methods = append(methods, ssh.RetryableAuthMethod(ssh.PasswordCallback(a.askPassword), 3))
	}
	return methods
}

// offerFields are what the prompts after a refusal and the auth error say about the keys offered.
func (a *attempt) offerFields(fields map[string]any) map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	fields["offered"] = a.offered
	if a.offered == nil {
		fields["offered"] = []offeredKey{}
	}
	if a.agentProblem != "" {
		fields["agentProblem"] = a.agentProblem
	}
	return fields
}

// signers offers keys like ssh's pubkey_prepare: the agent's in agent order (one that is also an entry counts as that
// entry; others only without identitiesOnly), then the remaining entries. An encrypted key whose public half is known
// asks for its passphrase only once the server accepted it; one whose public half is unknown asks before it is
// offered.
func (a *attempt) signers() ([]ssh.Signer, error) {
	auth := a.state.hop.Auth
	remaining := append([]*identity(nil), a.state.identities...)
	var signers []ssh.Signer
	var offered []offeredKey
	if auth.Agent != "" {
		keys, agentSigners, problem := a.agentKeys(auth.Agent)
		a.mu.Lock()
		a.agentProblem = problem
		a.mu.Unlock()
		for i, key := range keys {
			match := -1
			for j, id := range remaining {
				if id.public != nil && bytes.Equal(id.public.Marshal(), key.Marshal()) {
					match = j
					break
				}
			}
			if match < 0 && auth.IdentitiesOnly {
				continue
			}
			var index *int
			if match >= 0 {
				index = &remaining[match].index
				remaining = append(remaining[:match], remaining[match+1:]...)
			}
			signers = append(signers, agentSigners[i])
			offered = append(offered, offer(key, key.Comment, true, index))
		}
	}
	for _, id := range remaining {
		a.state.mu.Lock()
		signer, public := id.signer, id.public
		a.state.mu.Unlock()
		switch {
		case id.pem == nil:
			continue // only the public half, and the agent does not hold it
		case signer != nil:
			signers = append(signers, signer)
		case public != nil:
			signers = append(signers, &lockedSigner{attempt: a, id: id})
		default:
			unlocked, err := a.unlock(id)
			if err != nil {
				return nil, err
			}
			signer, public = unlocked, unlocked.PublicKey()
			signers = append(signers, signer)
		}
		offered = append(offered, offer(public, id.comment, false, &id.index))
	}
	a.mu.Lock()
	a.offered = offered
	problem := a.agentProblem
	a.mu.Unlock()
	if len(signers) == 0 && auth.Password == nil && !auth.KeyboardInteractive && !auth.None {
		message := "no key to offer"
		if problem != "" {
			message += ": " + problem
		}
		err := &codedError{code: "key", err: errors.New(message), offered: offered, agentProblem: problem}
		a.fail(err)
		return nil, err
	}
	return signers, nil
}

// agentKeys lists the agent's keys and signers; problem says why there are none.
func (a *attempt) agentKeys(path string) (keys []*agent.Key, signers []ssh.Signer, problem string) {
	if path == "default" {
		path = os.Getenv("SSH_AUTH_SOCK")
		if path == "" && runtime.GOOS == "windows" {
			path = `\\.\pipe\openssh-ssh-agent`
		}
		if path == "" {
			return nil, nil, "ssh-agent: SSH_AUTH_SOCK is not set"
		}
	}
	conn, err := dialAgent(path)
	if err != nil {
		return nil, nil, fmt.Sprintf("ssh-agent at %s: %v", path, err)
	}
	a.mu.Lock()
	closed := a.agentClosed
	if !closed {
		a.agentConn = conn
	}
	a.mu.Unlock()
	if closed {
		_ = conn.Close() // never used: the handshake is over
		return nil, nil, fmt.Sprintf("ssh-agent at %s: the handshake ended", path)
	}
	client := agent.NewClient(conn)
	if keys, err = client.List(); err != nil {
		return nil, nil, fmt.Sprintf("ssh-agent at %s: %v", path, err)
	}
	if signers, err = client.Signers(); err != nil {
		return nil, nil, fmt.Sprintf("ssh-agent at %s: %v", path, err)
	}
	if len(keys) == 0 {
		return nil, nil, fmt.Sprintf("ssh-agent at %s holds no keys", path)
	}
	return keys, signers, ""
}

// dialAgent connects to an ssh-agent: a Unix socket, or a named pipe on Windows.
func dialAgent(path string) (io.ReadWriteCloser, error) {
	if runtime.GOOS == "windows" && strings.HasPrefix(path, `\\.\pipe\`) {
		return os.OpenFile(path, os.O_RDWR, 0)
	}
	return net.Dial("unix", path)
}

func (a *attempt) closeAgent() {
	a.mu.Lock()
	conn := a.agentConn
	a.agentConn = nil
	a.agentClosed = true
	a.mu.Unlock()
	if conn != nil {
		if err := conn.Close(); err != nil {
			a.dialer.core.writeLog(fmt.Sprintf("ssh: closing the ssh-agent connection: %v", err))
		}
	}
}

// unlock asks for id's passphrase until it decrypts the key.
func (a *attempt) unlock(id *identity) (ssh.Signer, error) {
	a.state.mu.Lock()
	signer, wrong := id.signer, id.wrong
	a.state.mu.Unlock()
	for signer == nil {
		fields := map[string]any{"text": "Enter the passphrase for private key " + strconv.Itoa(id.index+1), "key": id.index,
			"wrong": wrong}
		if id.public != nil {
			fields["publicKey"] = base64.StdEncoding.EncodeToString(id.public.Marshal())
			fields["text"] = "Enter the passphrase for key " + ssh.FingerprintSHA256(id.public)
		}
		answers, err := a.askText("passphrase", "passphrase", 1, fields)
		if err != nil {
			return nil, err
		}
		a.state.mu.Lock()
		err = id.unlock(answers[0])
		signer = id.signer
		id.wrong = signer == nil
		wrong = id.wrong
		a.state.mu.Unlock()
		if err != nil {
			a.fail(err)
			return nil, err
		}
	}
	return signer, nil
}

// lockedSigner is an encrypted key whose public half is known: the server sees it offered, and only a key it accepts
// is unlocked to sign.
type lockedSigner struct {
	attempt *attempt
	id      *identity
}

func (l *lockedSigner) PublicKey() ssh.PublicKey { return l.id.public }

func (l *lockedSigner) Sign(rand io.Reader, data []byte) (*ssh.Signature, error) {
	signer, err := l.attempt.unlock(l.id)
	if err != nil {
		return nil, err
	}
	return signer.Sign(rand, data)
}

func (l *lockedSigner) SignWithAlgorithm(rand io.Reader, data []byte, algorithm string) (*ssh.Signature, error) {
	signer, err := l.attempt.unlock(l.id)
	if err != nil {
		return nil, err
	}
	algorithmSigner, ok := signer.(ssh.AlgorithmSigner)
	if !ok {
		return nil, fmt.Errorf("the key cannot sign with %s", algorithm)
	}
	return algorithmSigner.SignWithAlgorithm(rand, data, algorithm)
}

func (a *attempt) keyboardInteractive(name, instruction string, questions []string, echos []bool) ([]string, error) {
	// OpenSSH ends a PAM conversation with an empty round; only one with text reaches the user.
	if len(questions) == 0 && name == "" && instruction == "" {
		return []string{}, nil
	}
	auth := a.state.hop.Auth
	// Servers with PasswordAuthentication off often take the password through a PAM keyboard-interactive prompt
	// instead: type it into one password prompt, once.
	a.mu.Lock()
	typeIt := auth.Password != nil && !a.typed && len(questions) == 1 && !echos[0] &&
		strings.Contains(strings.ToLower(questions[0]), "password")
	if typeIt {
		a.typed = true
	}
	a.mu.Unlock()
	if typeIt {
		return []string{*auth.Password}, nil
	}
	if !auth.KeyboardInteractive {
		return nil, errCannotAnswer
	}
	asked := make([]map[string]any, len(questions))
	for i, question := range questions {
		asked[i] = map[string]any{"text": question, "echo": echos[i]}
	}
	return a.askText("keyboardInteractive", "auth", len(questions), a.offerFields(map[string]any{
		"name":        name,
		"instruction": instruction,
		"questions":   asked,
	}))
}

func (a *attempt) askPassword() (string, error) {
	answers, err := a.askText("password", "auth", 1, a.offerFields(map[string]any{
		"text": a.state.hop.label() + "'s password:",
	}))
	if err != nil {
		return "", err
	}
	return answers[0], nil
}

// answer is the page's ssh.answer to an ssh.prompt.
type answer struct {
	Accept  bool     `json:"accept"`
	Answers []string `json:"answers"`
	Cancel  bool     `json:"cancel"`
}

// promptReply is the page's ssh.answer, or why none will come.
type promptReply struct {
	answer answer
	err    error
}

// promptDeadline bounds how long a prompt waits for its answer; a variable so a test can shorten it.
var promptDeadline = 10 * time.Minute

// prompt emits an ssh.prompt to page and waits for its ssh.answer, at most promptDeadline. A page that went away fails
// it at once.
func (c *Core) prompt(page uint64, fields map[string]any) (answer, error) {
	deadline := promptDeadline
	id := c.newID("p")
	reply := make(chan promptReply, 1)
	c.mu.Lock()
	c.prompts[id] = reply
	c.mu.Unlock()
	fields["prompt"] = id
	// Sent, the prompt is in prompts before SetEmit swaps the listener, and so failed by its failPrompts.
	if !c.sendTo(page, map[string]any{"event": "ssh.prompt", "params": fields}) {
		c.mu.Lock()
		delete(c.prompts, id)
		c.mu.Unlock()
		return answer{}, withCode("closed", errors.New("the page went away"))
	}
	timer := time.NewTimer(deadline)
	defer timer.Stop()
	select {
	case r := <-reply:
		return r.answer, r.err
	case <-timer.C:
	}
	c.mu.Lock()
	_, pending := c.prompts[id]
	delete(c.prompts, id)
	c.mu.Unlock()
	if !pending {
		r := <-reply // it was answered as time ran out
		return r.answer, r.err
	}
	return answer{}, withCode("timeout", fmt.Errorf("the %s prompt had no answer within %v", fields["kind"], deadline))
}

// failPrompts ends every prompt waiting for an answer: the page that was asked went away.
func (c *Core) failPrompts() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, reply := range c.prompts {
		reply <- promptReply{err: withCode("closed", errors.New("the page went away"))}
		delete(c.prompts, id)
	}
}

func (c *Core) sshAnswer(params json.RawMessage) (any, error) {
	p, err := decode[struct {
		answer
		Prompt string `json:"prompt"`
	}](params)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	reply, ok := c.prompts[p.Prompt]
	delete(c.prompts, p.Prompt)
	c.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("unknown prompt %q", p.Prompt)
	}
	reply <- promptReply{answer: p.answer}
	return struct{}{}, nil
}

// deadline is a timeout that stops while the user answers a prompt and restarts in full afterwards.
type deadline struct {
	mu       sync.Mutex
	duration time.Duration
	timer    *time.Timer
	paused   int
	stopped  bool
	expired  bool
	onExpire func()
}

func newDeadline(duration time.Duration, onExpire func()) *deadline {
	d := &deadline{duration: duration, onExpire: onExpire}
	d.timer = time.AfterFunc(duration, d.fire)
	return d
}

func (d *deadline) fire() {
	d.mu.Lock()
	if d.stopped || d.paused > 0 {
		d.mu.Unlock()
		return
	}
	d.expired = true
	d.mu.Unlock()
	d.onExpire()
}

func (d *deadline) pause() (resume func()) {
	d.mu.Lock()
	d.paused++
	d.timer.Stop()
	d.mu.Unlock()
	return func() {
		d.mu.Lock()
		d.paused--
		if d.paused == 0 && !d.stopped && !d.expired {
			d.timer.Reset(d.duration)
		}
		d.mu.Unlock()
	}
}

// stop ends the deadline and reports whether it expired.
func (d *deadline) stop() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stopped = true
	d.timer.Stop()
	return d.expired
}

// startProxy runs a proxyCommand and returns its stdin and stdout as the connection to the first hop.
func (c *Core) startProxy(command string) (net.Conn, error) {
	if !local() {
		return nil, fmt.Errorf("proxyCommand is not available on %s", runtime.GOOS)
	}
	cmd := shellCommand(command, nil, "")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = logWriter{c, "ssh: proxyCommand: "}
	// A child of the proxy that inherited stderr must not hold up closing the connection.
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &commandConn{cmd: cmd, stdin: stdin, stdout: stdout, command: command}, nil
}

// commandConn is a proxy command's stdin and stdout as a net.Conn; x/crypto uses only Read, Write and Close.
type commandConn struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	stdout  io.Reader
	command string

	closeOnce sync.Once
	closeErr  error
}

func (p *commandConn) Read(b []byte) (int, error)  { return p.stdout.Read(b) }
func (p *commandConn) Write(b []byte) (int, error) { return p.stdin.Write(b) }

// Close ends the proxy command: a proxy that would outlive its connection holds a socket for nothing.
func (p *commandConn) Close() error {
	p.closeOnce.Do(func() {
		err := p.stdin.Close()
		if killErr := p.cmd.Process.Kill(); !errors.Is(killErr, os.ErrProcessDone) {
			err = errors.Join(err, killErr)
		}
		var exit *exec.ExitError
		if waitErr := p.cmd.Wait(); !errors.As(waitErr, &exit) {
			err = errors.Join(err, waitErr)
		}
		p.closeErr = err
	})
	return p.closeErr
}

func (p *commandConn) LocalAddr() net.Addr  { return proxyAddr(p.command) }
func (p *commandConn) RemoteAddr() net.Addr { return proxyAddr(p.command) }

func (p *commandConn) SetDeadline(time.Time) error {
	return errors.New("a proxy command's pipes have no deadlines")
}
func (p *commandConn) SetReadDeadline(t time.Time) error  { return p.SetDeadline(t) }
func (p *commandConn) SetWriteDeadline(t time.Time) error { return p.SetDeadline(t) }

type proxyAddr string

func (proxyAddr) Network() string  { return "proxy" }
func (a proxyAddr) String() string { return string(a) }

// logWriter writes each write to the core's log with prefix.
type logWriter struct {
	core   *Core
	prefix string
}

func (w logWriter) Write(p []byte) (int, error) {
	w.core.writeLog(w.prefix + strings.TrimRight(string(p), "\n"))
	return len(p), nil
}
