//go:build windows

package core

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/charmbracelet/x/conpty"
	"golang.org/x/sys/windows"
)

type windowsPTY struct {
	console *conpty.ConPty
	process *os.Process
}

// startPTY starts argv, or the raw command line cmdLine when it is not empty (shellArgv).
func startPTY(argv []string, cmdLine string, env []string, dir string, cols, rows int) (localPTY, error) {
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, err
	}
	console, err := conpty.New(cols, rows, 0)
	if err != nil {
		return nil, err
	}
	attr := &syscall.ProcAttr{Dir: dir, Env: env}
	if cmdLine != "" {
		attr.Sys = &syscall.SysProcAttr{CmdLine: cmdLine}
	}
	pid, handle, err := console.Spawn(path, argv, attr)
	if err != nil {
		return nil, errors.Join(err, console.Close())
	}
	// The open handle keeps the pid from being reused until os.FindProcess holds its own.
	process, err := os.FindProcess(pid)
	if err != nil {
		return nil, errors.Join(err, windows.TerminateProcess(windows.Handle(handle), 1),
			windows.CloseHandle(windows.Handle(handle)), console.Close())
	}
	if err := windows.CloseHandle(windows.Handle(handle)); err != nil {
		return nil, errors.Join(err, process.Kill(), console.Close())
	}
	return &windowsPTY{console: console, process: process}, nil
}

func (p *windowsPTY) Read(b []byte) (int, error)  { return p.console.Read(b) }
func (p *windowsPTY) Write(b []byte) (int, error) { return p.console.Write(b) }

func (p *windowsPTY) closeInput() error {
	return errors.New("a ConPTY cannot close its input: write ^Z and Enter, or kill the stream")
}

func (p *windowsPTY) resize(cols, rows int) error { return p.console.Resize(cols, rows) }

func (p *windowsPTY) kill() error { return p.process.Kill() }

// wait closes the pseudo console once the process exited: until then, reads of its output never end.
func (p *windowsPTY) wait() ending {
	state, err := p.process.Wait()
	if err != nil {
		return ending{code: -1, err: errors.Join(err, p.console.Close())}
	}
	if err := p.console.Close(); err != nil {
		return ending{code: state.ExitCode(), err: fmt.Errorf("closing the pseudo console: %w", err)}
	}
	return ending{code: state.ExitCode()}
}

// release is a no-op after wait: ConPty.Close runs once.
func (p *windowsPTY) release() error { return p.console.Close() }

// ptyEnded reports whether a read error is the end of a ConPTY's output: the pipe breaks when the console closes, or
// its handle is already closed.
func ptyEnded(err error) bool {
	return errors.Is(err, windows.ERROR_BROKEN_PIPE) || errors.Is(err, windows.ERROR_INVALID_HANDLE) ||
		errors.Is(err, os.ErrClosed)
}
