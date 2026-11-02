// Package ompcore is the core's gomobile binding for the Apple and Android shells (docs/contracts/bridge.md, Core
// bindings).
package ompcore

import (
	"os"
	"sync"

	"ompanion.app/core"
)

// Listener receives every message the core emits, one at a time, on a core thread.
type Listener interface {
	OnMessage(message string)
}

var (
	once     sync.Once
	instance *core.Core
)

func shared() *core.Core {
	once.Do(func() { instance = core.New(nil) })
	return instance
}

// Start points the process's one core at listener; called again, it only replaces the listener.
func Start(listener Listener) {
	shared().SetEmit(listener.OnMessage)
}

// Send hands the core one request.
func Send(message string) {
	shared().Handle(message)
}

// SetEnv sets a variable of the process before the page loads: the Android shell has no environment of its own.
func SetEnv(key, value string) error {
	return os.Setenv(key, value)
}
