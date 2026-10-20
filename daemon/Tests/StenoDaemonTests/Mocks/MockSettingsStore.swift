import Foundation
@testable import StenoDaemon

/// Test double for `SettingsStoring`. Holds settings in memory so a test
/// that exercises the daemon's persistence path never reaches the user's
/// real `~/Library/Application Support/Steno/settings.json` (#116).
/// Mirrors the codebase's `@unchecked Sendable` mock style (mutable config
/// touched serially by tests).
final class MockSettingsStore: SettingsStoring, @unchecked Sendable {
    /// Test-only error used by the throw-injection knobs.
    struct InjectedError: Error, Equatable {
        let message: String
        init(_ message: String = "injected") { self.message = message }
    }

    /// What `load()` returns when `loadError` is nil, and where a
    /// successful `save(_:)` lands.
    var stored: StenoSettings

    /// When set, `load()` throws this instead of returning `stored`.
    /// Stands in for a settings file that exists but cannot be read or
    /// decoded — the case where writing defaults back would destroy data.
    var loadError: Error?

    /// When set, `save(_:)` throws this instead of recording the write.
    var saveError: Error?

    private(set) var loadCount = 0
    private(set) var saveCount = 0

    /// Every settings value handed to `save(_:)`, in call order.
    private(set) var saves: [StenoSettings] = []

    init(stored: StenoSettings = StenoSettings()) {
        self.stored = stored
    }

    func load() throws -> StenoSettings {
        loadCount += 1
        if let loadError { throw loadError }
        return stored
    }

    func save(_ settings: StenoSettings) throws {
        saveCount += 1
        if let saveError { throw saveError }
        saves.append(settings)
        stored = settings
    }
}
