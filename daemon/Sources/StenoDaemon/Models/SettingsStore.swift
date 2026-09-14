import Foundation

/// Reads and writes `StenoSettings`.
///
/// Persistence used to live on `StenoSettings` itself, as `load()` / `save()`
/// statics pointed at a hardcoded `~/Library/Application Support/Steno/
/// settings.json`. Any code that persisted settings therefore wrote that one
/// real file — including the daemon's own unit tests, which rewrote the
/// settings of whoever ran the suite (#116). Behind a protocol, a caller
/// that has no business touching the user's file simply is not handed a
/// store.
public protocol SettingsStoring: Sendable {
    /// Read the stored settings.
    ///
    /// A missing file is not an error — it means "nothing saved yet, use the
    /// defaults". Anything else (unreadable, truncated, not JSON) throws, so
    /// a caller doing load-mutate-save can tell "no settings" apart from
    /// "settings I could not read" and decline to overwrite the second.
    func load() throws -> StenoSettings

    /// Replace the stored settings.
    func save(_ settings: StenoSettings) throws
}

/// The production `SettingsStoring`: a JSON file on disk.
public struct FileSettingsStore: SettingsStoring {
    /// The file this store reads and writes. Defaults to the daemon's real
    /// settings path; tests pass a temp URL.
    public let url: URL

    public init(url: URL = DaemonPaths.settingsURL) {
        self.url = url
    }

    public func load() throws -> StenoSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run: no settings file yet.
            return StenoSettings()
        }
        return try JSONDecoder().decode(StenoSettings.self, from: data)
    }

    public func save(_ settings: StenoSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(settings)
        // Atomic: the engine rewrites this file on every successful start,
        // and a plain write truncates in place. A crash or a full disk
        // partway through would leave a half-file, which `load()` now
        // (correctly) refuses to decode.
        try data.write(to: url, options: .atomic)
    }
}
