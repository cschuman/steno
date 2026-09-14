# Gate and restore the live-daemon tests

Closes #110.

## Why

Running the repo's own test suite turned the user's recording off.

The live tests connect to whatever daemon is installed on the machine. They
skipped only when the socket file was missing, so on any Mac where steno runs
as a launchd service they always ran, and every mutating one ended on `stop`.
Nothing started the daemon again: always-on recording (#32) has no user-facing
start, and `.idle` is a state the engine never leaves on its own.

`make test` is the documented pre-push gate. It is the single command a
contributor is most likely to run, and it was the one that silently ended
capture.

| Test | Ends on |
|---|---|
| `TestLiveTUIFlow` (`internal/app/live_test.go`) | `stop` |
| `TestDaemonCrashDuringRecording` (`internal/daemon/crash_test.go`) | `stop` |
| `TestLiveDaemonStartStop` (`internal/daemon/integration_test.go`) | `stop` |
| `TestLiveDaemonEventStream` (`internal/daemon/integration_test.go`) | `stop` |

The issue describes `TestLiveTUIFlow` as the path that reaches the bug. It is
wider than that: the whole `internal/daemon` package drives the real daemon, so
`go test -skip TestLiveTUIFlow ./...` still leaves it stopped. Measured on a
live machine before this change.

## How

Both halves of the issue's acceptance criteria, because they close different
holes.

**Gate.** A mutating live test runs only when `STENO_LIVE_TESTS=1`. `make test`
does not set it; the new `make test-live` does. This is the half that actually
makes the pre-push gate safe, since it does not depend on cleanup running.

**Restore.** `livetest.Require(t)` reads `status` up front and puts it back in
`t.Cleanup`, symmetrically: it starts a daemon the test left stopped, and stops
one the test left running. It then re-reads `status` to confirm, and fails the
test if the daemon is not where it was found. A restore that quietly did not
happen is the same invisible stall as the original bug.

**Paused is off limits.** A case the issue does not mention. `ensureIdle`'s
`stop` clears the engine's in-memory pause markers while leaving the persisted
pause anchor on the session row, so the stop/start sequence would resume
capture on someone who explicitly asked not to be recorded, and would look like
an ordinary idle daemon while doing it. The gate skips instead.

**The stale comment.** `ensureIdle` moved to `livetest.EnsureIdle` and its doc
comment no longer claims "sending `stop` is safe whether or not anything is
recording." That was true before #32 and is the assumption the whole bug rests
on.

## Key decisions

- **Gate and restore, not one or the other.** The restore is best-effort by
  nature: it cannot run if the process is killed, and it cannot resurrect the
  session the test closed. The gate is what makes `make test` safe.
- **Skip on paused rather than restore the pause.** Restoring would still
  record during the test window, which is what pause exists to prevent.
- **Loud restore failures.** `t.Errorf` naming the state it could not restore.
- **The read-only smoke test stays ungated**, so `make test` keeps proving the
  socket protocol works against a real daemon.
- **New `internal/livetest` package.** The gate and the restore are one policy
  used by two packages, and duplicating privacy-critical logic is how the two
  copies drift. It also forced the two mutating daemon tests into the external
  test package (`package daemon_test`): `livetest` imports `internal/daemon`,
  so a file in `package daemon` importing it is an import cycle. `derefBool` /
  `derefInt` are duplicated there for the same reason — `smoke_test.go` is
  still in `package daemon` and needs the originals.

## Testing

Twelve unit tests for the pure policy in `internal/livetest`: the gate
(no socket, no opt-in, opted in), the paused cases including a
`pausedIndefinitely` daemon whose status still reads `idle`, restore in both
directions, restore as a no-op when the state already matches, `starting`
counting as capture, and `StateFromResponse` tolerating the nil pause pointers
a pre-U10 daemon sends.

Verified against the live daemon on this machine:

- `go test ./...` with no env var: four mutating tests skip, the read-only one
  passes, and the recorder stayed on the same session throughout (segments
  196 → 202).
- `STENO_LIVE_TESTS=1`: tests ran, and the daemon came back recording with its
  power assertion held.
- Paused daemon plus `STENO_LIVE_TESTS=1`: both mutating tests skipped with the
  pause intact.

## What this does not close

- A daemon stopped by something else still needs #111 (PR #113) to come back.
  This stops the test suite from being the thing that stops it.
- `make test-live` still interrupts capture, by design. The session it closes
  stays closed.
