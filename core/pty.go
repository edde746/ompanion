package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"os/user"
	"regexp"
	"runtime"
	"strings"
	"sync"
)

// localPTY is a process on a local pseudo-terminal: creack/pty on Unix, ConPTY on Windows.
type localPTY interface {
	io.Reader
	io.Writer
	// closeInput ends the input the way a terminal user does.
	closeInput() error
	resize(cols, rows int) error
	kill() error
	// wait waits for the process and lets pending reads end.
	wait() ending
	release() error
}

type ptyParams struct {
	Machine  string            `json:"machine"`
	Argv     []string          `json:"argv"`
	Command  string            `json:"command"`
	Cwd      string            `json:"cwd"`
	Cols     int               `json:"cols"`
	Rows     int               `json:"rows"`
	Term     string            `json:"term"`
	Env      map[string]string `json:"env"`
	Encoding string            `json:"encoding"`
}

// term is the terminal type the PTY announces: an env TERM, else term, else xterm-256color.
func (p ptyParams) term() string {
	if term, ok := p.Env["TERM"]; ok {
		return term
	}
	if p.Term != "" {
		return p.Term
	}
	return "xterm-256color"
}

func (c *Core) ptyOpen(params json.RawMessage) (any, func(), error) {
	p, err := decode[ptyParams](params)
	if err != nil {
		return nil, nil, err
	}
	if p.Cols <= 0 || p.Rows <= 0 {
		return nil, nil, errors.New("pty.open needs cols > 0 and rows > 0")
	}
	binary, err := streamEncoding(p.Encoding)
	if err != nil {
		return nil, nil, err
	}
	if p.Machine != "" {
		if len(p.Argv) > 0 || p.Cwd != "" {
			return nil, nil, errors.New("an SSH PTY runs command, without argv and cwd")
		}
		return c.sshPTY(p, binary)
	}
	if !local() {
		return nil, nil, fmt.Errorf("local PTYs are not available on %s", runtime.GOOS)
	}
	env := terminalEnv(p.term(), p.Env, runtime.GOOS == "windows", os.Getenv, accountShell)
	argv, cmdLine := p.Argv, ""
	switch {
	case len(argv) > 0 && p.Command != "":
		return nil, nil, errors.New("a local PTY runs argv or command, not both")
	case p.Command != "":
		argv, cmdLine = shellArgv(p.Command)
	case len(argv) == 0:
		argv = defaultShell(env)
	}
	dir := nativePath(p.Cwd)
	if dir == "" {
		if dir, err = os.UserHomeDir(); err != nil {
			return nil, nil, err
		}
	}
	argv, env, dir = hostStart(argv, env, dir, true)
	t, err := startPTY(argv, cmdLine, environ(env), dir, p.Cols, p.Rows)
	if err != nil {
		return nil, nil, err
	}
	s := c.newStream(binary)
	s.stdin = ptyInput{t}
	s.kill = t.kill
	s.resize = t.resize
	c.register(s)
	out := c.output(s, "stdout")
	return map[string]string{"stream": s.id}, func() {
		close(s.started)
		read := make(chan error, 1)
		go func() {
			_, err := io.Copy(out, t)
			if ptyEnded(err) {
				err = nil
			}
			read <- err
		}()
		end := t.wait()
		readErr := <-read
		out.flush()
		end.err = errors.Join(end.err, readErr, t.release())
		c.exit(s, end)
	}, nil
}

// ptyInput is a local PTY's stdin: Close ends the input instead of releasing the PTY.
type ptyInput struct{ t localPTY }

func (i ptyInput) Write(p []byte) (int, error) { return i.t.Write(p) }
func (i ptyInput) Close() error                { return i.t.closeInput() }

// defaultShell is the user's login shell, as terminal apps start it (a GUI app's own PATH is minimal): env's SHELL
// (terminalEnv), else the core's, when absolute; PowerShell on Windows.
func defaultShell(env map[string]string) []string {
	if runtime.GOOS == "windows" {
		return []string{"powershell.exe", "-NoLogo"}
	}
	shell := env["SHELL"]
	if shell == "" {
		shell = os.Getenv("SHELL")
	}
	if !strings.HasPrefix(shell, "/") {
		shell = "/bin/sh"
	}
	return []string{shell, "-l"}
}

// terminalEnv is what a local terminal gets on top of the core's environment (lookup): TERM and COLORTERM; on POSIX a
// UTF-8 locale when the environment names none (GUI apps on macOS start without one, and zsh then mangles UTF-8
// input), and the account's login shell as SHELL when the environment has no absolute one (an app started by launchd
// or a desktop launcher may have none). page, the request's env, wins over all of it.
func terminalEnv(term string, page map[string]string, windows bool, lookup func(string) string,
	account func() string) map[string]string {
	env := map[string]string{"TERM": term, "COLORTERM": "truecolor"}
	if !windows {
		if lookup("LC_ALL") == "" && lookup("LC_CTYPE") == "" && lookup("LANG") == "" {
			env["LANG"] = "en_US.UTF-8"
		}
		if _, given := page["SHELL"]; !given && !strings.HasPrefix(lookup("SHELL"), "/") {
			if shell := account(); shell != "" {
				env["SHELL"] = shell
			}
		}
	}
	maps.Copy(env, page)
	return env
}

// accountShell is the login shell the user database names for this user (USER, else LOGNAME, else the process's
// user): dscl on macOS, getent passwd elsewhere, /etc/passwd where there is no getent; in a Flatpak on the host, whose
// sandbox has a passwd of its own. "" when the lookup finds no absolute path, which leaves /bin/sh, as accountLoginShell
// does.
var accountShell = sync.OnceValue(func() string {
	name := os.Getenv("USER")
	if name == "" {
		name = os.Getenv("LOGNAME")
	}
	if name == "" {
		current, err := user.Current()
		if err != nil {
			return ""
		}
		name = current.Username
	}
	if runtime.GOOS == "darwin" {
		out, err := hostCommand([]string{"dscl", ".", "-read", "/Users/" + name, "UserShell"}, nil, "", false).Output()
		if err != nil {
			return ""
		}
		return parseDsclUserShell(string(out))
	}
	out, err := hostCommand([]string{"getent", "passwd", name}, nil, "", false).Output()
	if errors.Is(err, exec.ErrNotFound) {
		passwd, err := os.ReadFile("/etc/passwd")
		if err != nil {
			return ""
		}
		for line := range strings.Lines(string(passwd)) {
			if strings.HasPrefix(line, name+":") {
				return parsePasswdShell(line)
			}
		}
		return ""
	}
	if err != nil {
		return ""
	}
	return parsePasswdShell(string(out))
})

var dsclUserShell = regexp.MustCompile(`(?m)^UserShell:\s*(/\S+)\s*$`)

// parseDsclUserShell reads the path in `dscl . -read /Users/<user> UserShell` output (`UserShell: /bin/zsh`).
func parseDsclUserShell(output string) string {
	match := dsclUserShell.FindStringSubmatch(output)
	if match == nil {
		return ""
	}
	return match[1]
}

// parsePasswdShell reads the shell field (the seventh) of a passwd line, when it is an absolute path.
func parsePasswdShell(line string) string {
	fields := strings.Split(strings.TrimSpace(line), ":")
	if len(fields) < 7 || !strings.HasPrefix(fields[6], "/") {
		return ""
	}
	return fields[6]
}
