//go:build ios || android

package core

import (
	"fmt"
	"runtime"
)

// startPTY fails: phones run no local processes (pty.open checks local() before it gets here).
func startPTY(argv []string, cmdLine string, env []string, dir string, cols, rows int) (localPTY, error) {
	return nil, fmt.Errorf("local PTYs are not available on %s", runtime.GOOS)
}

func ptyEnded(err error) bool { return false }
