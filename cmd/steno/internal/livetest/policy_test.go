package livetest

import (
	"strings"
	"testing"

	"github.com/jwulff/steno/internal/daemon"
)

func TestGateEnvironmentSkipsWithoutSocket(t *testing.T) {
	d := GateEnvironment(false, true)
	if d.Run {
		t.Fatal("expected skip when the socket is absent")
	}
	if !strings.Contains(d.SkipReason, "not running") {
		t.Errorf("skip reason should say the daemon is not running, got %q", d.SkipReason)
	}
}

func TestGateEnvironmentSkipsWithoutOptIn(t *testing.T) {
	d := GateEnvironment(true, false)
	if d.Run {
		t.Fatal("a live daemon alone must not be enough to run a mutating test")
	}
	// The reason has to name the variable, or the skip is a dead end for
	// whoever reads it.
	if !strings.Contains(d.SkipReason, EnvVar) {
		t.Errorf("skip reason should name %s, got %q", EnvVar, d.SkipReason)
	}
}

func TestGateEnvironmentRunsWhenOptedInWithSocket(t *testing.T) {
	if d := GateEnvironment(true, true); !d.Run {
		t.Fatalf("expected run, got skip: %q", d.SkipReason)
	}
}

func TestGateStateSkipsWhenPaused(t *testing.T) {
	// The privacy case. `stop` clears the in-memory pause markers, so a
	// mutating test that stopped and then started would record a user who
	// explicitly asked not to be recorded.
	for _, st := range []State{
		{Status: "paused", Paused: true},
		{Status: "paused", Paused: true, PausedIndefinitely: true},
		{Status: "idle", PausedIndefinitely: true},
	} {
		d := GateState(st)
		if d.Run {
			t.Errorf("expected skip for %+v", st)
		}
		if !strings.Contains(d.SkipReason, "paused") {
			t.Errorf("skip reason should say paused, got %q", d.SkipReason)
		}
	}
}

func TestGateStateRunsWhenRecordingOrIdle(t *testing.T) {
	for _, st := range []State{
		{Status: "recording", Recording: true},
		{Status: "idle"},
	} {
		if d := GateState(st); !d.Run {
			t.Errorf("expected run for %+v, got skip: %q", st, d.SkipReason)
		}
	}
}

func TestRestoreCommandsStartsWhenItFoundCapture(t *testing.T) {
	before := State{Status: "recording", Recording: true}
	now := State{Status: "idle"}
	got := RestoreCommands(before, now)
	if len(got) != 1 || got[0].Cmd != "start" {
		t.Fatalf("expected a single start, got %+v", got)
	}
}

func TestRestoreCommandsStopsWhatTheTestLeftRunning(t *testing.T) {
	// A test that found the daemon idle and left it recording has to put
	// that back too, or the suite is still not state-preserving.
	before := State{Status: "idle"}
	now := State{Status: "recording", Recording: true}
	got := RestoreCommands(before, now)
	if len(got) != 1 || got[0].Cmd != "stop" {
		t.Fatalf("expected a single stop, got %+v", got)
	}
}

func TestRestoreCommandsIsEmptyWhenStateMatches(t *testing.T) {
	for _, st := range []State{
		{Status: "recording", Recording: true},
		{Status: "idle"},
	} {
		if got := RestoreCommands(st, st); len(got) != 0 {
			t.Errorf("expected no commands for %+v, got %+v", st, got)
		}
	}
}

func TestRestoreCommandsTreatsStartingAsCapture(t *testing.T) {
	// `starting` is capture that has been asked for. Reading it as "not
	// capturing" would make the restore stop a daemon that was coming up.
	before := State{Status: "starting"}
	now := State{Status: "recording", Recording: true}
	if got := RestoreCommands(before, now); len(got) != 0 {
		t.Errorf("expected no commands, got %+v", got)
	}
}

func TestStateFromResponseReadsOptionalFields(t *testing.T) {
	yes, no := true, false
	resp := daemon.Response{
		OK:                 true,
		Status:             "paused",
		Recording:          &no,
		Paused:             &yes,
		PausedIndefinitely: &yes,
	}
	st := StateFromResponse(resp)
	if st.Status != "paused" || st.Recording || !st.Paused || !st.PausedIndefinitely {
		t.Fatalf("unexpected state: %+v", st)
	}
}

func TestStateFromResponseToleratesNilPointers(t *testing.T) {
	// A daemon built before U10 omits the pause fields entirely. Reading
	// that as "paused" would skip every live test forever.
	st := StateFromResponse(daemon.Response{OK: true, Status: "idle"})
	if st.Recording || st.Paused || st.PausedIndefinitely {
		t.Fatalf("nil pointers should read as false, got %+v", st)
	}
}
