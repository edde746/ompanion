//go:build windows

package core

import (
	"errors"
	"os"
	"os/exec"
	"sync"
	"syscall"

	"golang.org/x/sys/windows"
)

// shellArgv is how cmd.exe runs command exactly as written, the way Windows OpenSSH's exec does with cmd.exe as its
// shell. Go quotes each argument for the C runtime, turning a " inside one into \", which cmd.exe has no escape for;
// so cmdLine, the whole command line as written, goes to CreateProcess, and /s makes cmd.exe remove exactly the outer
// quotes.
func shellArgv(command string) (argv []string, cmdLine string) {
	return []string{"cmd.exe", "/d", "/s", "/c", command}, `cmd.exe /d /s /c "` + command + `"`
}

func shellCommand(command string, env map[string]string, dir string) *exec.Cmd {
	argv, cmdLine := shellArgv(command)
	cmd := exec.Command(argv[0])
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: cmdLine}
	cmd.Env = environ(env)
	cmd.Dir = dir
	return cmd
}

// processGroup is a local process in a job object of its own: kill terminates the job, so what the process started
// goes with it (Process.Kill's TerminateProcess ends the process alone). A detached run leaves no process in it: its
// launch starts omp through Win32_Process.Create (windows_run.ts).
type processGroup struct {
	mu  sync.Mutex
	job windows.Handle // 0 once released
}

// startGroup starts cmd and puts it in a new job object. A process it started before that is outside the job; cmd.exe
// and PowerShell start nothing that soon.
func startGroup(cmd *exec.Cmd) (*processGroup, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, errors.Join(err, windows.CloseHandle(job))
	}
	if err := assignToJob(job, cmd.Process.Pid); err != nil {
		return nil, errors.Join(err, cmd.Process.Kill(), cmd.Process.Release(), windows.CloseHandle(job))
	}
	return &processGroup{job: job}, nil
}

// assignToJob puts process pid in job; cmd.Process's own handle keeps the pid from being reused meanwhile.
func assignToJob(job windows.Handle, pid int) error {
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return err
	}
	return errors.Join(windows.AssignProcessToJobObject(job, process), windows.CloseHandle(process))
}

// kill ends every process in the job with exit code 1, as Process.Kill does.
func (g *processGroup) kill() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.job == 0 {
		return os.ErrProcessDone
	}
	return windows.TerminateJobObject(g.job, 1)
}

// release closes the job once the process was waited for; processes left in it run on.
func (g *processGroup) release() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.job == 0 {
		return nil
	}
	err := windows.CloseHandle(g.job)
	g.job = 0
	return err
}

// signalOf is empty: Windows processes do not end by signal.
func signalOf(*os.ProcessState) string { return "" }
