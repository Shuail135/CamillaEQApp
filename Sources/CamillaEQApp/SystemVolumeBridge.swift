import Foundation
import CoreAudio

@MainActor
final class SystemVolumeBridge {
    private weak var coreAudio: CoreAudioManager?
    private weak var spectrum: SpectrumAnalyzer?
    private var blackHoleUID: String?
    private var physicalUID: String?
    private var blackHoleID: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var rampTask: Task<Void, Never>?
    private var onVolume: ((Double) -> Void)?

    func start(
        blackHole: AudioDeviceInfo,
        physicalUID: String,
        coreAudio: CoreAudioManager,
        spectrum: SpectrumAnalyzer,
        onVolume: @escaping (Double) -> Void
    ) {
        stop()
        self.coreAudio = coreAudio
        self.spectrum = spectrum
        self.blackHoleUID = blackHole.id
        self.physicalUID = physicalUID
        self.blackHoleID = blackHole.objectID
        self.onVolume = onVolume

        let initialVolume = coreAudio.volume(uid: physicalUID) ?? 1
        try? coreAudio.setVolume(uid: blackHole.id, scalar: initialVolume)
        coreAudio.setMuted(uid: blackHole.id, muted: coreAudio.isMuted(uid: physicalUID) ?? false)
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
        _ = AudioObjectAddPropertyListenerBlock(blackHole.objectID, &volumeAddress, .main, volumeBlock)
        _ = AudioObjectAddPropertyListenerBlock(blackHole.objectID, &muteAddress, .main, muteBlock)
    }

    func stop() {
        rampTask?.cancel()
        rampTask = nil
        if let id = blackHoleID, let block = volumeListener {
            var address = Self.volumeAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        if let id = blackHoleID, let block = muteListener {
            var address = Self.muteAddress
            _ = AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        spectrum?.setInputCompensation(decibels: 0)
        volumeListener = nil
        muteListener = nil
        blackHoleID = nil
        blackHoleUID = nil
        physicalUID = nil
        onVolume = nil
    }

    func setVolume(_ scalar: Float32, physicalUID requestedUID: String) -> Bool {
        guard requestedUID == physicalUID,
              let coreAudio,
              let blackHoleUID else { return false }
        try? coreAudio.setVolume(uid: blackHoleUID, scalar: scalar)
        synchronize()
        return true
    }

    private func synchronize() {
        guard let coreAudio, let blackHoleUID, let physicalUID,
              let target = coreAudio.volume(uid: blackHoleUID) else { return }
        let attenuation = Double(coreAudio.volumeDecibels(uid: blackHoleUID) ?? 0)
        spectrum?.setInputCompensation(decibels: -attenuation)
        onVolume?(Double(target))
        rampPhysicalVolume(to: target, uid: physicalUID)
    }

    private func synchronizeMute() {
        guard let coreAudio, let blackHoleUID, let physicalUID,
              let muted = coreAudio.isMuted(uid: blackHoleUID) else { return }
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
