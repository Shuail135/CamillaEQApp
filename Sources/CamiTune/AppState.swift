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

        if audio.isSystemAudioBridgePresentationSupported {
            try? audio.setSystemAudioBridgePresentation(
                name: "System Audio Bridge",
                visible: false
            )
        }
        let staleProfileID = audio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:))
        let cleanupFallbackUID = staleProfileID.flatMap { profileID in
            profiles.profiles.first(where: { $0.id == profileID })?.outputDeviceUID
        }
        audio.destroyAllProfileRoutingDevices(fallbackUID: cleanupFallbackUID)

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

    func renameProfile(id: UUID, to requestedName: String) {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = profiles.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles.profiles[index].name != name else { return }

        profiles.profiles[index].name = name
        let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles.profiles)

        do {
            // The active route is the real bridge, not an aggregate selector,
            // so complete that handoff and remove any stale selector before
            // giving the bridge the new name. This prevents Sound Settings
            // from seeing two live devices with the same profile name.
            if activeProfileID == id {
                // Normally activation has already removed the selector. Do
                // not reassign the current default output on every rename:
                // that makes Core Audio rebuild its presentation cache and
                // delays the visible name update. Perform the handoff only
                // when a selector genuinely survived activation.
                if coreAudio.profileRoutingDevice(profileID: id) != nil {
                    if let activeRoutingUID,
                       coreAudio.defaultOutputUID != activeRoutingUID {
                        try coreAudio.setDefaultOutput(uid: activeRoutingUID)
                    }
                    try coreAudio.removeProfileRoutingDevice(profileID: id)
                }
            }

            // Rename selector aggregates first. The device-list refresh below
            // must happen after this write or Sound Settings can re-cache the
            // previous name.
            try coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: activeProfileID
            )

            if let activeProfileID,
               let activeDescriptor = descriptors[activeProfileID] {
                // This both updates an active bridge name and makes macOS
                // re-read any inactive selector renamed in the same pass.
                try coreAudio.refreshSystemAudioBridgePresentation(
                    name: activeDescriptor.name
                )
            } else if coreAudio.profileRoutingDevice(profileID: id) != nil {
                // With EQ inactive, use the hidden bridge only to produce a
                // real device-list refresh after the selector rename.
                try coreAudio.refreshDeviceListKeepingSystemAudioBridgeHidden()
            }
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
            // A profile selector is only a short-lived aggregate and does not
            // provide normal macOS volume controls. If the profile is disabled
            // before the monitor finishes activating it, move the route back
            // to its physical output before removing the selector.
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

    func setAutoActivate(id: UUID, enabled: Bool) async {
        profiles.setAutoActivate(profileID: id, enabled: enabled)
        if enabled { await monitorRouting() }
    }

    func setAutoActivateWhenProfileDeviceSelected(id: UUID, enabled: Bool) async {
        guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
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

    func activate(profile: DeviceProfile, reportErrors: Bool = true) async {
        guard !transitionInProgress else { return }
        transitionInProgress = true
        defer { transitionInProgress = false }

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
            guard let output = coreAudio.device(uid: profile.outputDeviceUID) else { throw AppError.outputMissing(profile.outputDeviceName) }
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
                activeProfileID = nil
                activeSampleRate = nil
            }

            // The aggregate already exists when a profile was selected from
            // macOS. Manual and physical-output activation do not need to
            // create a temporary aggregate merely to calculate the name.
            let descriptors = ProfileRoutingDescriptor.descriptors(for: profiles.profiles)
            guard let descriptor = descriptors[profile.id] else {
                throw AppError.profileRoutingDeviceMissing(profile.name)
            }

            // Aggregate profile devices are only selectors. Once selected, the
            // real driver adopts the collision-safe profile name so macOS uses
            // its native volume and mute controls.
            try coreAudio.setSystemAudioBridgePresentation(
                name: descriptor.name,
                visible: true
            )
            guard let routing = coreAudio.systemAudioBridge else {
                throw AppError.missingRoutingDriver
            }

            if coreAudio.defaultOutputUID != descriptor.uid,
               coreAudio.defaultOutputUID != bridge.id,
               coreAudio.defaultOutputUID.flatMap(ProfileRoutingDescriptor.profileID(from:)) == nil {
                previousDefaultUID = coreAudio.defaultOutputUID
            }
            activeRoutingUID = routing.id

            try coreAudio.setSampleRate(uid: bridge.id, rate: sampleRate)

            try await dsp.start(binary: dependencies.camillaDSPBinary)
            var resolvedProfile = profile
            resolvedProfile.outputDeviceName = output.name
            let yaml = configBuilder.build(profile: resolvedProfile, parsed: parsed)
            try await dsp.apply(yaml: yaml)

            try driverTransport.start(
                deviceObjectID: bridge.objectID,
                expectedChannelCount: 2,
                audioSink: try dsp.audioInputHandle(),
                spectrum: spectrum
            )

            // Switch system audio only after the DSP is ready to receive frames.
            try coreAudio.setDefaultOutput(uid: routing.id)

            volumeBridge.start(
                routingDevice: routing,
                physicalUID: output.id,
                coreAudio: coreAudio
            ) { [weak self] volume in
                guard let self,
                      let index = self.profiles.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                self.profiles.profiles[index].outputVolumeScalar = volume
            }

            meters.start(rpc: dsp.rpc)

            activeProfileID = profile.id
            activeSampleRate = profile.sampleRate
            isActive = true
            _ = try? coreAudio.synchronizeProfileRoutingDevices(
                profiles: profiles.profiles,
                activeProfileID: profile.id
            )
            suppressedAutoUID = nil
            errorMessage = nil
            notifications.activated()
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
            await stopProcessingPipeline()
            if let routingUID = activeRoutingUID,
               coreAudio.defaultOutputUID == routingUID {
                let restore = previousDefaultUID.flatMap { coreAudio.device(uid: $0) != nil ? $0 : nil } ?? profile.outputDeviceUID
                try? coreAudio.setDefaultOutput(uid: restore)
            }
            isActive = false
            activeProfileID = nil
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
        activeProfileID = nil
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
        let reboundProfileIDs = profiles.reconcileDevices(coreAudio.outputDevices)

        if isActive {
            if let activeProfileID,
               profiles.profiles.first(where: { $0.id == activeProfileID })?.isEnabled == false {
                await deactivate(manual: false)
                return
            }
            if let activeProfileID,
               reboundProfileIDs.contains(activeProfileID),
               let reboundProfile = profiles.profiles.first(where: { candidate in
                   candidate.id == activeProfileID
               }) {
                await deactivate(manual: false, restoreOutput: false)
                await activate(profile: reboundProfile, reportErrors: false)
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

            if let activeProfileID,
               let descriptor = ProfileRoutingDescriptor.descriptors(
                   for: profiles.profiles
               )[activeProfileID],
               routing.name != descriptor.name {
                try? coreAudio.setSystemAudioBridgePresentation(
                    name: descriptor.name,
                    visible: true
                )
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
        if let profile = profiles.profiles.first(where: {
            $0.isEnabled
                && $0.autoActivate
                && $0.outputDeviceUID == current
                && coreAudio.device(uid: $0.outputDeviceUID) != nil
        }) {
            await activate(profile: profile, reportErrors: false)
            return
        }

        if let selectedProfileID = ProfileRoutingDescriptor.profileID(from: current),
           let selectedProfile = profiles.profiles.first(where: {
               $0.id == selectedProfileID
                   && $0.isEnabled
                   && $0.autoActivateWhenProfileDeviceSelected
                   && coreAudio.device(uid: $0.outputDeviceUID) != nil
           }) {
            await activate(profile: selectedProfile, reportErrors: false)
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
        activeProfileID = nil
        activeSampleRate = nil
        activeRoutingUID = nil
        previousDefaultUID = nil
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
            }
        }
    }
}
