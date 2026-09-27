// The live-daemon tests in this file drive the real daemon over its
// socket, so they are gated and cleaned up by internal/livetest (#110).
// That puts them in the external test package: livetest imports
// internal/daemon, so a file in `package daemon` cannot import it without
// an import cycle.
package daemon_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/jwulff/steno/internal/daemon"
	"github.com/jwulff/steno/internal/livetest"
)

// TestDaemonCrashDuringRecording tests if the daemon crashes during recording
// even without an event subscriber. This isolates whether the crash is related
// to event broadcasting or to SpeechAnalyzer itself.
//
// Mutating: stops and starts the daemon. livetest.Require gates it behind
// STENO_LIVE_TESTS=1 and restores the state it found.
func TestDaemonCrashDuringRecording(t *testing.T) {
	client := livetest.Require(t)

	// Start recording
	livetest.EnsureIdle(t, client)

	resp, err := client.SendCommand(daemon.Command{Cmd: "start"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if !resp.OK {
		t.Fatalf("start failed: %s", resp.Error)
	}
	fmt.Printf("Started recording: sessionId=%s\n", resp.SessionID)

	// Wait 5 seconds to let SpeechAnalyzer actually process audio
	fmt.Println("Waiting 5 seconds to let speech recognizer run...")
	time.Sleep(5 * time.Second)

	// Check if daemon is still alive by sending status
	resp, err = client.SendCommand(daemon.Command{Cmd: "status"})
	if err != nil {
		t.Fatalf("daemon crashed during recording (status failed): %v", err)
	}
	fmt.Printf("Still alive after 5s: recording=%v segments=%v\n", derefBool(resp.Recording), derefInt(resp.Segments))

	// Stop
	resp, err = client.SendCommand(daemon.Command{Cmd: "stop"})
	if err != nil {
		t.Fatalf("stop: %v", err)
	}
	fmt.Printf("Stopped: recording=%v\n", derefBool(resp.Recording))
}
