import Foundation
import CoreAudio
import AudioToolbox
import SystemAudioBridgeC

@MainActor
final class CoreAudioManager: ObservableObject {
    static let minimumPresentationDriverVersion = "0.1.0"

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
        outputDevices = enumerateOutputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        defaultOutputUID = defaultOutputDevice().flatMap { deviceUID($0) }
    }

    var systemAudioBridge: AudioDeviceInfo? {
        deviceInfo(forUID: AudioDeviceInfo.systemAudioBridgeUID)
    }

    var isSystemAudioBridgeTransportSupported: Bool {
        guard let device = systemAudioBridge else { return false }
        return sabr_client_transport_is_supported(device.objectID)
    }

    var installedSystemAudioBridgeVersion: String? {
        let path = "/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver/Contents/Info.plist"
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

    /// Sound Settings caches virtual-device rows by UID and does not always
    /// repaint them after a name-only notification. Removing the bridge from
    /// the visible device list and immediately re-presenting the same object
    /// emits the system device-list notifications macOS actually observes.
    /// Hiding does not stop the device or change the default audio route.
    func refreshSystemAudioBridgePresentation(name: String) throws {
        guard let bridge = systemAudioBridge else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let hiddenStatus = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: name,
            visible: false
        )
        guard hiddenStatus == noErr else { throw AudioError.osStatus(hiddenStatus) }

        let visibleStatus = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: name,
            visible: true
        )
        if visibleStatus != noErr {
            // Make one best-effort attempt to avoid leaving an active route
            // hidden if the first re-presentation was interrupted.
            _ = setSystemAudioBridgePresentation(
                objectID: bridge.objectID,
                name: name,
                visible: true
            )
            throw AudioError.osStatus(visibleStatus)
        }
        refresh()
    }

    /// Forces Sound Settings to re-read other virtual-device names while the
    /// real bridge remains hidden (the normal state when EQ is inactive).
    /// The show/hide pair is back-to-back, so clients only observe the final
    /// hidden state but Core Audio still emits device-list changes.
    func refreshDeviceListKeepingSystemAudioBridgeHidden() throws {
        guard let bridge = systemAudioBridge else {
            throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID)
        }
        let visibleStatus = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: bridge.name,
            visible: true
        )
        guard visibleStatus == noErr else { throw AudioError.osStatus(visibleStatus) }

        let hiddenStatus = setSystemAudioBridgePresentation(
            objectID: bridge.objectID,
            name: bridge.name,
            visible: false
        )
        if hiddenStatus != noErr {
            _ = setSystemAudioBridgePresentation(
                objectID: bridge.objectID,
                name: bridge.name,
                visible: false
            )
            throw AudioError.osStatus(hiddenStatus)
        }
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
            (uid == AudioDeviceInfo.systemAudioBridgeUID ? deviceInfo(forUID: uid) : nil)
    }

    func profileRoutingDevice(profileID: UUID) -> AudioDeviceInfo? {
        device(uid: ProfileRoutingDescriptor.uid(for: profileID))
    }

    /// Removes the short-lived aggregate device used to select a profile from
    /// macOS. The caller must first move the default output to the real bridge;
    /// Core Audio will not reliably remove an aggregate while it is default.
    func removeProfileRoutingDevice(profileID: UUID) throws {
        refresh()
        guard let device = profileRoutingDevice(profileID: profileID) else { return }
        guard device.id != defaultOutputUID else {
            throw AudioError.profileRoutingDeviceIsDefault(device.name)
        }
        let status = AudioHardwareDestroyAggregateDevice(device.objectID)
        guard status == noErr || status == kAudioHardwareBadObjectError else {
            throw AudioError.osStatus(status)
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
        guard systemAudioBridge != nil else { throw AudioError.deviceNotFound(AudioDeviceInfo.systemAudioBridgeUID) }

        let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles)
        let desired = ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaultOutputUID: defaultOutputUID,
            additionallyVisible: additionallyVisible
        )

        let existing = outputDevices.compactMap { device -> (UUID, AudioDeviceInfo)? in
            guard let profileID = ProfileRoutingDescriptor.profileID(from: device.id) else { return nil }
            return (profileID, device)
        }
        for (profileID, device) in existing where !desired.contains(profileID) {
            guard device.id != defaultOutputUID else { continue }
            let status = AudioHardwareDestroyAggregateDevice(device.objectID)
            guard status == noErr || status == kAudioHardwareBadObjectError else {
                throw AudioError.osStatus(status)
            }
        }

        refresh()
        for profileID in desired.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let descriptor = descriptors[profileID] else { continue }
            if let existing = device(uid: descriptor.uid) {
                if existing.name != descriptor.name { try setDeviceName(existing.objectID, name: descriptor.name) }
            } else {
                try createProfileAggregate(descriptor)
            }
        }
        refresh()
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

    func setSampleRate(uid: String, rate: Double) throws {
        guard let device = device(uid: uid) else { throw AudioError.deviceNotFound(uid) }
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
            return AudioDeviceInfo(id: uid, objectID: id, name: name)
        }
    }

    private func deviceInfo(forUID uid: String) -> AudioDeviceInfo? {
        guard let objectID = deviceObjectID(forUID: uid),
              hasOutputStreams(objectID),
              let name = deviceName(objectID) else { return nil }
        return AudioDeviceInfo(id: uid, objectID: objectID, name: name)
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

    private func createProfileAggregate(_ descriptor: ProfileRoutingDescriptor) throws {
        let subdevice: [String: Any] = [kAudioSubDeviceUIDKey: AudioDeviceInfo.systemAudioBridgeUID]
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: descriptor.uid,
            kAudioAggregateDeviceNameKey: descriptor.name,
            kAudioAggregateDeviceSubDeviceListKey: [subdevice],
            kAudioAggregateDeviceMainSubDeviceKey: AudioDeviceInfo.systemAudioBridgeUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false
        ]
        var objectID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &objectID)
        guard status == noErr else { throw AudioError.aggregateCreationFailed(descriptor.name, status) }
    }

    private func setDeviceName(_ objectID: AudioObjectID, name: String) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(objectID, &address, &settable)
        guard settableStatus == noErr else { throw AudioError.osStatus(settableStatus) }
        guard settable.boolValue else { throw AudioError.deviceNameNotSettable(name) }
        var value = name as CFString
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFString>.size),
                pointer
            )
        }
        guard status == noErr else { throw AudioError.osStatus(status) }
        guard deviceName(objectID) == name else {
            throw AudioError.deviceRenameDidNotApply(name)
        }
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

    enum AudioError: LocalizedError {
        case deviceNotFound(String)
        case osStatus(OSStatus)
        case volumeNotSettable
        case sampleRateNotSettable(String)
        case aggregateCreationFailed(String, OSStatus)
        case profileRoutingDeviceIsDefault(String)
        case deviceNameNotSettable(String)
        case deviceRenameDidNotApply(String)
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
            case .osStatus(let status): return "CoreAudio error: \(status)"
            case .volumeNotSettable: return "This audio device does not expose a settable output volume."
            case .sampleRateNotSettable(let name): return "The sample rate for \(name) cannot be changed by the app."
            case .aggregateCreationFailed(let name, let status):
                return "Could not create the \(name) audio device (CoreAudio \(status))."
            case .profileRoutingDeviceIsDefault(let name):
                return "The temporary \(name) selector is still the macOS default output."
            case .deviceNameNotSettable(let name):
                return "Core Audio does not allow the \(name) profile device to be renamed."
            case .deviceRenameDidNotApply(let name):
                return "Core Audio accepted the rename to \(name), but did not publish it."
            }
        }
    }
}
