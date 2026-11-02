package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"sync"
	"time"
)

func (c *Core) localExec(params json.RawMessage) (any, func(), error) {
	if !local() {
		return nil, nil, fmt.Errorf("local.exec is not available on %s", runtime.GOOS)
	}
	p, err := decode[struct {
		Argv     []string          `json:"argv"`
		Command  string            `json:"command"`
		Cwd      string            `json:"cwd"`
		Env      map[string]string `json:"env"`
		Encoding string            `json:"encoding"`
	}](params)
	if err != nil {
		return nil, nil, err
	}
	binary, err := streamEncoding(p.Encoding)
	if err != nil {
		return nil, nil, err
	}
	var cmd *exec.Cmd
	switch {
	case len(p.Argv) > 0 && p.Command == "":
		cmd = hostCommand(p.Argv, p.Env, nativePath(p.Cwd), false)
	case len(p.Argv) == 0 && p.Command != "":
		cmd = shellCommand(p.Command, p.Env, nativePath(p.Cwd))
	default:
		return nil, nil, errors.New("local.exec needs argv or command")
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, err
	}
	// Pipes of its own, not exec's copying: exec's WaitDelay would close them 2 s after the process exited even while
	// the stream is paused, dropping what they still hold.
	stdoutRead, stdoutWrite, err := os.Pipe()
	if err != nil {
		return nil, nil, errors.Join(err, stdin.Close())
	}
	stderrRead, stderrWrite, err := os.Pipe()
	if err != nil {
		return nil, nil, errors.Join(err, stdin.Close(), stdoutRead.Close(), stdoutWrite.Close())
	}
	cmd.Stdout, cmd.Stderr = stdoutWrite, stderrWrite
	group, err := startGroup(cmd)
	// The process has its own copies of the write ends; the reads end once it and its children closed theirs.
	closeErr := errors.Join(stdoutWrite.Close(), stderrWrite.Close())
	if err != nil {
		return nil, nil, errors.Join(err, stdoutRead.Close(), stderrRead.Close())
	}
	if closeErr != nil {
		c.writeLog(fmt.Sprintf("local.exec: closing the write ends of the output pipes: %v", closeErr))
	}
	s := c.newStream(binary)
	s.stdin = stdin
	s.kill = group.kill
	c.register(s)
	stdout, stderr := c.output(s, "stdout"), c.output(s, "stderr")
	return map[string]string{"stream": s.id}, func() {
		close(s.started)
		copied := make(chan error, 2)
		go func() { copied <- copyOutput(stdout, stdoutRead) }()
		go func() { copied <- copyOutput(stderr, stderrRead) }()
		err := cmd.Wait()
		end := exitCode(cmd.ProcessState, err)
		end.err = errors.Join(end.err, s.awaitOutput(copied, stdoutRead, stderrRead), group.release())
		stdout.flush()
		stderr.flush()
		c.exit(s, end)
	}, nil
}

// outputGrace is how long a local process's output may stay open, the stream not paused, after the process exited:
// a background child that inherited stdout must not keep the stream open.
const outputGrace = 2 * time.Second

// awaitOutput waits for the copies of a local process's output pipes, which send their results on copied, after the
// process exited, and closes the pipes. Once the stream spent outputGrace not paused, it stops waiting.
func (s *stream) awaitOutput(copied <-chan error, pipes ...*os.File) error {
	var errs []error
	grace := time.NewTimer(outputGrace)
	defer grace.Stop()
	left := len(pipes)
wait:
	for left > 0 {
		select {
		case err := <-copied:
			errs = append(errs, err)
			left--
		case <-grace.C:
			paused := s.pausedUntil()
			if paused == nil {
				// A background child holds a pipe. On Windows closing it does not end a read in flight: that copy's
				// late output is dropped, as the stream has exited by then.
				break wait
			}
			<-paused
			grace.Reset(outputGrace)
		}
	}
	for _, pipe := range pipes {
		errs = append(errs, pipe.Close())
	}
	return errors.Join(errs...)
}

// copyOutput copies a pipe into an output until the pipe ends; closing it (awaitOutput) is an end too.
func copyOutput(out *output, pipe *os.File) error {
	_, err := io.Copy(out, pipe)
	if errors.Is(err, os.ErrClosed) {
		return nil
	}
	return err
}

// environ returns the core's environment with overrides applied; exec.Cmd keeps the last value of a repeated key.
func environ(overrides map[string]string) []string {
	env := os.Environ()
	for key, value := range overrides {
		env = append(env, key+"="+value)
	}
	return env
}

// exitCode reads how a finished process ended: no code (-1) when a signal ended it or it never ran, with the reason
// in err. err is what waiting for it returned.
func exitCode(state *os.ProcessState, err error) ending {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		err = nil // a non-zero status, which state carries
	}
	if state == nil {
		return ending{code: -1, err: err}
	}
	if code := state.ExitCode(); code >= 0 {
		return ending{code: code, err: err}
	}
	return ending{code: -1, signal: signalOf(state), err: errors.Join(errors.New(state.String()), err)}
}

// inFlatpak reports whether the core runs in a Flatpak sandbox, where its own processes see the runtime's /usr and
// /etc instead of this computer's. What this computer runs then starts on the host (hostStart).
var inFlatpak = sync.OnceValue(func() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	_, err := os.Stat("/.flatpak-info")
	return err == nil
})

// hostStart is how argv starts with env (added to the core's environment) in dir on this computer: as itself, or in
// a Flatpak as flatpakStart says.
func hostStart(argv []string, env map[string]string, dir string, terminal bool) ([]string, map[string]string, string) {
	if !inFlatpak() {
		return argv, env, dir
	}
	return flatpakStart(argv, env, dir, terminal), nil, ""
}

// flatpakStart starts argv on the host through `flatpak-spawn --host` (the manifest's org.freedesktop.Flatpak
// permission). The host process gets the environment of the user's session, not the sandbox's, so env and dir go as
// flatpak-spawn's options, which it reads only as --name=value before the program. terminal is a start on a PTY that
// the new process leads: release-tty lets go of the PTY so the host shell can take it.
func flatpakStart(argv []string, env map[string]string, dir string, terminal bool) []string {
	spawn := []string{"flatpak-spawn", "--host"}
	if dir != "" {
		spawn = append(spawn, "--directory="+dir)
	}
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		spawn = append(spawn, "--env="+key+"="+env[key])
	}
	spawn = append(spawn, argv...)
	if terminal {
		return append([]string{"/app/libexec/release-tty"}, spawn...)
	}
	return spawn
}

// hostCommand is the exec.Cmd of hostStart.
func hostCommand(argv []string, env map[string]string, dir string, terminal bool) *exec.Cmd {
	argv, env, dir = hostStart(argv, env, dir, terminal)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = environ(env)
	cmd.Dir = dir
	return cmd
}
