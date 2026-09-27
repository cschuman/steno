import Testing
import Foundation
@testable import StenoDaemon

@Suite("StenoSettings Tests")
struct StenoSettingsTests {

    // MARK: - errorRecoveryIntervalSeconds (#109)

    @Test func errorRecoveryIntervalDefaultsToSixtyWhenAbsent() throws {
        // A settings file written before the timer existed must pick up
        // the plan's default rather than decoding to 0 (which would
        // silently disable automatic recovery on upgrade).
        let json = """
        {"summarizationProvider":"local","anthropicModel":"m","lastSystemAudioEnabled":true,
         "healGapSeconds":30,"retentionDays":0}
        """
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: Data(json.utf8))
        #expect(decoded.errorRecoveryIntervalSeconds == 60)
    }

    @Test func errorRecoveryIntervalDefaultsToSixtyInMemberwiseInit() {
        #expect(StenoSettings().errorRecoveryIntervalSeconds == 60)
    }

    @Test func errorRecoveryIntervalRoundTrips() throws {
        let settings = StenoSettings(errorRecoveryIntervalSeconds: 120)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: data)
        #expect(decoded.errorRecoveryIntervalSeconds == 120)
    }

    @Test func errorRecoveryIntervalZeroDecodesAsZero() throws {
        // `0` is the documented off switch, so it must survive decoding
        // instead of being replaced by the default.
        let json = """
        {"errorRecoveryIntervalSeconds":0}
        """
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: Data(json.utf8))
        #expect(decoded.errorRecoveryIntervalSeconds == 0)
    }
}
