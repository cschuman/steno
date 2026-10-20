import Testing
import Foundation
@testable import StenoDaemon

/// #116 — `StenoSettings` used to carry its own `load()` / `save()` statics
/// pointed at a hardcoded real path, so anything that persisted settings
/// wrote the user's file. Persistence now lives behind `SettingsStoring`,
/// and `FileSettingsStore` takes the URL it writes.
@Suite("SettingsStore Tests")
struct SettingsStoreTests {

    /// A unique empty directory. Callers `defer` the removal.
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func roundTripsThroughTheInjectedURL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileSettingsStore(url: dir.appendingPathComponent("settings.json"))
        try store.save(StenoSettings(lastDevice: "Studio Mic", lastSystemAudioEnabled: false, healGapSeconds: 42))

        let loaded = try store.load()
        #expect(loaded.lastDevice == "Studio Mic")
        #expect(loaded.lastSystemAudioEnabled == false)
        #expect(loaded.healGapSeconds == 42)
    }

    @Test func aMissingFileLoadsDefaultsWithoutThrowing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Nothing written yet: a first run has no settings file, and that
        // is not an error — it means "use the defaults".
        let store = FileSettingsStore(url: dir.appendingPathComponent("settings.json"))
        let loaded = try store.load()

        #expect(loaded.healGapSeconds == StenoSettings().healGapSeconds)
        #expect(loaded.lastDevice == nil)
    }

    @Test func aFileThatCannotBeDecodedThrowsRatherThanReturningDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("settings.json")
        try Data("{ this is not settings json".utf8).write(to: url)

        // The old `load()` swallowed every error and returned defaults, so
        // a load-mutate-save cycle over an unreadable file replaced the
        // user's settings with defaults. Throwing lets the caller skip the
        // save and leave the file alone.
        let store = FileSettingsStore(url: url)
        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test func saveCreatesTheParentDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("settings.json")
        let store = FileSettingsStore(url: url)

        try store.save(StenoSettings(lastDevice: "Built-in"))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try store.load().lastDevice == "Built-in")
    }

    @Test func theDefaultStoreTargetsTheDaemonSettingsPath() {
        // Reads a URL only — touches no file. If this ever drifts, the
        // daemon silently stops seeing the settings the user edits.
        #expect(FileSettingsStore().url == DaemonPaths.settingsURL)
        #expect(DaemonPaths.settingsURL.lastPathComponent == "settings.json")
        #expect(DaemonPaths.settingsURL.deletingLastPathComponent() == DaemonPaths.baseDirectory)
    }
}
