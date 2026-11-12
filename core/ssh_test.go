//go:build darwin || linux

package core

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// connecting is what one ssh.connect did: its response and the prompts it asked.
type connecting struct {
	response message
	prompts  []map[string]any
}

// connect calls ssh.connect and answers each prompt with what reply returns.
func (h *harness) connect(params map[string]any, reply func(prompt map[string]any) map[string]any) connecting {
	h.t.Helper()
	response := h.send("ssh.connect", params)
	var c connecting
	for {
		select {
		case m := <-response:
			c.response = m
			return c
		case m := <-h.other:
			if m.Event != "ssh.prompt" {
				h.t.Fatalf("unexpected event during ssh.connect: %s", m.raw)
			}
			c.prompts = append(c.prompts, m.params)
			answer := reply(m.params)
			answer["prompt"] = m.params["prompt"]
			h.send("ssh.answer", answer)
		case <-time.After(testTimeout):
			h.t.Fatal("ssh.connect did not answer")
		}
	}
}

// machine returns the machine a successful connect named.
func (c connecting) machine(t *testing.T) string {
	t.Helper()
	if c.response.Error != nil {
		t.Fatalf("ssh.connect: %s", c.response.raw)
	}
	var r struct {
		Machine string `json:"machine"`
	}
	if err := json.Unmarshal(c.response.Result, &r); err != nil || r.Machine == "" {
		t.Fatalf("ssh.connect answered %s", c.response.raw)
	}
	return r.Machine
}

func (c connecting) kinds() []string {
	var kinds []string
	for _, prompt := range c.prompts {
		kinds = append(kinds, prompt["kind"].(string))
	}
	return kinds
}

// answering accepts host keys and answers every other prompt with the next of answers.
func answering(t *testing.T, answers ...string) func(map[string]any) map[string]any {
	return func(prompt map[string]any) map[string]any {
		if prompt["kind"] == "hostKey" {
			return map[string]any{"accept": true}
		}
		if len(answers) == 0 {
			t.Errorf("unexpected prompt %v", prompt)
			return map[string]any{"cancel": true}
		}
		answer := answers[0]
		answers = answers[1:]
		if answer == "<cancel>" {
			return map[string]any{"cancel": true}
		}
		return map[string]any{"answers": []string{answer}}
	}
}

func hop(s *testServer, auth map[string]any) map[string]any {
	return map[string]any{"host": "127.0.0.1", "port": s.port, "user": "tester", "auth": auth}
}

func TestSSHAuth(t *testing.T) {
	userKey, _ := newKey(t)
	encryptedKey, _ := newKey(t)
	agentKey, _ := newKey(t)
	strangerKey, _ := newKey(t)
	server := startServer(t, serverOptions{password: "pw", home: t.TempDir(),
		keys: []ssh.PublicKey{publicOf(t, userKey), publicOf(t, encryptedKey), publicOf(t, agentKey)}})
	agentPath := startAgent(t, agentKey)
	plain := privatePEM(t, userKey, "user@test", "")
	encrypted := privatePEM(t, encryptedKey, "", "secret")
	encryptedStranger := privatePEM(t, strangerKey, "", "secret")

	h := newHarness(t)
	for _, tc := range []struct {
		name    string
		auth    map[string]any
		answers []string
		kinds   []string
	}{
		{"password", map[string]any{"password": "pw"}, nil, []string{"hostKey"}},
		{"key", map[string]any{"privateKeys": []any{map[string]any{"key": plain}}}, nil, []string{"hostKey"}},
		{"encrypted key with its passphrase",
			map[string]any{"privateKeys": []any{map[string]any{"key": encrypted, "passphrase": "secret"}}}, nil,
			[]string{"hostKey"}},
		{"agent", map[string]any{"agent": agentPath}, nil, []string{"hostKey"}},
		{"asked password, wrong first", map[string]any{"keyboardInteractive": true}, []string{"nope", "pw"},
			[]string{"hostKey", "password", "password"}},
		{"asked passphrase, wrong first", map[string]any{"privateKeys": []any{map[string]any{"key": encrypted}}},
			[]string{"nope", "secret"}, []string{"hostKey", "passphrase", "passphrase"}},
		{"a refused encrypted key is never unlocked",
			map[string]any{"privateKeys": []any{map[string]any{"key": encryptedStranger}}, "password": "pw"}, nil,
			[]string{"hostKey"}},
	} {
		c := h.connect(map[string]any{"host": "127.0.0.1", "port": server.port, "user": "tester", "auth": tc.auth},
			answering(t, tc.answers...))
		machine := c.machine(t)
		if !slices.Equal(c.kinds(), tc.kinds) {
			t.Errorf("%s: prompts %v, want %v", tc.name, c.kinds(), tc.kinds)
		}
		if out := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo in"})); out.stdout.String() != "in\n" {
			t.Errorf("%s: exec printed %q (%s)", tc.name, out.stdout.String(), out.exit.raw)
		}
		h.ok("ssh.close", map[string]string{"machine": machine})
		switch tc.name {
		case "asked passphrase, wrong first":
			first, second := c.prompts[1], c.prompts[2]
			if first["key"] != 0.0 || first["wrong"] != false || second["wrong"] != true ||
				first["publicKey"] != blob(publicOf(t, encryptedKey)) {
				t.Errorf("passphrase prompts %v, %v", first, second)
			}
		case "asked password, wrong first":
			prompt := c.prompts[1]
			if prompt["text"] != fmt.Sprintf("tester@127.0.0.1:%d's password:", server.port) || prompt["hop"] != 0.0 {
				t.Errorf("password prompt %v", prompt)
			}
		}
	}

	// The default agent is $SSH_AUTH_SOCK's.
	t.Setenv("SSH_AUTH_SOCK", agentPath)
	c := h.connect(hop(server, map[string]any{"agent": "default"}), answering(t))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})

	// OpenSSH's order: none, publickey, then password.
	server.mu.Lock()
	server.methods = nil
	server.mu.Unlock()
	c = h.connect(hop(server, map[string]any{"privateKeys": []any{map[string]any{"key": privatePEM(t, strangerKey, "", "")}},
		"password": "pw"}), answering(t))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})
	methods := server.triedMethods()
	if len(methods) < 3 || methods[0] != "none" || slices.Index(methods, "publickey") > slices.Index(methods, "password") {
		t.Errorf("methods tried in the order %v", methods)
	}
}

func TestSSHLegacyEncryptedKey(t *testing.T) {
	// An encrypted PEM key does not show its public half: it is unlocked before it is offered.
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	//nolint:staticcheck // the legacy format is what is under test
	block, err := x509.EncryptPEMBlock(rand.Reader, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(rsaKey), []byte("secret"),
		x509.PEMCipherAES256)
	if err != nil {
		t.Fatal(err)
	}
	public, err := ssh.NewPublicKey(&rsaKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	server := startServer(t, serverOptions{keys: []ssh.PublicKey{public}})
	h := newHarness(t)
	c := h.connect(hop(server, map[string]any{"privateKeys": []any{map[string]any{"key": string(pem.EncodeToMemory(block))}}}),
		answering(t, "secret"))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})
	if !slices.Equal(c.kinds(), []string{"hostKey", "passphrase"}) || c.prompts[1]["publicKey"] != nil {
		t.Fatalf("prompts %v", c.prompts)
	}
}

func TestSSHKeyboardInteractive(t *testing.T) {
	server := startServer(t, serverOptions{questions: []question{{"Code: ", true, "123"}, {"Secret: ", false, "s3"}}})
	h := newHarness(t)
	c := h.connect(hop(server, map[string]any{"keyboardInteractive": true}), func(prompt map[string]any) map[string]any {
		if prompt["kind"] == "hostKey" {
			return map[string]any{"accept": true}
		}
		return map[string]any{"answers": []string{"123", "s3"}}
	})
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})
	prompt := c.prompts[1]
	questions, _ := json.Marshal(prompt["questions"])
	if prompt["kind"] != "keyboardInteractive" || prompt["name"] != "login" || prompt["instruction"] != "answer these" ||
		string(questions) != `[{"echo":true,"text":"Code: "},{"echo":false,"text":"Secret: "}]` {
		t.Fatalf("keyboard-interactive prompt %v", prompt)
	}

	// A server that asks for the password through keyboard-interactive gets the password given, without a prompt.
	server = startServer(t, serverOptions{questions: []question{{"Password: ", false, "pw"}}})
	c = h.connect(hop(server, map[string]any{"password": "pw"}), answering(t))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})

	// A server that needs no authentication.
	server = startServer(t, serverOptions{none: true})
	c = h.connect(hop(server, map[string]any{"none": true}), answering(t))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})
}

func TestSSHAuthFailures(t *testing.T) {
	userKey, _ := newKey(t)
	strangerKey, _ := newKey(t)
	encryptedKey, _ := newKey(t)
	server := startServer(t, serverOptions{password: "pw",
		keys: []ssh.PublicKey{publicOf(t, userKey), publicOf(t, encryptedKey)}})
	h := newHarness(t)
	fail := func(auth map[string]any, code string, answers ...string) message {
		t.Helper()
		c := h.connect(hop(server, auth), answering(t, answers...))
		m := c.response
		if m.Error == nil || m.Error.Code != code || m.Error.Hop == nil || *m.Error.Hop != 0 ||
			!strings.HasPrefix(m.Error.Message, fmt.Sprintf("tester@127.0.0.1:%d: ", server.port)) {
			t.Fatalf("ssh.connect with %v answered %s, want code %s", auth, m.raw, code)
		}
		return m
	}

	if m := fail(map[string]any{"password": "bad"}, "auth"); !strings.Contains(m.Error.Message, "authentication failed") {
		t.Errorf("wrong password: %s", m.Error.Message)
	}
	m := fail(map[string]any{"privateKeys": []any{map[string]any{"key": privatePEM(t, strangerKey, "me@there", "")}}}, "auth")
	if len(m.Error.Offered) != 1 || m.Error.Offered[0]["fingerprint"] != ssh.FingerprintSHA256(publicOf(t, strangerKey)) ||
		m.Error.Offered[0]["key"] != 0.0 || m.Error.Offered[0]["agent"] != false || m.Error.Offered[0]["comment"] != "me@there" ||
		m.Error.Offered[0]["publicKey"] != blob(publicOf(t, strangerKey)) {
		t.Errorf("refused key: offered %v", m.Error.Offered)
	}
	fail(map[string]any{"keyboardInteractive": true}, "auth", "<cancel>")
	fail(map[string]any{"privateKeys": []any{map[string]any{"key": privatePEM(t, encryptedKey, "", "secret")}}},
		"passphrase", "<cancel>")
	fail(map[string]any{"privateKeys": []any{map[string]any{"key": "not a key"}}}, "key")
	if m := fail(map[string]any{"agent": "/no/such/agent.sock"}, "key"); !strings.Contains(m.Error.Message, "no key to offer: ssh-agent at /no/such/agent.sock") ||
		!strings.HasPrefix(m.Error.AgentProblem, "ssh-agent at /no/such/agent.sock: ") {
		t.Errorf("no agent: %s", m.Error.Message)
	}

	// identitiesOnly offers only the agent keys that match an entry, which may hold only the public half.
	agentPath := startAgent(t, strangerKey, userKey)
	strangerLine := string(ssh.MarshalAuthorizedKey(publicOf(t, strangerKey)))
	m = fail(map[string]any{"agent": agentPath, "identitiesOnly": true,
		"privateKeys": []any{map[string]any{"publicKey": strangerLine}}}, "auth")
	if len(m.Error.Offered) != 1 || m.Error.Offered[0]["agent"] != true || m.Error.Offered[0]["key"] != 0.0 {
		t.Errorf("identitiesOnly: offered %v", m.Error.Offered)
	}
	c := h.connect(hop(server, map[string]any{"agent": agentPath, "privateKeys": []any{map[string]any{"publicKey": strangerLine}}}),
		answering(t))
	h.ok("ssh.close", map[string]string{"machine": c.machine(t)})
}

func TestSSHHostKey(t *testing.T) {
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	params := hop(server, map[string]any{"password": "pw"})
	params["tag"] = "tag-1"
	c := h.connect(params, answering(t))
	machine := c.machine(t)
	prompt := c.prompts[0]
	if prompt["kind"] != "hostKey" || prompt["host"] != "127.0.0.1" || prompt["port"] != float64(server.port) ||
		prompt["keyType"] != "ssh-ed25519" || prompt["key"] != blob(server.hostKey) ||
		prompt["fingerprint"] != server.fingerprint() || prompt["tag"] != "tag-1" || prompt["hop"] != 0.0 {
		t.Fatalf("host key prompt %v", prompt)
	}
	var result struct {
		HostKeys []string `json:"hostKeys"`
	}
	if err := json.Unmarshal(c.response.Result, &result); err != nil || !slices.Equal(result.HostKeys, []string{server.fingerprint()}) {
		t.Fatalf("hostKeys %s", c.response.raw)
	}
	h.ok("ssh.close", map[string]string{"machine": machine})

	for _, reply := range []map[string]any{{"accept": false}, {"cancel": true}} {
		c = h.connect(hop(server, map[string]any{"password": "pw"}), func(map[string]any) map[string]any { return reply })
		if m := c.response; m.Error == nil || m.Error.Code != "hostKey" || len(c.prompts) != 1 {
			t.Fatalf("host key answered %v: %s", reply, m.raw)
		}
	}
}

// TestSSHPromptEnds checks that a prompt no page will answer fails its connect: the page went away (the shell or
// the dev bridge replaced the listener), or the prompt's deadline passed.
func TestSSHPromptEnds(t *testing.T) {
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	unanswered := func() (response <-chan message, prompt string) {
		t.Helper()
		response = h.send("ssh.connect", hop(server, map[string]any{"password": "pw"}))
		m := h.event()
		if m.Event != "ssh.prompt" || m.params["kind"] != "hostKey" {
			t.Fatalf("got %s", m.raw)
		}
		return response, m.params["prompt"].(string)
	}

	response, prompt := unanswered()
	h.core.SetEmit(h.receive) // a reloaded page takes over the core
	if m := h.call("ssh.answer", map[string]any{"prompt": prompt, "accept": true}); m.Error == nil {
		t.Fatalf("answering a failed prompt: %s", m.raw)
	}
	// The connect failed; its response, under an id of the page that went away, is not sent to the next one.
	select {
	case m := <-response:
		t.Fatalf("the next page got the response %s", m.raw)
	case <-time.After(300 * time.Millisecond):
	}

	deadline := promptDeadline
	promptDeadline = 200 * time.Millisecond
	t.Cleanup(func() { promptDeadline = deadline })
	response, _ = unanswered()
	if m := h.wait(response, "ssh.connect"); m.Error == nil || m.Error.Code != "timeout" ||
		!strings.Contains(m.Error.Message, "the hostKey prompt had no answer within 200ms") {
		t.Fatalf("connect after the prompt's deadline: %s", m.raw)
	}
}

// TestPageReload checks that the core releases what a page opened once another takes over: the PTY's process is
// gone, the forward's port is closed, the machine, stream and forward ids are unknown, and the next page gets no
// event for any of them.
func TestPageReload(t *testing.T) {
	server := startServer(t, serverOptions{password: "pw", home: t.TempDir()})
	h := newHarness(t)
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)
	pty := h.open("pty.open", map[string]any{"command": `echo "pid=$$"; exec sleep 300`, "cols": 80, "rows": 24})
	match := regexp.MustCompile(`pid=(\d+)`).FindStringSubmatch(h.until(pty, "\n"))
	if match == nil {
		t.Fatal("the PTY printed no pid")
	}
	pid, err := strconv.Atoi(match[1])
	if err != nil {
		t.Fatal(err)
	}
	remote := h.open("ssh.exec", map[string]any{"machine": machine, "command": "sleep 300"})
	h.ok("stream.pause", map[string]string{"stream": remote})
	echo := echoServer(t)
	connection := h.open("net.connect", map[string]any{"machine": "local", "host": "127.0.0.1", "port": echo})
	forward := okInto[struct {
		Forward   string `json:"forward"`
		LocalPort int    `json:"localPort"`
	}](h, "net.forward", map[string]any{"machine": machine, "host": "127.0.0.1", "port": echo})

	var mu sync.Mutex
	var events []string
	h.core.SetEmit(func(text string) {
		if strings.HasPrefix(text, `{"event"`) {
			mu.Lock()
			events = append(events, text)
			mu.Unlock()
		}
		h.receive(text)
	})

	for deadline := time.Now().Add(5 * time.Second); syscall.Kill(pid, 0) == nil; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("the PTY's process %d outlived its page", pid)
		}
	}
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", forward.LocalPort)); err == nil {
		conn.Close()
		t.Fatal("the forward's port is open after its page went away")
	}
	h.fails("ssh.exec", map[string]string{"machine": machine, "command": "true"}, "closed")
	if m := h.call("net.forwardClose", map[string]string{"forward": forward.Forward}); m.Error == nil {
		t.Fatalf("net.forwardClose of the old page's forward answered %s", m.raw)
	}
	for _, stream := range []string{pty, remote, connection} {
		for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(20 * time.Millisecond) {
			m := h.call("stream.kill", map[string]string{"stream": stream})
			if m.Error != nil && strings.Contains(m.Error.Message, "unknown stream") {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s outlived its page: %s", stream, m.raw)
			}
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(events) > 0 {
		t.Fatalf("the next page got events of the old one: %q", events)
	}
}

func TestSSHJumpChain(t *testing.T) {
	targetKey, _ := newKey(t)
	bastion := startServer(t, serverOptions{password: "pw"})
	target := startServer(t, serverOptions{keys: []ssh.PublicKey{publicOf(t, targetKey)}})
	h := newHarness(t)
	params := hop(target, map[string]any{"privateKeys": []any{map[string]any{"key": privatePEM(t, targetKey, "", "")}}})
	params["jump"] = []any{hop(bastion, map[string]any{"password": "pw"})}
	c := h.connect(params, answering(t))
	machine := c.machine(t)
	if len(c.prompts) != 2 || c.prompts[0]["hop"] != 0.0 || c.prompts[0]["fingerprint"] != bastion.fingerprint() ||
		c.prompts[1]["hop"] != 1.0 || c.prompts[1]["fingerprint"] != target.fingerprint() {
		t.Fatalf("prompts %v", c.prompts)
	}
	var result struct {
		HostKeys []string `json:"hostKeys"`
	}
	if err := json.Unmarshal(c.response.Result, &result); err != nil ||
		!slices.Equal(result.HostKeys, []string{bastion.fingerprint(), target.fingerprint()}) {
		t.Fatalf("hostKeys %s", c.response.raw)
	}
	bastion.mu.Lock()
	dials := bastion.dials
	bastion.mu.Unlock()
	if !slices.Contains(dials, fmt.Sprintf("127.0.0.1:%d", target.port)) {
		t.Fatalf("the bastion dialed %v", dials)
	}
	if o := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo via-jump"})); o.stdout.String() != "via-jump\n" {
		t.Fatalf("exec through the jump printed %q", o.stdout.String())
	}
	h.ok("ssh.close", map[string]string{"machine": machine})

	// A rejected target key names the target's hop.
	c = h.connect(params, func(prompt map[string]any) map[string]any {
		return map[string]any{"accept": prompt["hop"] == 0.0}
	})
	if m := c.response; m.Error == nil || m.Error.Code != "hostKey" || *m.Error.Hop != 1 {
		t.Fatalf("rejected target key: %s", m.raw)
	}

	// A target the bastion cannot reach.
	unreachable := hop(target, map[string]any{"password": "x"})
	unreachable["port"] = 1
	unreachable["jump"] = params["jump"]
	c = h.connect(unreachable, answering(t))
	if m := c.response; m.Error == nil || m.Error.Code != "unreachable" || *m.Error.Hop != 1 {
		t.Fatalf("unreachable target: %s", m.raw)
	}

	// proxyCommand carries the first hop: the hop's own address is not dialed.
	if _, err := exec.LookPath("nc"); err != nil {
		t.Skip("no nc for the proxyCommand test")
	}
	proxied := hop(bastion, map[string]any{"password": "pw"})
	proxied["host"] = "unreachable.invalid"
	proxied["proxyCommand"] = fmt.Sprintf("nc 127.0.0.1 %d", bastion.port)
	c = h.connect(proxied, answering(t))
	machine = c.machine(t)
	if o := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo via-proxy"})); o.stdout.String() != "via-proxy\n" {
		t.Fatalf("exec through the proxy printed %q", o.stdout.String())
	}
	h.ok("ssh.close", map[string]string{"machine": machine})
}

func TestExpandProxyCommand(t *testing.T) {
	got := expandProxyCommand("ssh -W %h:%p %r@bastion 100%%", sshHop{Host: "box", User: "me"})
	if got != "ssh -W box:22 me@bastion 100%" {
		t.Fatalf("expanded to %q", got)
	}
}

func TestSSHClosed(t *testing.T) {
	unit := keepaliveUnit
	keepaliveUnit = 20 * time.Millisecond
	t.Cleanup(func() { keepaliveUnit = unit })
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	params := hop(server, map[string]any{"password": "pw"})
	params["keepAliveSec"] = 1

	// Answered keepalives keep the machine.
	machine := h.connect(params, answering(t)).machine(t)
	time.Sleep(10 * keepaliveUnit)
	if o := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo alive"})); o.stdout.String() != "alive\n" {
		t.Fatalf("after keepalives: %q", o.stdout.String())
	}

	// Three unanswered in a row close it, and its streams end.
	sleep := h.open("ssh.exec", map[string]any{"machine": machine, "command": "sleep 30"})
	server.muteKeepalives.Store(true)
	closed := h.event()
	if closed.Event != "ssh.closed" || closed.params["machine"] != machine ||
		!strings.Contains(fmt.Sprint(closed.params["error"]), "did not answer 3 keepalives") {
		t.Fatalf("got %s", closed.raw)
	}
	if o := h.drain(sleep); o.exit.Params.Code != nil || !strings.Contains(o.exit.Params.Error, "did not answer") {
		t.Fatalf("the stream ended with %s", o.exit.raw)
	}
	h.fails("ssh.exec", map[string]any{"machine": machine, "command": "true"}, "closed")
	server.muteKeepalives.Store(false)

	// The server hanging up closes it too.
	machine = h.connect(params, answering(t)).machine(t)
	server.dropAll()
	if closed := h.event(); closed.Event != "ssh.closed" || closed.params["machine"] != machine {
		t.Fatalf("got %s", closed.raw)
	}

	// ssh.close sends no ssh.closed.
	machine = h.connect(params, answering(t)).machine(t)
	h.ok("ssh.close", map[string]string{"machine": machine})
	select {
	case m := <-h.other:
		t.Fatalf("after ssh.close: %s", m.raw)
	case <-time.After(10 * keepaliveUnit):
	}
}

func TestSSHCheck(t *testing.T) {
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)
	type checked struct {
		Alive bool `json:"alive"`
	}
	params := map[string]any{"machine": machine, "quietSec": 0.5}

	if !okInto[checked](h, "ssh.check", params).Alive {
		t.Fatal("a target that answers keepalives was not alive")
	}

	// A target that answers no keepalive stays open while it sends anything else, and is closed as dead once it sent
	// nothing for quietSec.
	server.muteKeepalives.Store(true)
	ticks := h.open("ssh.exec", map[string]any{"machine": machine,
		"command": "for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.2; done"})
	start := time.Now()
	if okInto[checked](h, "ssh.check", params).Alive {
		t.Fatal("a target that answers no keepalive was alive")
	}
	if waited := time.Since(start); waited < 1400*time.Millisecond {
		t.Fatalf("closed after %v while the output still came", waited)
	}
	if o := h.drain(ticks); o.stdout.String() != "1\n2\n3\n4\n5\n6\n7\n8\n" || o.exit.Params.Code == nil ||
		*o.exit.Params.Code != 0 {
		t.Fatalf("the output was cut short: %q, %s", o.stdout.String(), o.exit.raw)
	}
	if closed := h.event(); closed.Event != "ssh.closed" || closed.params["machine"] != machine ||
		!strings.Contains(fmt.Sprint(closed.params["error"]), "sent nothing for 500ms") {
		t.Fatalf("got %s", closed.raw)
	}
	h.fails("ssh.check", params, "closed")
}

// TestSSHClosedAfterConnect checks that a machine whose server hangs up right after the handshake is closed only once
// the response that names it went out: the page listens for a machine's ssh.closed once it knows its id.
func TestSSHClosedAfterConnect(t *testing.T) {
	server := startServer(t, serverOptions{password: "pw"})
	h := newHarness(t)
	params, err := json.Marshal(hop(server, map[string]any{"password": "pw"}))
	if err != nil {
		t.Fatal(err)
	}
	type dispatched struct {
		after func()
		err   error
	}
	done := make(chan dispatched, 1)
	// The connect as Handle runs it, up to its response.
	go func() {
		_, after, err := h.core.dispatch(h.core.page.Load(), "ssh.connect", params)
		done <- dispatched{after, err}
	}()
	prompt := h.event()
	if prompt.Event != "ssh.prompt" || prompt.params["kind"] != "hostKey" {
		t.Fatalf("got %s", prompt.raw)
	}
	h.ok("ssh.answer", map[string]any{"prompt": prompt.params["prompt"], "accept": true})
	var connected dispatched
	select {
	case connected = <-done:
	case <-time.After(testTimeout):
		t.Fatal("ssh.connect did not answer")
	}
	if connected.err != nil {
		t.Fatal(connected.err)
	}
	for deadline := time.Now().Add(5 * time.Second); server.connCount() == 0; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the server holds no connection")
		}
	}
	server.dropAll()
	select {
	case m := <-h.other:
		t.Fatalf("before the response that names the machine: %s", m.raw)
	case <-time.After(300 * time.Millisecond):
	}
	if connected.after == nil {
		t.Fatal("ssh.connect starts nothing once its response went out")
	}
	connected.after()
	if m := h.event(); m.Event != "ssh.closed" {
		t.Fatalf("got %s", m.raw)
	}
}

// TestSSHAgentThatNeverAnswers checks that the handshake's deadline covers ssh-agent calls: an agent that takes the
// connection and never answers fails the connect in time, as a timeout.
func TestSSHAgentThatNeverAnswers(t *testing.T) {
	// macOS limits a socket path to 104 bytes, which t.TempDir() can exceed.
	dir, err := os.MkdirTemp("/tmp", "ompcore-agent")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := net.Listen("unix", dir+"/agent.sock")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		var held []net.Conn
		for {
			conn, err := listener.Accept()
			if err != nil {
				for _, conn := range held {
					conn.Close()
				}
				return
			}
			held = append(held, conn)
		}
	}()
	key, _ := newKey(t)
	server := startServer(t, serverOptions{keys: []ssh.PublicKey{publicOf(t, key)}})
	h := newHarness(t)
	params := hop(server, map[string]any{"agent": dir + "/agent.sock"})
	params["timeoutSec"] = 0.3
	start := time.Now()
	c := h.connect(params, answering(t))
	if m := c.response; m.Error == nil || m.Error.Code != "timeout" || time.Since(start) > 5*time.Second {
		t.Fatalf("ssh.connect with a mute agent answered %s after %v", m.raw, time.Since(start))
	}
}

func TestSSHSessions(t *testing.T) {
	idle := idleClose
	idleClose = 100 * time.Millisecond
	t.Cleanup(func() { idleClose = idle })
	server := startServer(t, serverOptions{password: "pw", maxSessions: 2, home: t.TempDir()})
	h := newHarness(t)
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)

	o := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo out; echo err >&2; exit 3"}))
	if o.stdout.String() != "out\n" || o.stderr.String() != "err\n" || exitCodeOf(t, o) != 3 {
		t.Fatalf("exec: %q %q %s", o.stdout.String(), o.stderr.String(), o.exit.raw)
	}
	out, exit := h.drainBytes(h.open("ssh.exec", map[string]any{"machine": machine, "command": `printf '\377\000'`,
		"encoding": "base64"}))
	if string(out) != "\xff\x00" || *exit.Params.Code != 0 {
		t.Fatalf("base64 exec: %q (%s)", out, exit.raw)
	}
	deflated := deflatedFile(t, "head\n", strings.Repeat("body ", 100_000))
	o = h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": fmt.Sprintf("cat %q", deflated),
		"inflate": true}))
	if o.stdout.String() != "head\n"+strings.Repeat("body ", 100_000) || exitCodeOf(t, o) != 0 {
		t.Fatalf("inflated exec: %d bytes (%s)", o.stdout.Len(), o.exit.raw)
	}
	o = h.drain(h.open("pty.open", map[string]any{"machine": machine, "command": `echo "$TERM"`, "term": "vt220",
		"cols": 80, "rows": 24}))
	if !strings.Contains(o.stdout.String(), "vt220") {
		t.Fatalf("SSH PTY printed %q", o.stdout.String())
	}

	// sshd's MaxSessions: the third session goes to a second connection.
	var cats []string
	for range 3 {
		cats = append(cats, h.open("ssh.exec", map[string]any{"machine": machine, "command": "cat"}))
	}
	if n := server.connCount(); n != 2 {
		t.Fatalf("%d connections for 3 sessions with MaxSessions 2", n)
	}
	for i, cat := range cats {
		line := fmt.Sprintf("cat %d\n", i)
		h.ok("stream.write", map[string]string{"stream": cat, "data": line})
		h.until(cat, line)
		h.ok("stream.closeStdin", map[string]string{"stream": cat})
		if o := h.drain(cat); exitCodeOf(t, o) != 0 {
			t.Fatalf("cat %d: %s", i, o.exit.raw)
		}
	}
	// The extra connection closes once idle; the machine stays.
	for deadline := time.Now().Add(5 * time.Second); server.connCount() > 1; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("%d connections after the sessions ended", server.connCount())
		}
	}
	if o := h.drain(h.open("ssh.exec", map[string]any{"machine": machine, "command": "echo still"})); o.stdout.String() != "still\n" {
		t.Fatalf("after the extra connection closed: %q", o.stdout.String())
	}
	select {
	case m := <-h.other:
		t.Fatalf("unexpected event %s", m.raw)
	default:
	}
	h.ok("ssh.close", map[string]string{"machine": machine})
}

// TestSSHStreamPause checks stream.pause on SSH channels: the window stops the remote producer. ssh.close resumes a
// paused stream, so its stream.exit comes.
func TestSSHStreamPause(t *testing.T) {
	home := t.TempDir()
	server := startServer(t, serverOptions{password: "pw", home: home})
	h := newHarness(t)
	machine := h.connect(hop(server, map[string]any{"password": "pw"}), answering(t)).machine(t)
	// More than the 2 MB channel window.
	checkPause(t, h, h.open("ssh.exec", map[string]any{"machine": machine, "command": producer(900_000)}), home,
		900_000)
	checkPause(t, h, h.open("pty.open", map[string]any{"machine": machine, "command": producer(900_000), "cols": 80,
		"rows": 24}), home, 900_000)

	paused := h.open("ssh.exec", map[string]any{"machine": machine, "command": "seq 1 900000"})
	h.until(paused, "\n") // started: a start after the test ended would fail on its removed home
	h.ok("stream.pause", map[string]string{"stream": paused})
	h.ok("ssh.close", map[string]string{"machine": machine})
	if o := h.drain(paused); o.exit.Params.Code == nil && o.exit.Params.Error == "" {
		t.Fatalf("a paused stream of a closed machine exited with %s", o.exit.raw)
	}
}
