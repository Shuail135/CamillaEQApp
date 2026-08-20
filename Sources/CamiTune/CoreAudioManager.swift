import Foundation
import CoreAudio
import AudioToolbox
import SystemAudioBridgeC

@MainActor
final class CoreAudioManager: ObservableObject {
    static let minimumPresentationDriverVersion = "0.2.1"

    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var defaultOutputUID: String?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let devices = enumerateOutputDevices().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let defaultUID = defaultOutputDevice().flatMap { deviceUID($0) }
        if outputDevices != devices { outputDevices = devices }
        if defaultOutputUID != defaultUID { defaultOutputUID = defaultUID }
    }

    var physicalOutputDevices: [AudioDeviceInfo] {
        outputDevices.filter { !$0.isRoutingDevice }
    }

    var systemAudioBridge: AudioDeviceInfo? {
        deviceInfo(forUID: AudioDeviceInfo.systemAudioBridgeUID)
    }

    var isSystemAudioBridgeTransportSupported: Bool {
        guard let device = systemAudioBridge else { return false }
        return sabr_client_transport_is_supported(device.objectID)
    }

    var installedSystemAudioBridgeVersion: String? {
        let path = "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver/Contents/Info.plist"
        guard let dictionary = NSDictionary(contentsOfFile: path) else { return nil }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    var isSystemAudioBridgePresentationSupported: Bool {
        guard isSystemAudioBridgeTransportSupported,
              let version = installedSystemAudioBridgeVersion else { return false }
        return Self.version(version, isAtLeast: Self.minimumPresentationDriverVersion)
    }

    private static func version(_ candidate: String, isAtLeast minimum: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    func setSystemAudioBridgePresentation(name: String, visible: Bool) throws {
        guard let bridge = systemAudioBridge else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let status = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: name,
            visible: visible
        )
        guard status == noErr else { throw AudioError.osStatus(status) }
        refresh()
    }

    private func setSystemAudioBridgePresentation(
        objectID: AudioObjectID,
        name: String,
        visible: Bool
    ) -> OSStatus {
        name.withCString { displayName in
            sabr_client_set_presentation(objectID, displayName, visible)
        }
    }

    func device(uid: String) -> AudioDeviceInfo? {
        outputDevices.first(where: { $0.id == uid }) ??
            deviceInfo(forUID: uid)
    }

    func profileRoutingDevice(profileID: UUID) -> AudioDeviceInfo? {
        device(uid: ProfileRoutingDescriptor.uid(for: profileID))
    }

    func waitForProfileRoutingDevice(profileID: UUID) async -> AudioDeviceInfo? {
        for attempt in 0..<40 {
            refresh()
            if let device = profileRoutingDevice(profileID: profileID) {
                return device
            }
            guard attempt < 39, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Unpublishes the driver's native profile endpoints and removes any
    /// aggregate selectors left by an older CamiTune build.
    func destroyAllProfileRoutingDevices(fallbackUID: String? = nil) {
        refresh()
        var selectors = outputDevices.filter {
            ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
        }
        if let defaultOutputUID,
           selectors.contains(where: { $0.id == defaultOutputUID }) {
            let fallback = fallbackUID.flatMap { requested in
                physicalOutputDevices.first(where: { $0.id == requested })?.id
            } ?? physicalOutputDevices.first?.id
            if let fallback { try? setDefaultOutput(uid: fallback) }
        }

        refresh()
        selectors = outputDevices.filter {
            ProfileRoutingDescriptor.isProfileRoutingUID($0.id)
        }
        for device in selectors where device.id != defaultOutputUID && isAggregateDevice(device.objectID) {
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else { continue }
        }
        if let bridge = systemAudioBridge {
            _ = sabr_client_set_profile_devices(bridge.objectID, [] as CFArray)
        }
        refresh()
    }

    @discardableResult
    func synchronizeProfileRoutingDevices(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        additionallyVisible: Set<UUID> = []
    ) throws -> [UUID: ProfileRoutingDescriptor] {
        refresh()
        guard let bridge = systemAudioBridge else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }

        let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles)
        let desired = ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID,
            additionallyVisible: additionallyVisible
        )

        // One-time migration: native driver endpoints replace the aggregate
        // selectors used by older builds.
        var migratedDefaultUID: String?
        for device in outputDevices where
            ProfileRoutingDescriptor.isProfileRoutingUID(device.id) &&
            isAggregateDevice(device.objectID) {
            if device.id == defaultOutputUID {
                migratedDefaultUID = device.id
                try setDefaultOutput(uid: bridge.id)
            }
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else {
                throw AudioError.osStatus(status)
            }
        }

        let profileDevices: [[String: String]] = desired
            .sorted(by: { $0.uuidString < $1.uuidString })
            .compactMap { profileID in
                guard let descriptor = descriptors[profileID] else { return nil }
                return [
                    "deviceUID": descriptor.uid,
                    "displayName": descriptor.name
                ]
            }
        let status = sabr_client_set_profile_devices(bridge.objectID, profileDevices as CFArray)
        guard status == noErr else {
            throw AudioError.profileDeviceConfigurationFailed(status)
        }
        refresh()
        if let migratedDefaultUID, device(uid: migratedDefaultUID) != nil {
            try setDefaultOutput(uid: migratedDefaultUID)
        }
        return descriptors
    }

    func supportsSampleRate(uid: String, rate: Double) -> Bool {
        guard let device = device(uid: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device.objectID, &address, 0, nil, &size) == noErr else { return false }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &ranges) == noErr else { return false }
        return ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }

    func nominalSampleRate(uid: String) -> Double? {
        guard let device = device(uid: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            device.objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    func setSampleRate(uid: String, rate: Double) async throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        if let actual = nominalSampleRate(uid: uid), abs(actual - rate) < 0.5 {
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device.objectID, &address, &settable) == noErr,
              settable.boolValue else { throw AudioError.sampleRateNotSettable(device.name) }
        var value = rate
        let status = AudioObjectSetPropertyData(device.objectID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw AudioError.osStatus(status) }
        for _ in 0..<20 {
            if let actual = nominalSampleRate(uid: uid), abs(actual - rate) < 0.5 {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AudioError.sampleRateDidNotApply(
            device.name,
            requested: rate,
            actual: nominalSampleRate(uid: uid)
        )
    }

    func setDefaultOutput(uid: String) throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        var id = AudioDeviceID(device.objectID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        guard status == noErr else { throw AudioError.osStatus(status) }
        refresh()
    }

    func setDefaultOutputAndWait(uid: String) async throws {
        let deviceName = device(uid: uid)?.name ?? uid
        try setDefaultOutput(uid: uid)
        for attempt in 0..<40 {
            refresh()
            if defaultOutputUID == uid { return }
            guard attempt < 39 else { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AudioError.defaultOutputDidNotApply(deviceName)
    }

    func setVolume(uid: String, scalar: Float32) throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
        let deviceID = AudioDeviceID(device.objectID)
        let value = max(0, min(1, scalar))
        var didSet = false

        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { continue }
            var v = value
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        if !didSet { throw AudioError.volumeNotSettable }
    }

    func volume(uid: String) -> Float32? {
        floatProperty(uid: uid, selector: kAudioDevicePropertyVolumeScalar)
    }

    func volumeDecibels(uid: String) -> Float32? {
        floatProperty(uid: uid, selector: kAudioDevicePropertyVolumeDecibels)
    }

    func isMuted(uid: String) -> Bool? {
        guard let device = device(uid: uid) else { return nil }
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device.objectID, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return nil
    }

    func setMuted(uid: String, muted: Bool) {
        guard let device = device(uid: uid) else { return }
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device.objectID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device.objectID, &address, &settable) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            _ = AudioObjectSetPropertyData(device.objectID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }

    func unmute(uid: String) {
        setMuted(uid: uid, muted: false)
    }

    private func floatProperty(uid: String, selector: AudioObjectPropertySelector) -> Float32? {
        guard let device = device(uid: uid) else { return nil }
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device.objectID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private func enumerateOutputDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let uid = deviceUID(id), let name = deviceName(id) else { return nil }
            return AudioDeviceInfo(
                id: uid,
                objectID: id,
                name: name,
                transportType: uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            )
        }
    }

    private func deviceInfo(forUID uid: String) -> AudioDeviceInfo? {
        guard let objectID = deviceObjectID(forUID: uid),
              hasOutputStreams(objectID),
              let name = deviceName(objectID) else { return nil }
        return AudioDeviceInfo(
            id: uid,
            objectID: objectID,
            name: name,
            transportType: uint32Property(objectID, selector: kAudioDevicePropertyTransportType) ?? 0
        )
    }

    private func deviceObjectID(forUID uid: String) -> AudioDeviceID? {
        var uidValue = uid as CFString
        var objectID = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafePointer(to: &uidValue) { uidPointer in
            withUnsafeMutablePointer(to: &objectID) { objectPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(mutating: uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(objectPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func isAggregateDevice(_ objectID: AudioObjectID) -> Bool {
        uint32Property(objectID, selector: kAudioObjectPropertyClass) == kAudioAggregateDeviceClassID
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func uint32Property(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    enum AudioError: LocalizedError {
        case deviceNotFound(String)
        case osStatus(OSStatus)
        case volumeNotSettable
        case sampleRateNotSettable(String)
        case sampleRateDidNotApply(String, requested: Double, actual: Double?)
        case defaultOutputDidNotApply(String)
        case profileDeviceConfigurationFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
            case .osStatus(let status): return "CoreAudio error: \(status)"
            case .volumeNotSettable: return "This audio device does not expose a settable output volume."
            case .sampleRateNotSettable(let name): return "The sample rate for \(name) cannot be changed by the app."
            case .sampleRateDidNotApply(let name, let requested, let actual):
                let requestedText = String(format: "%.1f kHz", requested / 1_000)
                let actualText = actual.map { String(format: "%.1f kHz", $0 / 1_000) } ?? "an unknown rate"
                return "\(name) did not switch to \(requestedText); it remained at \(actualText)."
            case .defaultOutputDidNotApply(let name):
                return "macOS did not finish switching the default audio output to \(name)."
            case .profileDeviceConfigurationFailed(let status):
                return "System Audio Bridge could not publish the profile audio devices (CoreAudio \(status)). Reinstall the bundled driver."
            }
        }
    }
}
