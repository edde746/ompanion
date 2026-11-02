// Command capi is the core's C binding for the Windows and Linux shells, built with -buildmode=c-shared
// (docs/contracts/bridge.md, Core bindings).
package main

/*
#include <stdlib.h>
typedef void (*omp_core_emit)(const char *message, void *context);
// Go cannot call a C function pointer itself.
static void omp_core_call(omp_core_emit emit, const char *message, void *context) { emit(message, context); }
*/
import "C"

import (
	"fmt"
	"os"
	"sync"
	"unsafe"

	"ompanion.app/core"
)

var (
	once     sync.Once
	instance *core.Core
)

func shared() *core.Core {
	once.Do(func() { instance = core.New(nil) })
	return instance
}

// OmpCoreStart points the process's one core at emit; called again, it only replaces emit. The message passed to
// emit is valid only during the call.
//
//export OmpCoreStart
func OmpCoreStart(emit C.omp_core_emit, context unsafe.Pointer) {
	shared().SetEmit(func(message string) {
		text := C.CString(message)
		defer C.free(unsafe.Pointer(text))
		C.omp_core_call(emit, text, context)
	})
}

// OmpCoreSend hands the core one request; the caller keeps ownership of message.
//
//export OmpCoreSend
func OmpCoreSend(message *C.char) {
	shared().Handle(C.GoString(message))
}

// OmpCoreSetEnv sets a variable of the process for the core: Go reads the environment once when the library loads,
// so a C setenv afterwards never reaches it. The caller keeps ownership of key and value.
//
//export OmpCoreSetEnv
func OmpCoreSetEnv(key, value *C.char) {
	if err := os.Setenv(C.GoString(key), C.GoString(value)); err != nil {
		fmt.Fprintf(os.Stderr, "core: OmpCoreSetEnv: %v\n", err)
	}
}

func main() {}
