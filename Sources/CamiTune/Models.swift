import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: String          // CoreAudio UID
    let objectID: UInt32
    let name: String
    let transportType: UInt32

    static let systemAudioBridgeName = "System Audio Bridge"
    static let systemAudioBridgeUID = "local.systemaudiobridge.device"

    init(id: String, objectID: UInt32, name: String, transportType: UInt32 = 0) {
        self.id = id
        self.objectID = objectID
        self.name = name
        self.transportType = transportType
    }

    var isRoutingDevice: Bool {
        id == Self.systemAudioBridgeUID ||
            ProfileRoutingDescriptor.isProfileRoutingUID(id) ||
            transportType == kAudioDeviceTransportTypeAggregate ||
            transportType == kAudioDeviceTransportTypeVirtual
    }
}

struct PhysicalOutputIdentity: Identifiable, Codable, Hashable {
    var uid: String
    var name: String

    var id: String { uid }
}

struct PhysicalDeviceDefaultProfile: Identifiable, Codable, Hashable {
    var physicalDevice: PhysicalOutputIdentity
    var profileID: UUID

    var id: String { physicalDevice.uid }
}

struct DeviceProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var outputDevice: PhysicalOutputIdentity
    var isEnabled: Bool = true
    var autoActivateWhenProfileDeviceSelected: Bool = false
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

    init(
        id: UUID = UUID(),
        name: String,
        outputDeviceUID: String,
        outputDeviceName: String,
        isEnabled: Bool = true,
        autoActivateWhenProfileDeviceSelected: Bool = false,
        lockOutputVolume: Bool = false,
        outputVolumeScalar: Double = 0.0625,
        sampleRate: Int = 48_000,
        chunkSize: Int = 1024,
        equalizerAPOText: String = DeviceProfile.defaultEqualizerAPOText
    ) {
        self.id = id
        self.name = name
        self.outputDevice = PhysicalOutputIdentity(uid: outputDeviceUID, name: outputDeviceName)
        self.isEnabled = isEnabled
        self.autoActivateWhenProfileDeviceSelected = autoActivateWhenProfileDeviceSelected
        self.lockOutputVolume = lockOutputVolume
        self.outputVolumeScalar = outputVolumeScalar
        self.sampleRate = sampleRate
        self.chunkSize = chunkSize
        self.equalizerAPOText = equalizerAPOText
    }

    var outputDeviceUID: String {
        get { outputDevice.uid }
        set { outputDevice.uid = newValue }
    }

    var outputDeviceName: String {
        get { outputDevice.name }
        set { outputDevice.name = newValue }
    }

    private static let defaultEqualizerAPOText = """
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

    private enum CodingKeys: String, CodingKey {
        case id, name, outputDevice, outputDeviceUID, outputDeviceName, isEnabled
        case autoActivateWhenProfileDeviceSelected
        case lockOutputVolume, outputVolumeScalar, sampleRate, chunkSize, equalizerAPOText
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case autoActivateWhenSystemAudioBridgeSelected
        case autoActivateWhenBlackHoleSelected
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        if let decodedOutput = try values.decodeIfPresent(PhysicalOutputIdentity.self, forKey: .outputDevice) {
            outputDevice = decodedOutput
        } else {
            outputDevice = PhysicalOutputIdentity(
                uid: try values.decode(String.self, forKey: .outputDeviceUID),
                name: try values.decode(String.self, forKey: .outputDeviceName)
            )
        }
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoActivateWhenProfileDeviceSelected = try values.decodeIfPresent(
            Bool.self,
            forKey: .autoActivateWhenProfileDeviceSelected
        ) ?? legacy.decodeIfPresent(
            Bool.self,
            forKey: .autoActivateWhenSystemAudioBridgeSelected
        ) ?? legacy.decodeIfPresent(Bool.self, forKey: .autoActivateWhenBlackHoleSelected) ?? false
        lockOutputVolume = try values.decodeIfPresent(Bool.self, forKey: .lockOutputVolume) ?? false
        outputVolumeScalar = try values.decodeIfPresent(Double.self, forKey: .outputVolumeScalar) ?? 0.0625
        sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
        chunkSize = try values.decodeIfPresent(Int.self, forKey: .chunkSize) ?? 1024
        equalizerAPOText = try values.decodeIfPresent(String.self, forKey: .equalizerAPOText)
            ?? Self.defaultEqualizerAPOText
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(outputDevice, forKey: .outputDevice)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(autoActivateWhenProfileDeviceSelected, forKey: .autoActivateWhenProfileDeviceSelected)
        try values.encode(lockOutputVolume, forKey: .lockOutputVolume)
        try values.encode(outputVolumeScalar, forKey: .outputVolumeScalar)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(chunkSize, forKey: .chunkSize)
        try values.encode(equalizerAPOText, forKey: .equalizerAPOText)
    }
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
