import Foundation
import CoreAudio

@MainActor
final class SystemVolumeBridge {
    private weak var coreAudio: CoreAudioManager?
    private var routingUID: String?
    private var physicalUID: String?
    private var routingID: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var rampTask: Task<Void, Never>?
    private var onVolume: ((Double) -> Void)?

    func start(
        routingDevice: AudioDeviceInfo,
        physicalUID: String,
        coreAudio: CoreAudioManager,
        onVolume: @escaping (Double) -> Void
    ) {
        stop()
        self.coreAudio = coreAudio
        self.routingUID = routingDevice.id
        self.physicalUID = physicalUID
        self.routingID = routingDevice.objectID
        self.onVolume = onVolume

        let initialVolume = coreAudio.volume(uid: physicalUID) ?? 1
        try? coreAudio.setVolume(uid: routingDevice.id, scalar: initialVolume)
        coreAudio.setMuted(uid: routingDevice.id, muted: coreAudio.isMuted(uid: physicalUID) ?? false)
        synchronize()

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.synchronize() }
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.synchronizeMute() }
        }
        self.volumeListener = volumeBlock
        self.muteListener = muteBlock

        var volumeAddress = Self.volumeAddress
        var muteAddress = Self.muteAddress
        _ = AudioObjectAddPropertyListenerBlock(routingDevice.objectID, &volumeAddress, .main, volumeBlock)
        _ = AudioObjectAddPropertyListenerBlock(routingDevice.objectID, &muteAddress, .main, muteBlock)
    }

    func stop() {
        rampTask?.cancel()
        rampTask = nil
        if let id = routingID, let block = volumeListener {
            var address = Self.volumeAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        if let id = routingID, let block = muteListener {
            var address = Self.muteAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        volumeListener = nil
        muteListener = nil
        routingID = nil
        routingUID = nil
        physicalUID = nil
        onVolume = nil
    }

    func setVolume(_ scalar: Float32, physicalUID requestedUID: String) -> Bool {
        guard requestedUID == physicalUID,
              let coreAudio,
              let routingUID else { return false }
        try? coreAudio.setVolume(uid: routingUID, scalar: scalar)
        synchronize()
        return true
    }

    private func synchronize() {
        guard let coreAudio, let routingUID, let physicalUID,
              let target = coreAudio.volume(uid: routingUID) else { return }
        onVolume?(Double(target))
        rampPhysicalVolume(to: target, uid: physicalUID)
    }

    private func synchronizeMute() {
        guard let coreAudio, let routingUID, let physicalUID,
              let muted = coreAudio.isMuted(uid: routingUID) else { return }
        coreAudio.setMuted(uid: physicalUID, muted: muted)
    }

    private func rampPhysicalVolume(to target: Float32, uid: String) {
        rampTask?.cancel()
        guard let coreAudio else { return }
        let start = coreAudio.volume(uid: uid) ?? target
        rampTask = Task { [weak self] in
            for step in 1...6 {
                guard !Task.isCancelled, let self, let coreAudio = self.coreAudio else { return }
                let fraction = Float32(step) / 6
                let value = start + (target - start) * fraction
                try? coreAudio.setVolume(uid: uid, scalar: value)
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
