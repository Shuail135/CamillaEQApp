import Foundation
import AppKit

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var activeSession: AudioRuntimeSession?
    @Published var errorMessage: String?
    @Published var validationMessage: String = ""
    @Published var warnings: [String] = []
    @Published private(set) var isValidating = false

    var activeProfileID: UUID? { activeSession?.profileID }

    let coreAudio: CoreAudioManager
    let profiles: ProfileStore
    let dependencies: DependencyManager
    let loginItem = LoginItemManager()
    let dsp = CamillaDSPManager()
    let meters = MeterModel()
    let spectrum = SpectrumAnalyzer()
    let pcmRouter = PCMRouter()
    let driverTransport = SystemAudioBridgeTransport()
    let updateChecker = AppUpdateChecker()

    private let notifications = NotificationManager()
    private let parser = EqualizerAPOParser()
    private let configBuilder = CamillaConfigBuilder()
    private let volumeBridge = SystemVolumeBridge()
    private var previousDefaultUID: String?
    private var monitorTimer: Timer?
    private var suppressedAutoUID: String?
    private var transitionInProgress = false
    private var activeSampleRate: Int?
    private var activeRoutingUID: String?
    private var latestApplyRequest: UInt64 = 0
    private var sessionEQDrafts: [UUID: String] = [:]

    override init() {
        let audio = CoreAudioManager()
        self.coreAudio = audio
        self.profiles = ProfileStore()
        self.dependencies = DependencyManager(coreAudio: audio)
        super.init()
        UIRenderPerformance.startMonitoring()

        if audio.isSystemAudioBridgePresentationSupported {
            try? audio.setSystemAudioBridgePresentation(
                name: "System Audio Bridge",
                visible: false
            )
        }
        _ = try? audio.synchronizeProfileRoutingDevices(
            profiles: profiles.profiles,
            activeProfileID: nil
        )

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.monitorRouting()
            }
        }

        Task { await notifications.requestAuthorization() }
        updateChecker.start()
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

    func eqDraft(for profileID: UUID) -> String? {
        sessionEQDrafts[profileID]
    }

    func setEQDraft(_ text: String, for profileID: UUID) {
        sessionEQDrafts[profileID] = text
    }

    func clearEQDraft(for profileID: UUID) {
        sessionEQDrafts.removeValue(forKey: profileID)
    }

    func processingSampleRateProblem(rate: Int, outputUID: String) -> String? {
        guard let bridge = coreAudio.systemAudioBridge else {
            return AppError.missingRoutingDriver.localizedDescription
        }
        guard coreAudio.supportsSampleRate(uid: bridge.id, rate: Double(rate)) else {
            return AppError.unsupportedSampleRate(rate, bridge.name).localizedDescription
        }
        guard let output = coreAudio.device(uid: outputUID) else {
            return "The selected physical output is disconnected."
        }
        guard coreAudio.supportsSampleRate(uid: output.id, rate: Double(rate)) else {
            return AppError.unsupportedSampleRate(rate, output.name).localizedDescription
        }
        return nil
    }

    func reportProcessingSampleRateProblem(rate: Int, outputUID: String) {
        errorMessage = processingSampleRateProblem(rate: rate, outputUID: outputUID)
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
            guard let bridge = coreAudio.systemAudioBridge else { throw AppError.missingRoutingDriver }
            guard coreAudio.isSystemAudioBridgePresentationSupported else {
                throw AppError.outdatedRoutingDriver
            }
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            guard !output.isRoutingDevice else { throw AppError.invalidTarget }
            let rate = Double(profile.sampleRate)
            guard coreAudio.supportsSampleRate(uid: bridge.id, rate: rate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, bridge.name)
            }
            guard coreAudio.supportsSampleRate(uid: output.id, rate: rate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, output.name)
            }

            try dependencies.validateConfiguration(configBuilder.build(profile: profile, parsed: parsed))

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

    func renameProfile(id: UUID, to requestedName: String) {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = profiles.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles.profiles[index].name != name else { return }
        guard ProfileNamePolicy.isAvailable(name, in: profiles.profiles, excluding: id) else {
            errorMessage = "A profile named \"\(name)\" already exists. Profile names must be unique."
            return
        }

        profiles.profiles[index].name = name

        do {
            // The driver keeps the profile UID on the same native endpoint, so
            // renaming changes the selected device without replacing it.
            try coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )

            errorMessage = nil
        } catch {
            errorMessage = "The profile was renamed, but its macOS audio device could not be updated: \(error.localizedDescription)"
        }
    }

    func setProfileEnabled(id: UUID, enabled: Bool) async {
        guard let profile = profiles.profiles.first(where: { $0.id == id }),
              profile.isEnabled != enabled else { return }

        profiles.setProfileEnabled(profileID: id, enabled: enabled)
        if !enabled, activeProfileID == id {
            await deactivate(manual: false)
        } else {
            // Move away from a disabled profile endpoint before removing it;
            // Core Audio cannot destroy a device while it is the default.
            if !enabled,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == id,
               coreAudio.device(uid: profile.outputDeviceUID) != nil {
                try? coreAudio.setDefaultOutput(uid: profile.outputDeviceUID)
            }
            _ = try? coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
        }
        if enabled { await monitorRouting() }
    }

    func setAutomaticProfile(
        for physicalDevice: PhysicalOutputIdentity,
        profileID: UUID?
    ) async {
        profiles.setAutomaticProfile(physicalDevice: physicalDevice, profileID: profileID)
        if let profileID {
            profiles.setAutoActivateWhenProfileDeviceSelected(profileID: profileID, enabled: false)
        }
        if profileID != nil { await monitorRouting() }
    }

    func setAutoActivateWhenProfileDeviceSelected(id: UUID, enabled: Bool) async {
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        if enabled,
           profiles.automaticProfileID(forPhysicalDeviceUID: profile.outputDeviceUID) == id {
            profiles.setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: nil)
        }
        profiles.setAutoActivateWhenProfileDeviceSelected(profileID: id, enabled: enabled)

        if !enabled,
           !isActive,
           coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == id,
           coreAudio.device(uid: profile.outputDeviceUID) != nil {
            try? coreAudio.setDefaultOutput(uid: profile.outputDeviceUID)
        }
        if enabled { await monitorRouting() }
        else {
            _ = try? coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
        }
    }

    func activate(
        profile: DeviceProfile,
        reportErrors: Bool = true,
        automatic: Bool = false
    ) async {
        guard !transitionInProgress else { return }
        transitionInProgress = true
        defer { transitionInProgress = false }
        let activationOriginUID = coreAudio.defaultOutputUID

        do {
            guard profile.isEnabled else { throw AppError.profileDisabled(profile.name) }
            dependencies.refresh()
            guard FileManager.default.isExecutableFile(atPath: dependencies.camillaDSPBinary.path) else {
                throw AppError.missingCamillaDSP
            }
            guard let bridge = coreAudio.systemAudioBridge else { throw AppError.missingRoutingDriver }
            guard coreAudio.isSystemAudioBridgePresentationSupported else {
                throw AppError.outdatedRoutingDriver
            }
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            guard !output.isRoutingDevice else { throw AppError.invalidTarget }
            guard let parsed = validate(profile: profile) else { return }
            let sampleRate = Double(profile.sampleRate)
            guard coreAudio.supportsSampleRate(uid: bridge.id, rate: sampleRate) else {
                throw AppError.unsupportedSampleRate(profile.sampleRate, bridge.name)
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
                activeSession = nil
                activeSampleRate = nil
            }

            _ = try coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: nil,
                additionallyVisible: [profile.id]
            )
            guard let routing = await coreAudio.waitForProfileRoutingDevice(profileID: profile.id) else {
                throw AppError.profileRoutingDeviceMissing(profile.name)
            }

            // Native profile endpoints share this bridge's PCM stream. Keep
            // the generic transport hidden so Sound Settings exposes only the
            // stable, volume-capable profile device.
            try coreAudio.setSystemAudioBridgePresentation(
                name: AudioDeviceInfo.systemAudioBridgeName,
                visible: false
            )

            if coreAudio.defaultOutputUID != routing.id,
               coreAudio.defaultOutputUID != bridge.id,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == nil {
                previousDefaultUID = coreAudio.defaultOutputUID
            }
            activeRoutingUID = routing.id

            try await coreAudio.setSampleRate(uid: output.id, rate: sampleRate)
            try await coreAudio.setSampleRate(uid: bridge.id, rate: sampleRate)

            try await dsp.start(binary: dependencies.camillaDSPBinary)
            let camillaOutputs = try await dsp.rpc.availablePlaybackDevices(backend: "CoreAudio")
            guard camillaOutputs.contains(where: { $0.identifier == profile.outputDeviceUID }) else {
                throw AppError.camillaDSPCoreAudioUIDUnsupported
            }
            let yaml = configBuilder.build(profile: profile, parsed: parsed)
            try await dsp.apply(yaml: yaml)

            let runtimeSession = AudioRuntimeSession(profileID: profile.id)
            pcmRouter.start(
                camillaSink: try dsp.audioInputHandle(),
                analyzerConsumer: { [weak spectrum] frame in
                    spectrum?.ingest(
                        interleaved: frame.interleaved,
                        channelCount: frame.channelCount,
                        sampleRate: frame.sampleRate,
                        session: runtimeSession
                    )
                }
            )
            try driverTransport.start(
                deviceObjectID: bridge.objectID,
                expectedChannelCount: 2,
                expectedSampleRate: sampleRate,
                pcmRouter: pcmRouter
            )

            // Switch only when activation did not originate from this profile
            // output. The same Core Audio object remains selected afterward.
            if coreAudio.defaultOutputUID != routing.id {
                try await coreAudio.setDefaultOutputAndWait(uid: routing.id)
            }

            volumeBridge.start(
                routingDevice: routing,
                physicalUID: output.id,
                coreAudio: coreAudio
            ) { [weak self] volume in
                guard let self,
                      let index = self.profiles.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                self.profiles.profiles[index].outputVolumeScalar = volume
            }

            activeSession = runtimeSession
            activeSampleRate = profile.sampleRate
            isActive = true
            meters.start(rpc: dsp.rpc, session: runtimeSession)
            spectrum.start(session: runtimeSession, sourceName: "System Audio Bridge")
            _ = try? coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: profile.id
            )
            suppressedAutoUID = nil
            errorMessage = nil
            notifications.activated()
        } catch {
            if reportErrors || shouldAlwaysReport(error) {
                errorMessage = error.localizedDescription
            }
            if automatic, activationOriginUID == profile.outputDeviceUID {
                // A failed physical-output activation must not republish and
                // remove the profile endpoint once per monitor tick. Retry
                // after the user changes away from this physical output.
                suppressedAutoUID = profile.outputDeviceUID
            }
            await stopProcessingPipeline()
            if let routingUID = activeRoutingUID,
               coreAudio.defaultOutputUID == routingUID {
                let restore = previousDefaultUID.flatMap { coreAudio.device(uid: $0) != nil ? $0 : nil } ?? profile.outputDeviceUID
                try? coreAudio.setDefaultOutput(uid: restore)
            }
            isActive = false
            activeSession = nil
            activeSampleRate = nil
            activeRoutingUID = nil
            try? coreAudio.setSystemAudioBridgePresentation(
                name: "System Audio Bridge",
                visible: false
            )
            _ = try? coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: nil
            )
        }
    }

    func apply(profile: DeviceProfile) async {
        latestApplyRequest &+= 1
        let request = latestApplyRequest
        guard let parsed = validate(profile: profile) else { return }
        guard isActive, activeProfileID == profile.id else { return }
        if activeSampleRate != profile.sampleRate {
            if let problem = processingSampleRateProblem(
                rate: profile.sampleRate,
                outputUID: profile.outputDeviceUID
            ) {
                errorMessage = problem
                return
            }
            await deactivate(manual: false)
            await activate(profile: profile)
            return
        }
        do {
            guard coreAudio.device(uid: profile.outputDeviceUID) != nil else {
                throw AppError.outputMissing(profile.outputDeviceName)
            }
            let yaml = configBuilder.build(profile: profile, parsed: parsed)
            try await dsp.apply(yaml: yaml)
            guard request == latestApplyRequest, !Task.isCancelled else { return }
            errorMessage = nil
        } catch is CancellationError {
            // Dragging again intentionally supersedes an in-flight live update.
        } catch {
            guard request == latestApplyRequest else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deactivate(manual: Bool = true, restoreOutput: Bool = true) async {
        guard !transitionInProgress else { return }
        latestApplyRequest &+= 1
        transitionInProgress = true
        defer { transitionInProgress = false }

        let targetUID = activeProfileID.flatMap { id in profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID }

        await stopProcessingPipeline()

        if restoreOutput {
            let restore = previousDefaultUID.flatMap { coreAudio.device(uid: $0) != nil ? $0 : nil } ?? targetUID
            if let restore { try? coreAudio.setDefaultOutput(uid: restore) }
        }

        try? coreAudio.setSystemAudioBridgePresentation(
            name: "System Audio Bridge",
            visible: false
        )

        isActive = false
        activeSession = nil
        activeSampleRate = nil
        activeRoutingUID = nil
        previousDefaultUID = nil
        if manual { suppressedAutoUID = targetUID }
        _ = try? coreAudio.synchronizeProfileRoutingDevices(
            profiles: profiles.profiles,
            activeProfileID: nil
        )
        notifications.deactivated()
    }

    private func stopProcessingPipeline() async {
        meters.stop()
        volumeBridge.stop()
        driverTransport.stop()
        pcmRouter.stop()
        spectrum.stop()
        await dsp.stop()
    }

    private func monitorRouting() async {
        guard !transitionInProgress else { return }
        do {
            try coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )
        } catch {
            // Setup presents missing/incompatible-driver errors. Avoid showing
            // the same background registry failure once per monitor tick.
        }
        if isActive {
            if let runtimeError = driverTransport.runtimeError {
                errorMessage = runtimeError
                await deactivate(manual: false)
                return
            }
            if let activeSampleRate,
               let activeProfileID,
               let activeProfile = profiles.profiles.first(where: { $0.id == activeProfileID }),
               let actualRate = coreAudio.nominalSampleRate(uid: activeProfile.outputDeviceUID),
               abs(actualRate - Double(activeSampleRate)) >= 0.5 {
                errorMessage = AppError.runtimeSampleRateMismatch(
                    expected: activeSampleRate,
                    actual: actualRate,
                    device: activeProfile.outputDeviceName
                ).localizedDescription
                await deactivate(manual: false)
                return
            }
            if let activeProfileID,
               profiles.profiles.first(where: { $0.id == activeProfileID })?.isEnabled == false {
                await deactivate(manual: false)
                return
            }
            if let activeProfileID,
               let activeProfile = profiles.profiles.first(where: { $0.id == activeProfileID }),
               coreAudio.device(uid: activeProfile.outputDeviceUID) == nil {
                await deactivate(manual: false, restoreOutput: false)
                return
            }
            guard let routing = activeRoutingUID.flatMap({ coreAudio.device(uid: $0) }) else {
                await deactivate(manual: false, restoreOutput: false)
                return
            }

            // If the user picks another macOS output while EQ is active, respect it.
            if coreAudio.defaultOutputUID != routing.id {
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
        if let currentDevice = coreAudio.device(uid: current),
           !currentDevice.isRoutingDevice,
           let profile = profiles.automaticProfile(forPhysicalDeviceUID: current) {
            await activate(profile: profile, reportErrors: false, automatic: true)
            return
        }

        if let selectedProfileID = ProfileRoutingDescriptor.profileID(from: current),
           let selectedProfile = profiles.profiles.first(where: {
               $0.id == selectedProfileID
                   && $0.isEnabled
                   && $0.autoActivateWhenProfileDeviceSelected
                   && coreAudio.device(uid: $0.outputDeviceUID) != nil
           }) {
            await activate(profile: selectedProfile, reportErrors: false, automatic: true)
        }
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        shutdownSynchronously()
        updateChecker.installPreparedUpdateAfterExit()
    }

    private func shutdownSynchronously() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        meters.stop()
        volumeBridge.stop()
        driverTransport.stop()
        pcmRouter.stop()
        spectrum.stop()

        if let routingUID = activeRoutingUID,
           coreAudio.defaultOutputUID == routingUID {
            let targetUID = activeProfileID.flatMap { id in profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID }
            let restore = previousDefaultUID ?? targetUID
            if let restore { try? coreAudio.setDefaultOutput(uid: restore) }
        }
        try? coreAudio.setSystemAudioBridgePresentation(
            name: "System Audio Bridge",
            visible: false
        )
        let cleanupFallbackUID = activeProfileID.flatMap { id in
            profiles.profiles.first(where: { $0.id == id })?.outputDeviceUID
        } ?? previousDefaultUID
        coreAudio.destroyAllProfileRoutingDevices(fallbackUID: cleanupFallbackUID)
        dsp.forceStopAndWait()
        isActive = false
        activeSession = nil
        activeSampleRate = nil
        activeRoutingUID = nil
        previousDefaultUID = nil
    }

    private func shouldAlwaysReport(_ error: Error) -> Bool {
        if let appError = error as? AppError {
            switch appError {
            case .profileRoutingDeviceMissing, .unsupportedSampleRate,
                    .camillaDSPCoreAudioUIDUnsupported:
                return true
            default:
                break
            }
        }
        if let audioError = error as? CoreAudioManager.AudioError {
            switch audioError {
            case .sampleRateNotSettable, .sampleRateDidNotApply,
                    .defaultOutputDidNotApply:
                return true
            default:
                break
            }
        }
        return false
    }

    enum AppError: LocalizedError {
        case missingCamillaDSP
        case missingRoutingDriver
        case outdatedRoutingDriver
        case outputMissing(String)
        case invalidTarget
        case profileDisabled(String)
        case profileRoutingDeviceMissing(String)
        case unsupportedSampleRate(Int, String)
        case camillaDSPCoreAudioUIDUnsupported
        case runtimeSampleRateMismatch(expected: Int, actual: Double, device: String)
        var errorDescription: String? {
            switch self {
            case .missingCamillaDSP: return "CamillaDSP is not installed. Open Setup and install it first."
            case .missingRoutingDriver: return "System Audio Bridge is not installed or visible to CoreAudio. Open Setup to install the bundled driver."
            case .outdatedRoutingDriver: return "The installed audio routing driver is outdated. Open Setup and select Install / Repair Everything."
            case .outputMissing(let name): return "The selected output device is not connected: \(name)"
            case .invalidTarget: return "The virtual routing device cannot be used as the physical playback target."
            case .profileDisabled(let name): return "Activate the \(name) profile before using its EQ activation conditions."
            case .profileRoutingDeviceMissing(let name): return "CoreAudio did not create the \(name) profile audio device."
            case .unsupportedSampleRate(let rate, let device): return "\(device) does not report support for the selected \(Double(rate) / 1000) kHz sample rate."
            case .camillaDSPCoreAudioUIDUnsupported:
                return "The installed CamillaDSP build cannot select Core Audio devices by UID. Open Setup and select Install / Repair Everything."
            case .runtimeSampleRateMismatch(let expected, let actual, let device):
                return "\(device) changed to \(String(format: "%.1f", actual / 1_000)) kHz while this profile requires \(String(format: "%.1f", Double(expected) / 1_000)) kHz. Processing was stopped to prevent wrong-speed or corrupted audio."
            }
        }
    }
}
