import Testing
import Foundation
@testable import StenoDaemon

/// Tests for the shipped defaults in `StenoSettings`.
///
/// Defaults matter more than they look: `healGapSeconds` is read once at
/// daemon start and decides whether a sleep/wake cycle keeps recording
/// into the same session or opens a new one. It was duplicated in three
/// places (the memberwise init, the decoder fallback, and
/// `RecordingEngine`'s own init default), so these tests pin the value
/// to one named constant.
@Suite("StenoSettings Defaults")
struct StenoSettingsTests {

    // MARK: - Heal-gap default

    @Test("Default heal gap is 5 minutes")
    func defaultHealGapIsFiveMinutes() {
        #expect(StenoSettings.defaultHealGapSeconds == 300)
        #expect(StenoSettings().healGapSeconds == StenoSettings.defaultHealGapSeconds)
    }

    @Test("A settings file with no healGapSeconds key gets the current default")
    func absentHealGapKeyDecodesToTheDefault() throws {
        let json = """
        {"summarizationProvider":"local","anthropicModel":"m","lastSystemAudioEnabled":false}
        """
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: Data(json.utf8))
        #expect(decoded.healGapSeconds == StenoSettings.defaultHealGapSeconds)
    }

    @Test("An explicit healGapSeconds is never overridden by the default")
    func explicitHealGapWins() throws {
        // Every install that has ever recorded has a complete settings.json
        // on disk, because a successful start persists the whole struct. So
        // raising the default only reaches fresh installs — an existing file
        // pinned at 30 keeps 30, which is also what makes a deliberate user
        // choice stick.
        let json = """
        {"summarizationProvider":"local","anthropicModel":"m",
         "lastSystemAudioEnabled":false,"healGapSeconds":30}
        """
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: Data(json.utf8))
        #expect(decoded.healGapSeconds == 30)
    }

    @Test("Heal gap survives an encode/decode round trip")
    func healGapRoundTrips() throws {
        let settings = StenoSettings(healGapSeconds: 90)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: data)
        #expect(decoded.healGapSeconds == 90)
    }

    // MARK: - The rule sees the default

    @Test("At the default threshold, a 4-minute gap heals and a 5-minute gap rolls over")
    func defaultThresholdBoundary() {
        let fourMinutes = HealRule.decide(
            gap: 240,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: StenoSettings.defaultHealGapSeconds
        )
        #expect(fourMinutes == .reuseSession(healMarker: "after_gap:240s"))

        let fiveMinutes = HealRule.decide(
            gap: 300,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: StenoSettings.defaultHealGapSeconds
        )
        #expect(fiveMinutes == .rollover)
    }
}
