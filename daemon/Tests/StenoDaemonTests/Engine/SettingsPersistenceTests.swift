import Testing
import Foundation
@testable import StenoDaemon

/// #116 — a successful `start(...)` persists the last-known audio config.
/// That write used to go through `StenoSettings.load()` / `save()`, which
/// were hardcoded to `~/Library/Application Support/Steno/settings.json`,
/// so every engine unit test that started recording rewrote the real
/// settings file of whoever ran the suite. The engine now writes through
/// an injected `SettingsStoring`, and has no store at all unless one is
/// passed.
@Suite("Settings Persistence Tests")
struct SettingsPersistenceTests {

    @MainActor
    private func makeEngine(
        settingsStore: (any SettingsStoring)? = nil
    ) -> (engine: RecordingEngine, delegate: MockRecordingEngineDelegate) {
        let repo = MockTranscriptRepository()
        let delegate = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: MockSpeechRecognizerFactory(),
            delegate: delegate,
            settingsStore: settingsStore,
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
        )
        return (engine, delegate)
    }

    @Test func aSuccessfulStartPersistsTheAudioConfigToTheInjectedStore() async throws {
        let store = MockSettingsStore(stored: StenoSettings(healGapSeconds: 42))
        let (engine, _) = await makeEngine(settingsStore: store)

        _ = try await engine.start(locale: Locale(identifier: "en_US"), device: "Studio Mic")
        await engine.stop()

        #expect(store.saves.count == 1)
        #expect(store.saves.last?.lastDevice == "Studio Mic")
        #expect(store.saves.last?.lastSystemAudioEnabled == false)
        // Load-mutate-save: the fields the engine does not own survive.
        #expect(store.saves.last?.healGapSeconds == 42)
    }

    @Test func anUnreadableSettingsFileSkipsTheSaveInsteadOfOverwritingIt() async throws {
        let store = MockSettingsStore(stored: StenoSettings(healGapSeconds: 42))
        store.loadError = MockSettingsStore.InjectedError("unreadable")
        let (engine, delegate) = await makeEngine(settingsStore: store)

        _ = try await engine.start(locale: Locale(identifier: "en_US"), device: "Studio Mic")
        await engine.stop()

        // The old code returned defaults on any read failure and then wrote
        // them back, so an unreadable file was replaced by defaults. Skip
        // the write and report it instead.
        #expect(store.saveCount == 0)
        #expect(store.stored.healGapSeconds == 42)

        let errors = await delegate.errors
        #expect(errors.contains { $0.0.contains("settings") && $0.1 })
    }

    @Test func aFailedSaveIsReportedButDoesNotStopRecording() async throws {
        let store = MockSettingsStore()
        store.saveError = MockSettingsStore.InjectedError("read-only volume")
        let (engine, delegate) = await makeEngine(settingsStore: store)

        _ = try await engine.start(locale: Locale(identifier: "en_US"))

        #expect(await engine.status == .recording)
        let errors = await delegate.errors
        #expect(errors.contains { $0.1 })  // transient, not fatal

        await engine.stop()
    }

    @Test func anEngineWithNoStoreLeavesTheRealSettingsFileAlone() async throws {
        // The acceptance criterion for #116. Every other engine test in the
        // suite builds its engine without a settings store, exactly as this
        // one does, so this stands in for all of them.
        //
        // Compares bytes rather than mtime on purpose: the always-on daemon
        // may legitimately rewrite its own settings while the suite runs,
        // and an identical rewrite is not a failure. A default-constructed
        // engine writing through would change the content (or create the
        // file where none existed), which is what this catches.
        let url = DaemonPaths.settingsURL
        let before = try? Data(contentsOf: url)

        let (engine, _) = await makeEngine()
        _ = try await engine.start(locale: Locale(identifier: "en_US"), device: "Studio Mic")
        await engine.stop()

        let after = try? Data(contentsOf: url)
        #expect(before == after)
    }
}
