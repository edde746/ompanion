package core

import (
	"os"
	"strings"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A kill ends what the process started too, which TerminateProcess alone leaves running.
func TestKillEndsWhatItStarted(t *testing.T) {
	h := newHarness(t)
	stream := h.open("local.exec", map[string]any{
		"command": "start /b ping -n 300 127.0.0.1 >nul & echo started & ping -n 300 127.0.0.1 >nul"})
	h.until(stream, "started")
	var shells, pings []uint32
	for _, p := range processes(t) {
		if p.ParentProcessID == uint32(os.Getpid()) && exeName(p) == "cmd.exe" {
			shells = append(shells, p.ProcessID)
		}
	}
	for _, p := range processes(t) {
		for _, shell := range shells {
			if p.ParentProcessID == shell && exeName(p) == "ping.exe" {
				pings = append(pings, p.ProcessID)
			}
		}
	}
	// The background ping started before the echo; the foreground one may not have yet.
	if len(pings) == 0 {
		t.Fatal("found no ping the shell started")
	}
	handles := make([]windows.Handle, len(pings))
	for i, pid := range pings {
		handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
		if err != nil {
			t.Fatalf("opening ping %d: %v", pid, err)
		}
		handles[i] = handle
		t.Cleanup(func() {
			if err := windows.CloseHandle(handle); err != nil {
				t.Error(err)
			}
		})
	}
	h.ok("stream.kill", map[string]string{"stream": stream})
	h.drain(stream)
	for i, handle := range handles {
		if event, err := windows.WaitForSingleObject(handle, uint32(testTimeout.Milliseconds())); err != nil ||
			event != windows.WAIT_OBJECT_0 {
			t.Fatalf("ping %d still runs after the kill (%#x, %v)", pings[i], event, err)
		}
	}
}

// processes is a snapshot of every process on the computer.
func processes(t *testing.T) []windows.ProcessEntry32 {
	t.Helper()
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := windows.CloseHandle(snapshot); err != nil {
			t.Error(err)
		}
	}()
	var list []windows.ProcessEntry32
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		list = append(list, entry)
	}
	if err != windows.ERROR_NO_MORE_FILES {
		t.Fatal(err)
	}
	return list
}

func exeName(p windows.ProcessEntry32) string {
	return strings.ToLower(windows.UTF16ToString(p.ExeFile[:]))
}
