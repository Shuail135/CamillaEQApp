import XCTest
@testable import CamillaEQApp

final class EqualizerAPOParserTests: XCTestCase {
    func testImportsEveryGraphicalFilterKindAndPreservesOff() throws {
        let parsed = try EqualizerAPOParser().parse("""
        Preamp: -4.0 dB
        Filter 1: OFF PEQ Fc 100 Hz Gain -2.0 dB BW Oct 1.0
        Filter 2: ON LSC Fc 120 Hz Gain 3.0 dB Q 0.70
        Filter 3: ON HSC Fc 9000 Hz Gain -1.5 dB Q 0.80
        Filter 4: ON LP Fc 18000 Hz
        Filter 5: ON HPQ Fc 25 Hz Q 0.60
        Filter 6: ON NO Fc 60 Hz Q 8.0
        Filter 7: ON AP Fc 1000 Hz Q 0.707
        """)

        XCTAssertEqual(parsed.preampDB, -4.0)
        XCTAssertEqual(parsed.bands.map(\.kind), [
            .peaking, .lowShelf, .highShelf, .lowPass, .highPass, .notch, .allPass
        ])
        XCTAssertFalse(parsed.bands[0].enabled)
        XCTAssertTrue(parsed.bands.dropFirst().allSatisfy(\.enabled))
        XCTAssertEqual(parsed.bands[0].q ?? 0, 1.0 / (2.0 * sinh(log(2.0) / 2.0)), accuracy: 0.000_001)
    }

    func testImportsTenBandLSCAndHSCPreset() throws {
        let parsed = try EqualizerAPOParser().parse("""
        Preamp: -2.50 dB
        Filter 1: ON LSC Fc 105.0 Hz Gain 0.7 dB Q 0.70
        Filter 2: ON PK Fc 271.5 Hz Gain 0.7 dB Q 1.01
        Filter 3: ON PK Fc 602.4 Hz Gain 2.3 dB Q 0.60
        Filter 4: ON PK Fc 1210.9 Hz Gain -0.7 dB Q 2.38
        Filter 5: ON PK Fc 1737.1 Hz Gain -3.6 dB Q 2.32
        Filter 6: ON PK Fc 2474.2 Hz Gain 2.6 dB Q 2.94
        Filter 7: ON PK Fc 3562.9 Hz Gain 2.1 dB Q 4.57
        Filter 8: ON PK Fc 4668.9 Hz Gain -2.8 dB Q 2.84
        Filter 9: ON PK Fc 7211.6 Hz Gain -5.3 dB Q 4.90
        Filter 10: ON HSC Fc 10000.0 Hz Gain 0.9 dB Q 0.70
        """)

        XCTAssertEqual(parsed.preampDB, -2.5)
        XCTAssertEqual(parsed.bands.count, 10)
        XCTAssertEqual(parsed.bands.first?.kind, .lowShelf)
        XCTAssertEqual(parsed.bands.last?.kind, .highShelf)
        XCTAssertTrue(parsed.bands.allSatisfy(\.enabled))
    }
}
