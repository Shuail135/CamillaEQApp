import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: String          // CoreAudio UID
    let objectID: UInt32
    let name: String

    static let blackHoleName = "BlackHole 2ch"
}

struct DeviceProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var outputDeviceUID: String
    var outputDeviceName: String
    var autoActivate: Bool = false
    // Optional keeps profiles written by earlier app versions decodable.
    var autoActivateWhenBlackHoleSelected: Bool? = true
    var lockOutputVolume: Bool = false
    var outputVolumeScalar: Double = 0.0625
    var sampleRate: Int = 48_000
    var chunkSize: Int = 1024
    var equalizerAPOText: String = """
Preamp: 0.0 dB
Filter 1: ON LS Fc 31 Hz Gain 0.0 dB Q 1.00
Filter 2: ON PK Fc 76 Hz Gain 0.0 dB Q 1.00
Filter 3: ON PK Fc 184 Hz Gain 0.0 dB Q 1.00
Filter 4: ON PK Fc 447 Hz Gain 0.0 dB Q 1.00
Filter 5: ON PK Fc 1087 Hz Gain 0.0 dB Q 1.00
Filter 6: ON PK Fc 2643 Hz Gain 0.0 dB Q 1.00
Filter 7: ON PK Fc 6423 Hz Gain 0.0 dB Q 1.00
Filter 8: ON HS Fc 16000 Hz Gain 0.0 dB Q 1.00
"""
}

struct EQBand: Identifiable, Hashable {
    enum Kind: String, Hashable, CaseIterable {
        case peaking
        case lowShelf
        case highShelf
        case lowPass
        case highPass
        case notch
        case allPass
    }

    let id: UUID
    var enabled: Bool
    var kind: Kind
    var frequency: Double
    var gain: Double?
    var q: Double?
    var bandwidth: Double?

    init(enabled: Bool = true, kind: Kind, frequency: Double, gain: Double? = nil, q: Double? = nil, bandwidth: Double? = nil) {
        self.id = UUID()
        self.enabled = enabled
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.bandwidth = bandwidth
    }
}

struct ParsedEQ {
    var preampDB: Double = 0
    var bands: [EQBand] = []
    var warnings: [String] = []
}

struct SpectrumPoint: Identifiable {
    let frequency: Double
    let db: Double
    var id: Double { frequency }
}
