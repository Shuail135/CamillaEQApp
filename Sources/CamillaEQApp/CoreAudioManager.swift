import Foundation
import CoreAudio
import AudioToolbox

@MainActor
final class CoreAudioManager: ObservableObject {
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

    var blackHole: AudioDeviceInfo? {
        outputDevices.first(where: { $0.name == AudioDeviceInfo.blackHoleName })
    }

    func device(uid: String) -> AudioDeviceInfo? { outputDevices.first(where: { $0.id == uid }) }

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
        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
            case .osStatus(let status): return "CoreAudio error: \(status)"
            case .volumeNotSettable: return "This audio device does not expose a settable output volume."
            case .sampleRateNotSettable(let name): return "The sample rate for \(name) cannot be changed by the app."
            }
        }
    }
}
