//go:build !windows && !ios && !android

package core

import (
	"errors"
	"os"
	"os/exec"
	"syscall"

	"github.com/creack/pty"
)

type unixPTY struct {
	cmd    *exec.Cmd
	master *os.File
}

// startPTY starts argv; cmdLine is Windows' raw command line, which Unix has no use for.
func startPTY(argv []string, _ string, env []string, dir string, cols, rows int) (localPTY, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Dir = dir
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, err
	}
	return &unixPTY{cmd: cmd, master: master}, nil
}

func (p *unixPTY) Read(b []byte) (int, error)  { return p.master.Read(b) }
func (p *unixPTY) Write(b []byte) (int, error) { return p.master.Write(b) }

// closeInput types VEOF (^D), which ends the input of a program reading a line.
func (p *unixPTY) closeInput() error {
	_, err := p.master.Write([]byte{4})
	return err
}

func (p *unixPTY) resize(cols, rows int) error {
	return pty.Setsize(p.master, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

// kill ends the PTY's process group: pty.Start made the process a session leader, so it leads its group too.
func (p *unixPTY) kill() error { return killGroup(p.cmd.Process) }

func (p *unixPTY) wait() ending {
	err := p.cmd.Wait()
	return exitCode(p.cmd.ProcessState, err)
}

func (p *unixPTY) release() error { return p.master.Close() }

// ptyEnded reports whether a read error is the end of a PTY's output: Linux reports EIO once the terminal side is
// closed.
func ptyEnded(err error) bool {
	return errors.Is(err, syscall.EIO)
}
