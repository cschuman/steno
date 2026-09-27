# Retry recovery from `.error` on a timer and on device changes

Refs #109, #112, #118.

## Why

The always-on plan (`docs/plans/2026-04-25-001-feat-always-on-recording-plan.md`,
"Engine-state recovery from `error`") lists three triggers that re-enter
`recording` from `error`:

1. "User toggle": "any `pause` or `resume` command from the TUI clears the
   error state and re-attempts the pipeline."
2. "External stimulus": "AVAudioEngine `configurationChangeNotification` (a
   new device, a re-plugged mic) triggers a re-attempt."
3. "Periodic re-attempt": "a coarse 60-second interval timer attempts a
   single restart from `error` state", "bounded by U5's `BackoffPolicy`".
   "The interval is configurable (`error_recovery_interval_secs`, default
   60)."

Trigger 1 already existed. #112 added a fourth path, wake. This change adds
triggers 2 and 3.

One difference from the plan: there, trigger 3 is "bounded by U5's
`BackoffPolicy`". Here every attempt is a full rebuild with fresh backoff
budgets, as a wake is, and the bound is one attempt per interval, shared by
both triggers.

U5 cannot clear `.error` by itself. Once a source's `BackoffPolicy` is
exhausted it stays exhausted until something replaces it, and only a full
rebuild (`start`, `resume`, a wake) does that. So a U5 surrender that happened
while the Mac stayed awake left the daemon dark until a client happened to
send `start`.

In this code base trigger 2 arrives through `AudioDeviceObserver`, which
debounces `AVAudioEngine.configurationChangeNotification` bursts (250 ms) and
then calls `handleAudioDeviceChange`. In `.error` that reached
`scheduleMicRestart`, but `beginRecovering` and `maybeRestoreRecordingStatus`
both refuse to act from `.error`, so the trigger could only re-surrender,
emitting another `recoveryExhausted` and changing nothing.

## What changed

- **Timer.** Entering `.error` arms a loop that sleeps for the configured
  interval and then makes one recovery attempt. Leaving `.error` for any
  reason cancels it. It is re-armed after a wake that ends in `.error`.
- **Device change.** In `.error`, `handleAudioDeviceChange` makes a recovery
  attempt straight away instead of scheduling a U5 restart.
- **One rebuild path.** The wake rebuild is factored into `rebuildAfterGap`,
  which the wake handler and both new triggers share. It resets both
  backoff budgets, applies the U6 heal rule to the time spent in `.error`
  (reuse the session under the heal threshold, roll it over above it), and
  emits `recovering:` with `error-recovery:timer:gap=Ns` or
  `error-recovery:device-change:gap=Ns`. A bring-up that succeeds claims
  `.recording` through the existing `errorEpoch` rule from #112, so the power
  assertion is re-taken the normal way.
- **A failed rebuild keeps the anchor.** A failed bring-up runs `cleanup()`,
  which drops `currentSession`. With the interval above 0, the rebuild now
  puts the session back, so the next attempt has something to recover into.
  This applies to a failed wake rebuild too. With the interval at 0 a failed
  wake behaves exactly as before.
- **`stop()` works from `.error`.** It used to return without doing anything
  there. With retries running, an ignored stop would let the next attempt
  start recording. It now closes the session row and returns to `.idle`.

## Safety rules

- **Permission gate.** A surrender caused by a revoked microphone or
  screen-recording grant blocks the timer. Retrying a revoked TCC grant every
  minute would not help. A device change still attempts, because it is new
  evidence.
- **Mic preflight.** Each attempt first reads the microphone permission
  (this never prompts). A denied grant means no attempt.
- **One attempt per interval**, shared by both triggers, so a burst of
  device notifications cannot become a retry storm.
- **No anchor, no retry.** An `.error` with no `currentSession` (a failure
  inside `start` that ran `cleanup`) has nothing to recover into, and the
  triggers leave it alone. An explicit `start` is still required there.
- **Lifecycle commands.** No attempt starts while `start`, `stop`, `pause`,
  `resume` or system sleep is running. `start`, `stop`, `pause` and sleep
  also cancel an attempt that is already running and wait for it to finish
  before they act. Every command that arrives while an attempt is running
  waits for that same attempt, concurrent commands included (socket
  commands run concurrently), and an attempt cancelled before its rebuild
  skips the rebuild. Waiting alone was not enough: a device-change attempt
  could slip in while the command was suspended in that wait or in its
  teardown, and its bring-up would then claim `.recording` after the command
  had finished. Only a command that acts counts as a lifecycle change for
  the anchor restore, so a rejected `start` or `resume` during a failing
  wake rebuild does not cost that rebuild its anchor.

## Setting

`errorRecoveryIntervalSeconds` in `settings.json`, the plan's
`error_recovery_interval_secs`. Default 60. `0` or a negative value turns off
both new triggers and the anchor restore after a failed rebuild. `stop()`
works from `.error` at every interval. A settings file written before this
key existed decodes to the default.

## Testing

`ErrorRecoveryTests` (30 tests) drives the timer with a hand-fired sleep and
a hand-advanced clock:

- timer recovery of a U5 surrender (same session, assertion re-taken);
- the loop sleeps for the configured interval;
- a hard-down source gets one bounded attempt per firing;
- the permission gate, the mic preflight, and interval 0 (no timer, and a
  failed wake leaves no session);
- `stop` and `pause` from `.error`; sleep cancels the loop and wake re-arms it;
- rollover past the heal threshold; a failed attempt keeps the anchor;
  no attempt without an anchor;
- device change recovers at once, is rate limited, and still attempts after a
  permission surrender;
- `stop`, `pause` and `start` racing an attempt parked mid-bring-up, with a
  check of the live mic pipelines afterwards (none after `stop` or `pause`,
  exactly one after `start`);
- a device change arriving while `stop`, `pause` or sleep waits for the
  timer's attempt, and a device change during `pause`'s teardown: none of
  them may start capture;
- a failed wake rebuild after `stop` does not restore the anchor;
- two lifecycle commands overlapping one attempt parked mid-bring-up
  (`start` then `stop`, `stop` then `start`, sleep then `stop` then wake):
  the second command waits for the attempt, and afterwards a mic is live only
  if the engine is recording;
- an attempt cancelled during its teardown opens no mic;
- a `start` or `resume` rejected during a failing wake rebuild does not cost
  the rebuild its anchor.

Each test that fires the timer to show nothing happens first checks whether
the loop is sleeping, so the firing is not vacuous. `StenoSettingsTests`
covers the default, the round trip, a file without the key, and `0`.

`make test` passes: 599 daemon tests, 0 failures; Go packages ok; app suite
43 tests in 6 suites.

## Known limitations

A command that lands while a bring-up is suspended mid-flight can be
overtaken by that bring-up's tail. A `stop()` or `pause()` during a wake or
resume bring-up, or a `stop()` during `start()`'s, ends with the tail
setting `.recording`. A sleep and wake during `start()`'s bring-up leave two
mic pipelines running. All of these also happen with the interval at 0, so
they are not caused by this change, and it does not fix them. The
error-recovery path avoids them by making those callers wait for the
attempt, and the generation guard keeps them from turning into a timer
retry. The general fix belongs in `bringUpPipelines`, for all callers.

A related case: when `start()` and `stop()` both wait for the same attempt,
the order in which they then run is not guaranteed, so a `start()` sent
just before a `stop()` can still end up recording.
