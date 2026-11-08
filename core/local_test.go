//go:build darwin || linux

package core

import (
	"bytes"
	"compress/flate"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestLocalExec(t *testing.T) {
	h := newHarness(t)

	o := h.drain(h.open("local.exec", map[string]any{"argv": []string{"sh", "-c", "echo out; echo err >&2; exit 3"}}))
	if o.stdout.String() != "out\n" || o.stderr.String() != "err\n" || exitCodeOf(t, o) != 3 {
		t.Fatalf("stdout %q, stderr %q, exit %s", o.stdout.String(), o.stderr.String(), o.exit.raw)
	}

	dir := t.TempDir()
	o = h.drain(h.open("local.exec", map[string]any{
		"argv": []string{"sh", "-c", `pwd; echo "$OMPCORE_TEST_VAR"`},
		"cwd":  dir,
		"env":  map[string]string{"OMPCORE_TEST_VAR": "from-env"},
	}))
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if want := real + "\nfrom-env\n"; o.stdout.String() != want || exitCodeOf(t, o) != 0 {
		t.Fatalf("stdout %q, want %q (%s)", o.stdout.String(), want, o.exit.raw)
	}

	// stdin: many writes sent without waiting keep their order, and closeStdin comes after them.
	cat := h.open("local.exec", map[string]any{"argv": []string{"cat"}})
	var want strings.Builder
	var pending []<-chan message
	for i := range 300 {
		line := fmt.Sprintf("line %d ü\n", i)
		want.WriteString(line)
		pending = append(pending, h.send("stream.write", map[string]string{"stream": cat, "data": line}))
	}
	pending = append(pending, h.send("stream.closeStdin", map[string]string{"stream": cat}))
	for _, ch := range pending {
		if m := h.wait(ch, "stream.write"); m.Error != nil {
			t.Fatalf("stream.write: %s", m.Error.Message)
		}
	}
	o = h.drain(cat)
	if o.stdout.String() != want.String() || exitCodeOf(t, o) != 0 {
		t.Fatalf("cat printed %d bytes, want %d (%s)", o.stdout.Len(), want.Len(), o.exit.raw)
	}

	sleep := h.open("local.exec", map[string]any{"argv": []string{"sleep", "30"}})
	h.ok("stream.kill", map[string]string{"stream": sleep})
	o = h.drain(sleep)
	if o.exit.Params.Code != nil || o.exit.Params.Signal != "KILL" || !strings.Contains(o.exit.Params.Error, "killed") {
		t.Fatalf("killed sleep exited with %s", o.exit.raw)
	}
	if m := h.call("stream.write", map[string]string{"stream": sleep, "data": "x"}); m.Error == nil {
		t.Fatalf("stream.write to an ended stream answered %s", m.raw)
	}

	if m := h.call("local.exec", map[string]any{"argv": []string{"/no/such/program"}}); m.Error == nil {
		t.Fatalf("local.exec of a missing program answered %s", m.raw)
	}

	// Multi-byte output in pipe-sized reads: no event splits a sequence.
	o = h.drain(h.open("local.exec", map[string]any{"argv": []string{"sh", "-c", `yes '€😀' | head -n 100000`}}))
	if n := utf8.RuneCountInString(o.stdout.String()); n != 300000 || exitCodeOf(t, o) != 0 {
		t.Fatalf("got %d runes in %d chunks, want 300000 (%s)", n, len(o.chunks), o.exit.raw)
	}
	for _, chunk := range o.chunks {
		if strings.ContainsRune(chunk, utf8.RuneError) {
			t.Fatalf("a chunk split a sequence: %q", chunk[:min(len(chunk), 40)])
		}
	}

	// command runs through /bin/sh, in cwd.
	o = h.drain(h.open("local.exec", map[string]any{"command": `printf '%s' "$PWD" | wc -c; exit 4`, "cwd": real}))
	if strings.TrimSpace(o.stdout.String()) != fmt.Sprint(len(real)) || exitCodeOf(t, o) != 4 {
		t.Fatalf("command printed %q (%s)", o.stdout.String(), o.exit.raw)
	}
	if m := h.call("local.exec", map[string]any{"argv": []string{"true"}, "command": "true"}); m.Error == nil {
		t.Fatalf("local.exec with argv and command answered %s", m.raw)
	}
}

// A request that crosses a stream's end is answered `unknown stream`; the page tells that from a failure by the end
// having arrived first (whileOpen in ui/src/core/transport/bridge_link.ts), so the core knows a stream until its
// stream.exit is out.
func TestStreamKnownUntilItsExitIsOut(t *testing.T) {
	known := make(chan bool, 1)
	var c *Core
	c = New(func(text string) {
		var m message
		if json.Unmarshal([]byte(text), &m) != nil || m.Event != "stream.exit" {
			return
		}
		_, err := c.stream(m.Params.Stream)
		known <- err == nil
	})
	c.Handle(`{"id": 1, "method": "local.exec", "params": {"argv": ["true"]}}`)
	select {
	case ok := <-known:
		if !ok {
			t.Fatal("the core forgot the stream before it emitted its stream.exit")
		}
	case <-time.After(testTimeout):
		t.Fatal("no stream.exit")
	}
}

func TestBase64Streams(t *testing.T) {
	h := newHarness(t)
	// Bytes that are not UTF-8 come out whole.
	out, exit := h.drainBytes(h.open("local.exec", map[string]any{"argv": []string{"printf", `\377\000\200ok`},
		"encoding": "base64"}))
	if !bytes.Equal(out, []byte{0xff, 0, 0x80, 'o', 'k'}) || *exit.Params.Code != 0 {
		t.Fatalf("printf gave %q (%s)", out, exit.raw)
	}
	// They go in whole too.
	cat := h.open("local.exec", map[string]any{"argv": []string{"cat"}, "encoding": "base64"})
	sent := []byte{0, 1, 0xfe, 0xff, '\n'}
	h.ok("stream.write", map[string]string{"stream": cat, "data": base64.StdEncoding.EncodeToString(sent)})
	if m := h.call("stream.write", map[string]string{"stream": cat, "data": "not base64!"}); m.Error == nil {
		t.Fatalf("stream.write of bad base64 answered %s", m.raw)
	}
	h.ok("stream.closeStdin", map[string]string{"stream": cat})
	if out, exit := h.drainBytes(cat); !bytes.Equal(out, sent) || *exit.Params.Code != 0 {
		t.Fatalf("cat gave %v (%s)", out, exit.raw)
	}
}

// deflatedFile writes parts as the follow script does, raw deflate with a sync flush after each and no final block,
// and returns the file's path.
func deflatedFile(t *testing.T, parts ...string) string {
	t.Helper()
	var out bytes.Buffer
	w, err := flate.NewWriter(&out, flate.DefaultCompression)
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range parts {
		if _, err := w.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
		if err := w.Flush(); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "out.deflate")
	if err := os.WriteFile(path, out.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestInflatedStreams(t *testing.T) {
	h := newHarness(t)
	line := strings.Repeat(`{"type":"message_update","message":{"text":"hello"}}`, 50) + "\n"
	parts := []string{"7 0 - 0 0\n", line, line, strings.Repeat("x", 300_000) + "\n"}
	whole := deflatedFile(t, parts...)
	o := h.drain(h.open("local.exec", map[string]any{"argv": []string{"cat", whole}, "inflate": true}))
	if o.stdout.String() != strings.Join(parts, "") || exitCodeOf(t, o) != 0 || o.exit.Params.Error != "" {
		t.Fatalf("inflated %d bytes, want %d (%s)", o.stdout.Len(), len(strings.Join(parts, "")), o.exit.raw)
	}

	// What a flush ends with comes out while the command still runs.
	first := deflatedFile(t, "header\n")
	live := h.open("local.exec", map[string]any{"command": fmt.Sprintf("cat %q; exec sleep 30", first), "inflate": true})
	h.until(live, "header\n")
	h.ok("stream.kill", map[string]string{"stream": live})
	h.drain(live)

	// Output that does not inflate ends the stream at once, with the reason.
	start := time.Now()
	o = h.drain(h.open("local.exec", map[string]any{"command": "printf 'not deflate'; exec sleep 30", "inflate": true}))
	if !strings.Contains(o.exit.Params.Error, "inflating the output") || time.Since(start) > 10*time.Second {
		t.Fatalf("a stream that does not inflate ended after %v: %s", time.Since(start), o.exit.raw)
	}
}

func TestLocalPTY(t *testing.T) {
	h := newHarness(t)
	stream := h.open("pty.open", map[string]any{"argv": []string{"/bin/sh"}, "cols": 80, "rows": 24,
		"env": map[string]string{"PS1": "$ "}})

	// The shell computes the marker, so seeing it proves a round trip rather than the terminal's echo.
	h.ok("stream.write", map[string]string{"stream": stream, "data": "echo pty-$((6*7))\n"})
	h.until(stream, "pty-42")

	h.ok("pty.resize", map[string]any{"stream": stream, "cols": 101, "rows": 33})
	h.ok("stream.write", map[string]string{"stream": stream, "data": "stty size\n"})
	h.until(stream, "33 101")

	h.ok("stream.write", map[string]string{"stream": stream, "data": "echo $TERM; exit 7\n"})
	o := h.drain(stream)
	if !strings.Contains(o.stdout.String(), "xterm-256color") || exitCodeOf(t, o) != 7 || o.exit.Params.Error != "" {
		t.Fatalf("output %q, exit %s", o.stdout.String(), o.exit.raw)
	}

	// The default program is the user's shell; a kill ends it.
	if os.Getenv("SHELL") == "" {
		t.Setenv("SHELL", "/bin/sh")
	}
	shell := h.open("pty.open", map[string]any{"cols": 80, "rows": 24})
	h.ok("stream.kill", map[string]string{"stream": shell})
	if o := h.drain(shell); o.exit.Params.Code != nil {
		t.Fatalf("killed shell exited with %s", o.exit.raw)
	}

	// command runs through /bin/sh on the PTY, in cwd, announcing term.
	dir := t.TempDir()
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	o = h.drain(h.open("pty.open", map[string]any{"command": `echo "$TERM $COLORTERM $PWD"`, "cwd": dir, "term": "vt100",
		"cols": 80, "rows": 24}))
	if !strings.Contains(o.stdout.String(), "vt100 truecolor "+real) || exitCodeOf(t, o) != 0 {
		t.Fatalf("PTY command printed %q (%s)", o.stdout.String(), o.exit.raw)
	}
}

// A kill ends what the process started too: a killed follow script's background `tail -F` must not outlive it.
func TestKillEndsWhatItStarted(t *testing.T) {
	h := newHarness(t)
	for _, method := range []string{"local.exec", "pty.open"} {
		dir := t.TempDir()
		// The child ignores SIGHUP, which the end of a PTY's session sends its foreground group.
		params := map[string]any{"command": `trap '' HUP; sleep 300 & echo $! > child; echo started; wait`, "cwd": dir}
		if method == "pty.open" {
			params["cols"], params["rows"] = 80, 24
		}
		stream := h.open(method, params)
		h.until(stream, "started")
		pid, err := os.ReadFile(filepath.Join(dir, "child"))
		if err != nil {
			t.Fatal(err)
		}
		child := strings.TrimSpace(string(pid))
		h.ok("stream.kill", map[string]string{"stream": stream})
		h.drain(stream)
		for deadline := time.Now().Add(testTimeout); ; {
			out, err := exec.Command("ps", "-o", "stat=", "-p", child).Output()
			var exit *exec.ExitError
			if err != nil && !errors.As(err, &exit) {
				t.Fatal(err)
			}
			// Gone (ps exits 1), or a zombie its new parent has not reaped yet.
			if state := strings.TrimSpace(string(out)); state == "" || strings.HasPrefix(state, "Z") {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s: the shell's child %s still runs after the kill", method, child)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

// producer is a command that prints `seq 1 lines`, then creates the file finished in its directory.
func producer(lines int) string { return fmt.Sprintf("seq 1 %d && touch finished", lines) }

// seqLines is what `seq 1 lines` prints.
func seqLines(lines int) string {
	var text strings.Builder
	for i := 1; i <= lines; i++ {
		fmt.Fprintf(&text, "%d\n", i)
	}
	return text.String()
}

// checkPause pauses stream, a producer of far more than its pipe, PTY or SSH window holds, running in dir: nothing
// arrives after the pause's response and the producer stays blocked; resume delivers the rest in order, then the
// exit. Both are idempotent.
func checkPause(t *testing.T, h *harness, stream, dir string, lines int) {
	t.Helper()
	h.ok("stream.pause", map[string]string{"stream": stream})
	h.ok("stream.pause", map[string]string{"stream": stream})
	var got strings.Builder
	// What the core emitted before the pause's response is queued already.
	for queued := true; queued; {
		select {
		case m := <-h.events(stream):
			if m.Event != "stream.data" {
				t.Fatalf("%s: before the pause: %s", stream, m.raw)
			}
			got.WriteString(m.Params.Data)
		default:
			queued = false
		}
	}
	time.Sleep(500 * time.Millisecond)
	select {
	case m := <-h.events(stream):
		t.Fatalf("%s: an event while paused: %.200s", stream, m.raw)
	default:
	}
	if _, err := os.Stat(filepath.Join(dir, "finished")); err == nil {
		t.Fatalf("%s: the producer got all its output out while paused", stream)
	}
	h.ok("stream.resume", map[string]string{"stream": stream})
	h.ok("stream.resume", map[string]string{"stream": stream})
	o := h.drain(stream)
	got.WriteString(o.stdout.String())
	// A PTY turns "\n" into "\r\n"; a macOS PTY whose output queue filled at a line end repeats the "\r".
	if text := strings.ReplaceAll(got.String(), "\r", ""); text != seqLines(lines) || exitCodeOf(t, o) != 0 {
		t.Fatalf("%s: %d bytes after resume, want %d (%s)", stream, len(text), len(seqLines(lines)), o.exit.raw)
	}
	if err := os.Remove(filepath.Join(dir, "finished")); err != nil {
		t.Fatalf("%s: the producer did not finish: %v", stream, err)
	}
}

func TestStreamPause(t *testing.T) {
	h := newHarness(t)
	dir := t.TempDir()
	checkPause(t, h, h.open("local.exec", map[string]any{"command": producer(200_000), "cwd": dir}), dir, 200_000)
	checkPause(t, h, h.open("pty.open", map[string]any{"command": producer(200_000), "cwd": dir, "cols": 80,
		"rows": 24}), dir, 200_000)

	// A process that ends while paused: its output and exit come after resume.
	late := h.open("local.exec", map[string]any{"command": "sleep 0.2; seq 1 10000"})
	h.ok("stream.pause", map[string]string{"stream": late})
	time.Sleep(time.Second)
	select {
	case m := <-h.events(late):
		t.Fatalf("an event while paused: %.200s", m.raw)
	default:
	}
	h.ok("stream.resume", map[string]string{"stream": late})
	if o := h.drain(late); o.stdout.String() != seqLines(10000) || exitCodeOf(t, o) != 0 {
		t.Fatalf("after resume: %d bytes, want %d (%s)", o.stdout.Len(), len(seqLines(10000)), o.exit.raw)
	}

	// stream.kill resumes.
	yes := h.open("local.exec", map[string]any{"argv": []string{"yes"}})
	h.ok("stream.pause", map[string]string{"stream": yes})
	h.ok("stream.kill", map[string]string{"stream": yes})
	if o := h.drain(yes); o.exit.Params.Signal != "KILL" {
		t.Fatalf("killed paused yes exited with %s", o.exit.raw)
	}
}

// TestAwaitOutput checks the time a local process's output may stay open after it exited: it stops while the stream is
// paused, and once it ran out the pipes close.
func TestAwaitOutput(t *testing.T) {
	s := New(nil).newStream(false)
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer write.Close()
	copied := make(chan error, 1)
	done := make(chan error, 1)
	s.pause()
	go func() { done <- s.awaitOutput(copied, read) }()
	select {
	case err := <-done:
		t.Fatalf("awaitOutput gave up on a paused stream: %v", err)
	case <-time.After(outputGrace + 500*time.Millisecond):
	}
	s.resume()
	copied <- nil
	if err := <-done; err != nil {
		t.Fatal(err)
	}

	read, write, err = os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer write.Close()
	start := time.Now()
	if err := s.awaitOutput(make(chan error), read); err != nil {
		t.Fatal(err)
	}
	if waited := time.Since(start); waited < outputGrace || waited > outputGrace+time.Second {
		t.Fatalf("a copy that never ends was waited for %v, want %v", waited, outputGrace)
	}
	if _, err := read.Read(make([]byte, 1)); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("the pipe was not closed: %v", err)
	}
}

func TestTerminalEnv(t *testing.T) {
	account := func() string { return "/bin/zsh" }
	noLocale := func(key string) string { return map[string]string{"SHELL": "zsh"}[key] }
	got := terminalEnv("xterm-256color", nil, false, noLocale, account)
	want := map[string]string{"TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("without a locale and an absolute SHELL: %v", got)
	}
	if shell := defaultShell(got); fmt.Sprint(shell) != "[/bin/zsh -l]" {
		t.Fatalf("defaultShell = %v", shell)
	}
	configured := func(key string) string {
		return map[string]string{"SHELL": "/bin/bash", "LC_CTYPE": "de_DE.UTF-8"}[key]
	}
	got = terminalEnv("vt100", map[string]string{"COLORTERM": "24bit"}, false, configured,
		func() string { t.Fatal("looked up the account's shell though SHELL is absolute"); return "" })
	if fmt.Sprint(got) != fmt.Sprint(map[string]string{"TERM": "vt100", "COLORTERM": "24bit"}) {
		t.Fatalf("with a locale, SHELL and a page COLORTERM: %v", got)
	}
	if shell := parseDsclUserShell("UserShell: /opt/homebrew/bin/fish\n"); shell != "/opt/homebrew/bin/fish" {
		t.Fatalf("parseDsclUserShell = %q", shell)
	}
	if shell := parsePasswdShell("me:x:1000:1000:Me:/home/me:/usr/bin/zsh\n"); shell != "/usr/bin/zsh" {
		t.Fatalf("parsePasswdShell = %q", shell)
	}
	if shell := parsePasswdShell("me:x:1000:1000:Me:/home/me:zsh"); shell != "" {
		t.Fatalf("parsePasswdShell of a relative shell = %q", shell)
	}
	// This computer's account has an absolute login shell.
	if shell := accountShell(); !strings.HasPrefix(shell, "/") {
		t.Fatalf("accountShell() = %q", shell)
	}
}

func TestFlatpakStart(t *testing.T) {
	got := flatpakStart([]string{"/bin/sh", "-c", "echo hi"}, map[string]string{"B": "2", "A": "1"}, "/work", false)
	want := []string{"flatpak-spawn", "--host", "--directory=/work", "--env=A=1", "--env=B=2", "/bin/sh", "-c", "echo hi"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("flatpakStart = %q, want %q", got, want)
	}
	got = flatpakStart([]string{"bash", "-l"}, nil, "", true)
	want = []string{"/app/libexec/release-tty", "flatpak-spawn", "--host", "bash", "-l"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("flatpakStart for a PTY = %q, want %q", got, want)
	}
}
