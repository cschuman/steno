// Package livetest gates and cleans up after the tests that drive the
// real steno daemon over its socket.
//
// Those tests are not hermetic. They connect to whatever daemon is
// installed on the machine, which on a developer's Mac is the same daemon
// that is recording that developer. Before #110 they skipped only when the
// socket file was missing and every mutating one ended on `stop`, so
// running `make test` turned the user's recording off and nothing ever
// turned it back on: always-on recording (#32) has no user-facing start,
// and `.idle` is a state the engine never leaves on its own.
//
// Two rules, and a mutating live test needs both:
//
//  1. Opt in. STENO_LIVE_TESTS=1 must be set, so a plain `go test ./...`
//     cannot touch anyone's daemon by accident. `make test-live` sets it;
//     `make test` deliberately does not.
//  2. Put it back. Require captures the daemon's state up front and
//     restores it in t.Cleanup, failing the test if it cannot.
//
// Read-only live tests (`status`, `devices`, `subscribe`) do not need this
// and stay ungated.
package livetest

import (
	"os"
	"testing"

	"github.com/jwulff/steno/internal/daemon"
)

// EnvVar must be set to "1" for a mutating live-daemon test to run.
const EnvVar = "STENO_LIVE_TESTS"

// State is the part of a `status` response that decides whether a mutating
// live test may run, and what it has to put back when it is done.
type State struct {
	Status             string
	Recording          bool
	Paused             bool
	PausedIndefinitely bool
}

// Decision is the outcome of a gate check.
type Decision struct {
	Run        bool
	SkipReason string
}

// GateEnvironment decides whether a mutating live test may run, from what
// can be known before connecting.
func GateEnvironment(socketPresent, optedIn bool) Decision {
	if !socketPresent {
		return Decision{SkipReason: "daemon not running (no socket at " + daemon.SocketPath() + ")"}
	}
	if !optedIn {
		return Decision{SkipReason: "mutating live-daemon test: set " + EnvVar +
			"=1 to run it (it stops and starts the daemon that is recording you), or use `make test-live`"}
	}
	return Decision{Run: true}
}

// GateState decides whether a mutating live test may run against the
// daemon state it found.
//
// A paused daemon is off limits. `stop` clears the engine's in-memory
// pause markers while leaving the persisted pause anchor on the session
// row, so the stop/start these tests perform would resume capture on
// someone who explicitly asked not to be recorded, and would look like a
// plain idle daemon while doing it.
func GateState(st State) Decision {
	if st.Paused || st.PausedIndefinitely {
		return Decision{SkipReason: "daemon is paused; refusing to stop/start it (a mutating live test would resume capture on a paused user)"}
	}
	return Decision{Run: true}
}

// capturing reports whether this state means capture was asked for.
// `starting` counts: the bring-up is underway and reading it as "not
// capturing" would make a restore stop a daemon that was coming up.
func capturing(st State) bool {
	return st.Recording || st.Status == "recording" || st.Status == "starting"
}

// RestoreCommands returns the commands that put the daemon back into the
// state a test found it in. Symmetric on purpose: a test that found the
// daemon idle and left it recording has to undo that too, or the suite is
// still not state-preserving.
func RestoreCommands(before, now State) []daemon.Command {
	switch {
	case capturing(before) && !capturing(now):
		return []daemon.Command{{Cmd: "start"}}
	case !capturing(before) && capturing(now):
		return []daemon.Command{{Cmd: "stop"}}
	}
	return nil
}

// StateFromResponse reads a `status` response. The pause pointers are
// absent on a daemon built before U10, and a nil pointer reads as false —
// treating "field missing" as "paused" would skip every live test forever.
func StateFromResponse(resp daemon.Response) State {
	deref := func(b *bool) bool { return b != nil && *b }
	return State{
		Status:             resp.Status,
		Recording:          deref(resp.Recording),
		Paused:             deref(resp.Paused),
		PausedIndefinitely: deref(resp.PausedIndefinitely),
	}
}

// Status reads the daemon's current state.
func Status(c *daemon.Client) (State, error) {
	resp, err := c.SendCommand(daemon.Command{Cmd: "status"})
	if err != nil {
		return State{}, err
	}
	return StateFromResponse(resp), nil
}

// Require gates a mutating live-daemon test and returns a connected
// client, skipping the test if it must not run. The daemon's state is
// captured now and restored in t.Cleanup.
func Require(t *testing.T) *daemon.Client {
	t.Helper()

	sockPath := daemon.SocketPath()
	_, statErr := os.Stat(sockPath)
	if d := GateEnvironment(statErr == nil, os.Getenv(EnvVar) == "1"); !d.Run {
		t.Skip(d.SkipReason)
	}

	client, err := daemon.Connect(sockPath)
	if err != nil {
		t.Fatalf("livetest: connect: %v", err)
	}
	// Registered first so it runs last: the restore below needs a live
	// connection.
	t.Cleanup(func() { _ = client.Close() })

	before, err := Status(client)
	if err != nil {
		t.Fatalf("livetest: read status: %v", err)
	}
	if d := GateState(before); !d.Run {
		t.Skip(d.SkipReason)
	}

	t.Cleanup(func() { restore(t, client, before) })
	return client
}

// restore puts the daemon back the way Require found it, and verifies it.
// Failures are loud: a restore that quietly did not happen is exactly the
// invisible stall that #110 was.
func restore(t *testing.T, c *daemon.Client, before State) {
	t.Helper()

	now, err := Status(c)
	if err != nil {
		t.Errorf("livetest: cannot read status to restore daemon to %q: %v", before.Status, err)
		return
	}

	for _, cmd := range RestoreCommands(before, now) {
		resp, err := c.SendCommand(cmd)
		if err != nil {
			t.Errorf("livetest: %q while restoring daemon from %q to %q: %v",
				cmd.Cmd, now.Status, before.Status, err)
			return
		}
		if !resp.OK {
			t.Errorf("livetest: %q while restoring daemon from %q to %q: %s",
				cmd.Cmd, now.Status, before.Status, resp.Error)
			return
		}
	}

	after, err := Status(c)
	if err != nil {
		t.Errorf("livetest: cannot confirm daemon was restored to %q: %v", before.Status, err)
		return
	}
	if capturing(after) != capturing(before) {
		t.Errorf("livetest: daemon not restored: found %q at start, left it %q", before.Status, after.Status)
	}
}

// EnsureIdle stops the daemon so a test can `start` from a known state.
//
// `start` against a recording daemon fails, and `go test ./...` runs
// packages against the one shared daemon, so whether a live test found it
// idle used to depend on what another package had done moments earlier
// (#87). Stopping first makes the suite order-independent.
//
// This is NOT safe to call on its own, which is what the comment here used
// to claim. Under always-on recording (#32) a `stop` ends capture until
// something explicitly starts it again. It is safe here only because
// Require has already gated the test and registered the restore.
func EnsureIdle(t *testing.T, client *daemon.Client) {
	t.Helper()
	if _, err := client.SendCommand(daemon.Command{Cmd: "stop"}); err != nil {
		t.Fatalf("EnsureIdle stop: %v", err)
	}
}
