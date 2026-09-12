# Recover from `.error` when a wake rebuild succeeds

Fixes #109.

## Why

`.error` was an absorbing state. `setStatus(.recording)` exists at exactly two
call sites in the daemon and both were gated on the status not already being
`.error`:

| Site | Guard |
|---|---|
| tail of `bringUpPipelines` | `if status != .error` |
| `maybeRestoreRecordingStatus` | `if status == .error { return }` |

None of the five surrender paths clears `currentSession`, so after a surrender
the engine holds a live session in `.error`. `handleSystemWillSleep` declines to
move off `.error`, and on wake `handleSystemDidWake` passes its three early
exits, emits `recovering:`, and calls `bringUpPipelines` — **which genuinely
succeeds. Audio and transcription resume.** The tail guard then blocks the
status transition.

Three things follow from that one blocked transition:

1. The `status` command keeps answering `"error"` on every poll, so the display
   is wrong for as long as the daemon runs.
2. No `setStatus` means no `.statusChanged`, so no `event:"status"` on the wire,
   so no connected client can correct itself either.
3. `powerAssertion.acquire()` has exactly one call site — inside `setStatus`, on
   entry to `.recording`. It is never re-taken, so the Mac is free to sleep
   again while the engine believes it is capturing. That is the reason the state
   survives for days rather than until the next user interaction: every
   subsequent sleep/wake re-runs the same cycle.

Also silently disabled for the duration: the #104 silence watchdog, which is
gated on `status == .recording`.

## How

A completed `bringUpPipelines` is positive evidence that the pipelines are up.
The guard exists so a bring-up cannot paper over a *concurrent* surrender —
`handleSystemAudioBringUpFailure` awaits `handleSystemAudioPermissionRevoked()`,
which sets `.error` inline before `startSystemAudio` returns — and that intent
is preserved, not removed.

The status alone cannot separate the two cases, because a second surrender does
not move a status that already reads `.error`. So the engine now counts
surrenders: `errorEpoch` is bumped by `setStatus` on every entry into `.error`,
`bringUpPipelines` captures it on entry, and the tail claims `.recording` only
if the count is unchanged.

- entered clean, surrendered during the bring-up → epoch moved → stay `.error`
  (the behaviour the guard was added for, preserved)
- entered surrendered, rebuild completed → epoch unchanged → `.recording`
  (the wake path, previously blocked)
- entered surrendered, surrendered again → epoch moved → stay `.error`
  (a status comparison could not see this at all)

`handleSystemDidWake` also resets the per-source `BackoffPolicy` objects before
rebuilding, as `start()` and `resume()` already do. A wake is a full rebuild and
gets a full retry budget; without it, the first post-wake hiccup short-circuits
straight back to `recoveryExhausted` against a budget spent before the sleep.

Client side, both UIs cleared a `healed:` only from `recovering`, never from
`error` — the same shape in two languages. A heal that completes after a
surrender is exactly the evidence the surrender is over, so both now clear from
either state and drop the stale error text with it.

## Key Decisions

- **Count surrenders, don't compare status.** An entry/exit status comparison
  would have been simpler but cannot distinguish a fresh surrender from an
  inherited one when both read `.error`.
- **`currentSession` is retained on surrender, deliberately.** Clearing it would
  make the state tidier but would make the engine *unrecoverable*: the wake
  handler needs the session to rebuild around, and nilling it would send it out
  the `guard let session` early exit instead. The invariant is now documented on
  the property rather than left implicit.
- **`maybeRestoreRecordingStatus`'s guard is left alone.** Its `.error` check is
  doing different work: it runs after a *single source* finishes restarting, and
  the other source may have surrendered permanently in the meantime. A mic
  restart completing is not evidence that a revoked screen-recording grant is
  resolved.
- **The plan's trigger #3 (`error_recovery_interval_secs`) is not implemented
  here.** The root cause is not a missing timer, it is a rebuild that succeeds
  and is not allowed to say so. A periodic re-attempt is a separate feature with
  its own config surface and its own failure mode — retry storms against a
  permanently revoked TCC grant, which is the most common surrender cause — and
  it deserves its own change rather than riding along with a regression fix.

## Testing

Two tests in `SleepWakeHandlerTests`, covering both directions of the rule:

- `wakeOutOfErrorRestoresRecordingAndPowerAssertion` — surrender via a revoked
  screen-recording grant, resolve it across the sleep, wake, and assert the
  status is back at `.recording` **and** the power assertion was re-acquired.
  Verified to fail against the old guard (3 failed expectations) and pass with
  the fix.
- `wakeOutOfErrorIntoAnotherSurrenderStaysInError` — the grant is still revoked
  across the sleep, so the rebuild surrenders a second time and the engine must
  stay in `.error` with no assertion held.

`make test` passes: daemon 0 failures, `go test -p 1 ./...` 193 tests across 7
packages, app suite 43 tests in 6 suites.

[steno-tests-passed: 514 tests in 99s]

## What's Next

Adjacent holes this does not close, each worth its own change:

- `handleAudioDeviceChange` can reach `scheduleMicRestart` from `.error`, but
  `beginRecovering` and `maybeRestoreRecordingStatus` both refuse to act from
  it, so the plan's trigger #2 remains inert.
- `handleDisplayBecameAvailable` still refuses to re-arm parked system audio
  from `.error`.
- A surrender that happens with no `currentSession` (during `start`/`cleanup`)
  still has no autonomous recovery; an explicit `start` is required.
