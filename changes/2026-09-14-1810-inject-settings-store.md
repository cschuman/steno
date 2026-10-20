# Put settings persistence behind an injected store (#116)

## Why

`StenoSettings` carried its own persistence: `load()` and `save()` statics
pointed at a hardcoded `~/Library/Application Support/Steno/settings.json`.
Nothing could persist settings without writing that one real file.

`RecordingEngine.persistLastKnownAudioConfig` calls both on every successful
`start()`. Every daemon unit test that starts recording therefore rewrote the
settings file of whoever ran the suite. Running `make test` on a machine with
a live install silently replaced the user's `lastDevice` and
`lastSystemAudioEnabled` with whatever the test happened to pass.

The read half was worse than the write half. `load()` caught every error and
returned defaults, so an unreadable or truncated settings file decoded to a
fresh `StenoSettings()`, and the very next `save()` wrote those defaults back
over it. A file the daemon could not read got replaced by one it could, and
the user's settings were gone with no error anywhere.

## How

A `SettingsStoring` protocol with a `FileSettingsStore` that takes the URL it
writes. `RecordingEngine` gained `settingsStore: (any SettingsStoring)? = nil`
and persists only when it has one, following the existing `dedupCoordinator`
convention: `nil` means no collaborator and the call site is a no-op.
`RunCommand` is the only production caller and passes a `FileSettingsStore`
explicitly. Tests construct engines without a store and so cannot reach the
user's file at all.

`FileSettingsStore.load()` now distinguishes the two cases the old code
collapsed. A missing file still yields defaults, because a first run has no
settings and that is not a failure. Anything else — unreadable, truncated,
not JSON — throws, and `persistLastKnownAudioConfig` skips the save and emits
a transient error instead of overwriting.

The `StenoSettings.load()` / `save()` statics are gone rather than deprecated,
so there is no second path that bypasses injection. The hardcoded path moved
to `DaemonPaths.settingsURL`, next to the database, socket and PID paths it
was duplicating.

## Key Decisions

- **Optional store, `nil` means no persistence.** The alternative shapes both
  fail: a required parameter forces edits at 30 test construction sites, and
  an optional that defaults to `FileSettingsStore()` leaves every one of those
  sites still writing the real file, which is the bug. The `dedupCoordinator`
  parameter already establishes this exact shape in this initializer.
  `powerAssertion` uses the opposite convention (`nil` means "build the
  production object"), which is why it is not the model followed here.

- **Throw on a file that exists but cannot be read.** A caller doing
  load-mutate-save needs to tell "nothing saved yet" apart from "settings I
  could not read". Only the first is safe to overwrite. Missing-file still
  returns defaults, so first-run behavior is unchanged.

- **`RunCommand` starts on defaults when the file is unreadable, and says so.**
  Refusing to start would make an unreadable settings file a total outage. It
  logs to unified logging and writes an operator-visible console line naming
  the path. The engine hits the same read error on its persistence path and
  declines to write, so the unreadable file is left intact for inspection
  rather than being replaced by the defaults the daemon booted on.

- **Atomic save.** The engine rewrites this file on every successful start and
  a plain `Data.write(to:)` truncates in place. Since `load()` now refuses to
  decode a damaged file, a half-written one would be a real fault rather than
  a silently-ignored one. This is a Foundation write option, not behavior a
  unit test can observe, and is not covered by one.

## Testing

`SettingsStoreTests` covers the store contract: round-trip through an injected
URL, missing file loads defaults without throwing, undecodable file throws
rather than returning defaults, save creates its parent directory, and the
default store still targets `DaemonPaths.settingsURL`.

`SettingsPersistenceTests` covers the engine: a successful start writes the
audio config to the injected store and preserves the fields the engine does
not own, an unreadable store skips the save entirely rather than overwriting,
and a failed save is reported as transient without stopping the recording.

The acceptance test is `anEngineWithNoStoreLeavesTheRealSettingsFileAlone`,
which compares the real settings file around a default-constructed engine's
start. It fails on the old code — that is how the regression was caught in the
first place. It compares bytes rather than mtime on purpose: an always-on
daemon may legitimately rewrite its own settings while the suite runs.

Verified end to end by hashing `~/Library/Application Support/Steno/
settings.json` around the daemon suite: hash and mtime identical before and
after. On the old code the same check fails.

[steno-tests-passed: 521 daemon tests + 43 app tests + go ./... (4 pkgs) in 36s; release build clean, no warnings]

## What's Next

`RecordingEngine.init` now takes twenty-odd parameters, most of them settings
fields unpacked one at a time by `RunCommand`. Passing the settings struct (or
a small engine-config value) would collapse that, and the store is the piece
that makes it possible. Out of scope here.

The Go live-TUI test still drives the real daemon (#110), so `make test` still
stops the user's recorder and the daemon then writes its own settings. That is
the daemon legitimately owning its file, not this bug, and it is what PR #114
addresses.
