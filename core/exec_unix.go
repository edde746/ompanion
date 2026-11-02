//go:build !windows

package core

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// shellArgv is how the user's shell runs command, as sshd's exec does. cmdLine is Windows' raw command line: none
// here.
func shellArgv(command string) (argv []string, cmdLine string) {
	return []string{"/bin/sh", "-c", command}, ""
}

func shellCommand(command string, env map[string]string, dir string) *exec.Cmd {
	argv, _ := shellArgv(command)
	return hostCommand(argv, env, dir, false)
}

// processGroup is a local process that leads a process group of its own: kill ends the group, so what the process
// started goes with it (a killed follow script's shell would leave its background `tail -F` running).
type processGroup struct{ process *os.Process }

// startGroup starts cmd as the leader of a new process group.
func startGroup(cmd *exec.Cmd) (*processGroup, error) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &processGroup{cmd.Process}, nil
}

func (g *processGroup) kill() error { return killGroup(g.process) }

func (g *processGroup) release() error { return nil }

// killGroup sends SIGKILL to the process group p leads, which Process.Kill sends to p alone.
func killGroup(p *os.Process) error {
	// Once p was waited for, its pid, and so the group's id, may be another process's.
	if err := p.Signal(syscall.Signal(0)); errors.Is(err, os.ErrProcessDone) {
		return err
	}
	err := syscall.Kill(-p.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}

// signalOf names the signal that ended a process the way SSH's exit-signal does: "TERM", "KILL", … ("" for none).
func signalOf(state *os.ProcessState) string {
	status, ok := state.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() {
		return ""
	}
	return strings.TrimPrefix(unix.SignalName(status.Signal()), "SIG")
}
