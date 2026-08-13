import Foundation
import AppKit

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var activeProfileID: UUID?
    @Published var errorMessage: String?
    @Published var validationMessage: String = ""
    @Published var warnings: [String] = []
    @Published private(set) var isValidating = false

    let coreAudio: CoreAudioManager
    let profiles: ProfileStore
    let dependencies: DependencyManager
    let loginItem = LoginItemManager()
    let dsp = CamillaDSPManager()
    let meters = MeterModel()
    let spectrum = SpectrumAnalyzer()

    private let notifications = NotificationManager()
    private let parser = EqualizerAPOParser()
    private let configBuilder = CamillaConfigBuilder()
    private let volumeBridge = SystemVolumeBridge()
    private var previousDefaultUID: String?
    private var monitorTimer: Timer?
    private var suppressedAutoUID: String?
    private var transitionInProgress = false
    private var activeSampleRate: Int?

    override init() {
        let audio = CoreAudioManager()
        self.coreAudio = audio
        self.profiles = ProfileStore()
        self.dependencies = DependencyManager(coreAudio: audio)
        super.init()

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.monitorRouting()
            }
        }

        Task { await notifications.requestAuthorization() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        monitorTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func validate(profile: DeviceProfile) -> ParsedEQ? {
        do {
            let parsed = try parser.parse(profile.equalizerAPOText)
            warnings = parsed.warnings
            let activeFilterCount = parsed.bands.lazy.filter(\.enabled).count
            validationMessage = "Valid: \(activeFilterCount) active filters, preamp \(String(format: "%.2f", parsed.preampDB)) dB"
            errorMessage = nil
            return parsed
        } catch {
            validationMessage = ""
            warnings = []
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func validateSetup(profile: DeviceProfile) async {
        guard !isValidating else { return }
        isValidating = true
        validationMessage = "Validating dependencies, devices, sample rate, and CamillaDSP configuration…"
        defer { isValidating = false }
        guard let parsed = validate(profile: profile) else { return }
        do {
            dependencies.refresh()
            guard FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) else {
                throw AppError.missingCamillaDSP
            }
            guard let blackHole = coreAudio.blackHole else { throw AppError.missingBlackHole }
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            guard output.id != blackHole.id else { throw AppError.invalidTarget }
            let rate = Double(profile.sampleRate)
            guard coreAudio.supportsSampleRate(uid: blackHole.id, rate: rate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, blackHole.name)
            }
            guard coreAudio.supportsSampleRate(uid: output.id, rate: rate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, output.name)
            }

            var resolved = profile
            resolved.outputDeviceName = output.name
            try dependencies.validateConfiguration(configBuilder.build(profile: resolved, parsed: parsed))

            if isActive, activeProfileID == profile.id {
                let engineState = try await dsp.rpc.state()
                validationMessage = "Ready: EQ syntax, dependencies, devices, \(rateDescription(profile.sampleRate)), CamillaDSP config, and live engine checked (\(engineState))."
            } else {
                validationMessage = "Ready: EQ syntax, dependencies, devices, \(rateDescription(profile.sampleRate)), and CamillaDSP config checked. Activate EQ to test the live audio engine."
            }
            errorMessage = nil
        } catch {
            validationMessage = ""
            errorMessage = "Validation failed: \(error.localizedDescription)"
        }
    }

    private func rateDescription(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }

    func activate(profile: DeviceProfile) async {
        guard !transitionInProgress else { return }
        transitionInProgress = true
        defer { transitionInProgress = false }

        do {
            dependencies.refresh()
            guard FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) else {
                throw AppError.missingCamillaDSP
            }
            guard let blackHole = coreAudio.blackHole else { throw AppError.missingBlackHole }
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else { throw AppError.outputMissing(profile.outputDeviceName) }
            guard output.id != blackHole.id else { throw AppError.invalidTarget }
            guard let parsed = validate(profile: profile) else { return }
            let sampleRate = Double(profile.sampleRate)
            guard coreAudio.supportsSampleRate(uid: blackHole.id, rate: sampleRate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, blackHole.name)
            }
            guard coreAudio.supportsSampleRate(uid: output.id, rate: sampleRate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, output.name)
            }

            if isActive {
                // There is one system route and one private CamillaDSP engine.
                // Switching profiles must explicitly release the old pipeline
                // before the replacement can own either resource.
                guard activeProfileID != profile.id else { return }
                await stopProcessingPipeline()
                isActive = false
                activeProfileID = nil
                activeSampleRate = nil
            }

            if coreAudio.defaultOutputUID != blackHole.id {
                previousDefaultUID = coreAudio.defaultOutputUID
            }

            // Virtual routing device is always unity.
            try? coreAudio.setVolume(uid: blackHole.id, scalar: 1.0)

            try coreAudio.setSampleRate(uid: blackHole.id, rate: sampleRate)

            try await dsp.start(binary: dependencies.camillaDSPBinary)
            var resolvedProfile = profile
            resolvedProfile.outputDeviceName = output.name
            let yaml = configBuilder.build(profile: resolvedProfile, parsed: parsed)
            try await dsp.apply(yaml: yaml)

            // This app is the sole BlackHole capture owner. It sends the exact
            // captured frames to both the FFT and CamillaDSP's stdin backend.
            try await spectrum.start(
                deviceObjectID: blackHole.objectID,
                audioSink: try dsp.audioInputHandle()
            )

            // Switch system audio only after the DSP is ready to receive BlackHole.
            try coreAudio.setDefaultOutput(uid: blackHole.id)
            try? coreAudio.setVolume(uid: blackHole.id, scalar: 1.0)

            guard await spectrum.waitUntilReceiving() else {
                throw AppError.spectrumCaptureFailed
            }

            volumeBridge.start(
                blackHole: blackHole,
                physicalUID: output.id,
                coreAudio: coreAudio,
                spectrum: spectrum
            ) { [weak self] volume in
                guard let self,
                      let index = self.profiles.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                self.profiles.profiles[index].outputVolumeScalar = volume
            }

            meters.start(rpc: dsp.rpc)

            activeProfileID = profile.id
            activeSampleRate = profile.sampleRate
            isActive = true
            suppressedAutoUID = nil
            notifications.activated()
        } catch {
            errorMessage = error.localizedDescription
            await stopProcessingPipeline()
            if let blackHole = coreAudio.blackHole,
               coreAudio.defaultOutputUID == blackHole.id {
                let restore = previousDefaultUID.flatMap { coreAudio.device(uid: $0) != nil ? $0 : nil } ?? profile.outputDeviceUID
                try? coreAudio.setDefaultOutput(uid: restore)
            }
            isActive = false
            activeProfileID = nil
            activeSampleRate = nil
        }
    }

    func apply(profile: DeviceProfile) async {
        guard let parsed = validate(profile: profile) else { return }
        guard isActive, activeProfileID == profile.id else { return }
        if activeSampleRate != profile.sampleRate {
            await deactivate(manual: false)
            await activate(profile: profile)
            return
        }
        do {
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else { throw AppError.outputMissing(profile.outputDeviceName) }
            var resolved = profile
            resolved.outputDeviceName = output.name
            let yaml = configBuilder.build(profile: resolved, parsed: parsed)
            try await dsp.apply(yaml: yaml)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deactivate(manual: Bool = true, restoreOutput: Bool = true) async {
        guard !transitionInProgress else { return }
        transitionInProgress = true
        defer { transitionInProgress = false }

        let targetUID = activeProfileID.flatMap { id in profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID }

        await stopProcessingPipeline()

        if restoreOutput {
            let restore = previousDefaultUID.flatMap { coreAudio.device(uid: $0) != nil ? $0 : nil } ?? targetUID
            if let restore { try? coreAudio.setDefaultOutput(uid: restore) }
        }

        isActive = false
        activeProfileID = nil
        activeSampleRate = nil
        previousDefaultUID = nil
        if manual { suppressedAutoUID = targetUID }
        notifications.deactivated()
    }

    private func stopProcessingPipeline() async {
        meters.stop()
        volumeBridge.stop()
        spectrum.stop()
        await dsp.stop()
    }

    private func monitorRouting() async {
        guard !transitionInProgress else { return }
        coreAudio.refresh()
        let reboundProfileIDs = profiles.reconcileDevices(coreAudio.outputDevices)

        if isActive {
            if let activeProfileID,
               reboundProfileIDs.contains(activeProfileID),
               let reboundProfile = profiles.profiles.first(where: { candidate in
                   candidate.id == activeProfileID
               }) {
                await deactivate(manual: false, restoreOutput: false)
                await activate(profile: reboundProfile)
                return
            }
            if let activeProfileID,
               let activeProfile = profiles.profiles.first(where: { $0.id == activeProfileID }),
               coreAudio.device(uid: activeProfile.outputDeviceUID) == nil {
                await deactivate(manual: false, restoreOutput: false)
                return
            }
            guard let blackHole = coreAudio.blackHole else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            // If the user picks another macOS output while EQ is active, respect it.
            if coreAudio.defaultOutputUID != blackHole.id {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            return
        }

        guard let current = coreAudio.defaultOutputUID else { return }
        if let suppressedAutoUID {
            if current == suppressedAutoUID { return }
            self.suppressedAutoUID = nil
        }

        // CoreAudio can temporarily keep a removed device's UID as the default
        // after it is unplugged. Never auto-activate from that stale UID: doing
        // so retries a missing route every monitor tick.
        if let profile = profiles.profiles.first(where: {
            $0.autoActivate
                && $0.outputDeviceUID == current
                && coreAudio.device(uid: $0.outputDeviceUID) != nil
        }) {
            await activate(profile: profile)
            return
        }

        if let blackHole = coreAudio.blackHole,
           current == blackHole.id {
            let connected = profiles.profiles.filter {
                ($0.autoActivateWhenBlackHoleSelected ?? false)
                    && coreAudio.device(uid: $0.outputDeviceUID) != nil
            }
            let preferred = profiles.selectedProfileID.flatMap { selectedID in
                connected.first(where: { $0.id == selectedID })
            } ?? connected.first
            if let preferred { await activate(profile: preferred) }
        }
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        shutdownSynchronously()
    }

    private func shutdownSynchronously() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        meters.stop()
        volumeBridge.stop()
        spectrum.stop()

        if let blackHole = coreAudio.blackHole,
           coreAudio.defaultOutputUID == blackHole.id {
            let targetUID = activeProfileID.flatMap { id in profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID }
            let restore = previousDefaultUID ?? targetUID
            if let restore { try? coreAudio.setDefaultOutput(uid: restore) }
        }
        dsp.forceStopAndWait()
        isActive = false
        activeProfileID = nil
        activeSampleRate = nil
        previousDefaultUID = nil
    }

    enum AppError: LocalizedError {
        case missingCamillaDSP
        case missingBlackHole
        case outputMissing(String)
        case invalidTarget
        case unsupportedSampleRate(Int, String)
        case spectrumCaptureFailed
        var errorDescription: String? {
            switch self {
            case .missingCamillaDSP: return "CamillaDSP is not installed. Open Setup and install it first."
            case .missingBlackHole: return "BlackHole 2ch is not installed or not visible to CoreAudio."
            case .outputMissing(let name): return "The selected output device is not connected: \(name)"
            case .invalidTarget: return "BlackHole cannot be used as the physical playback target."
            case .unsupportedSampleRate(let rate, let device): return "\(device) does not report support for the selected \(Double(rate) / 1000) kHz sample rate."
            case .spectrumCaptureFailed: return "BlackHole capture did not start. Audio routing was restored and CamillaDSP was stopped."
            }
        }
    }
}
