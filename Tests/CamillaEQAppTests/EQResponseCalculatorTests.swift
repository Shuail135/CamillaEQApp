import XCTest
@testable import CamillaEQApp

final class EQResponseCalculatorTests: XCTestCase {
    func testGainAtBandCenterIncludesFilterAndPreamp() {
        let parsed = ParsedEQ(
            preampDB: -3,
            bands: [EQBand(kind: .peaking, frequency: 1_000, gain: 12, q: 1)],
            warnings: []
        )

        let gain = EQResponseCalculator().gainDB(
            at: 1_000,
            parsed: parsed,
            sampleRate: 48_000
        )

        XCTAssertEqual(gain, 9, accuracy: 0.001)
    }

    func testDisabledFilterDoesNotChangeVisualizerResponse() {
        let parsed = ParsedEQ(
            preampDB: -2,
            bands: [
                EQBand(
                    enabled: false,
                    kind: .peaking,
                    frequency: 1_000,
                    gain: 12,
                    q: 1
                )
            ],
            warnings: []
        )

        let gain = EQResponseCalculator().gainDB(
            at: 1_000,
            parsed: parsed,
            sampleRate: 48_000
        )

        XCTAssertEqual(gain, -2, accuracy: 0.001)
    }
}
