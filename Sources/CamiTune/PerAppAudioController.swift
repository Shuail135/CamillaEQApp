import AppKit
import Combine
import Darwin
import Foundation

struct PerAppAudioSettings: Codable, Hashable, Sendable {
    var volume: Double = 1
    var isMuted = false
    var eqBypassed = false
    var equalizerBands: [EQBand] = []
}

struct PerAppAudioApplication: Identifiable, Hashable, Sendable {
    var id: String
    var bundleID: String?
    var bundleURL: URL?
    var processID: Int32
    var displayName: String
    var isActive: Bool
    var level: Double
    var settings: PerAppAudioSettings
}

struct PerAppDriverClient: Hashable, Sendable {
    var clientID: UInt32
    var processID: Int32
    var bundleID: String?
    var isActive: Bool
    var generation: UInt64

    var applicationKey: String {
        if let bundleID = PerAppAudioController.canonicalApplicationBundleID(bundleID) {
            return bundleID
        }
        return "pid:\(processID)"
    }
}

struct PerAppAudioPacket: Sendable {
    var clientID: UInt32
    var cycleCounter: UInt64
    var sampleTime: Double
    var interleaved: [Float]
    var channelCount: Int
    var sampleRate: Double
    var channelLayout: LPCMChannelLayout
    var sourceBufferedFrames: Int
    var sourceCapacityFrames: Int

    init(
        clientID: UInt32,
        cycleCounter: UInt64,
        sampleTime: Double,
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        channelLayout: LPCMChannelLayout? = nil,
        sourceBufferedFrames: Int,
        sourceCapacityFrames: Int
    ) {
        self.clientID = clientID
        self.cycleCounter = cycleCounter
        self.sampleTime = sampleTime
        self.interleaved = interleaved
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
            ?? LPCMChannelLayout.canonical(forChannelCount: channelCount)
            ?? LPCMChannelLayout(
                coreAudioTag: 0,
                roles: [ChannelRole](repeating: .unknown, count: max(0, channelCount))
            )
        self.sourceBufferedFrames = sourceBufferedFrames
        self.sourceCapacityFrames = sourceCapacityFrames
    }
}

/// Owns client identity, persisted per-application controls, per-client EQ
/// state, and the pre-global-DSP application mixer.
final class PerAppAudioController: ObservableObject, @unchecked Sendable {
    @Published private(set) var applications: [PerAppAudioApplication] = []

    private struct PendingMix {
        var cycleCounter: UInt64
        var sampleTime: Double
        var channelCount: Int
        var sampleRate: Double
        var channelLayout: LPCMChannelLayout
        var sourceBufferedFrames: Int
        var sourceCapacityFrames: Int
        var clientIDs: Set<UInt32>
        var samples: [Float]
        var lastPacketDate: Date
    }

    private struct HeadroomKey: Hashable {
        var applicationID: String
        var sampleRate: Double
        var bands: [EQBand]
    }

    private struct ApplicationIdentity: Hashable {
        var id: String
        var bundleID: String?
        var bundleURL: URL?
        var processID: Int32
        var displayName: String
        var isDockApplication: Bool
        var isAccessoryApplication: Bool
    }

    private static let applicationActivityFloor = pow(10.0, -72.0 / 20.0)
    private static let meterDecayTime: TimeInterval = 0.8
    private static let publishInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private let settingsURL: URL
    private let audioHistoryURL: URL
    private let monitorsRunningApplications: Bool
    private let persistenceQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioSettings",
        qos: .utility
    )
    private let identityQueue = DispatchQueue(
        label: "CamiTune.PerAppAudioIdentity",
        qos: .userInitiated
    )
    private let runningApplicationQueue = DispatchQueue(
        label: "CamiTune.RunningApplicationRoster",
        qos: .utility
    )
    private var clientsByID: [UInt32: PerAppDriverClient] = [:]
    private var identitiesByClientID: [UInt32: ApplicationIdentity] = [:]
    private var runningApplicationsByID: [String: ApplicationIdentity] = [:]
    private var settingsByApplication: [String: PerAppAudioSettings]
    private var knownAudioApplicationIDs: Set<String>
    private var levelsByApplication: [String: Double] = [:]
    private var lastAudibleDateByApplication: [String: Date] = [:]
    private var lastPacketDateByApplication: [String: Date] = [:]
    private var lastMeterUpdateByApplication: [String: Date] = [:]
    private var filterBanks: [UInt32: PerAppFilterBank] = [:]
    private var headroomScalars: [HeadroomKey: Float] = [:]
    private var pendingMix: PendingMix?
    private var pendingPersistence: DispatchWorkItem?
    private var pendingHistoryPersistence: DispatchWorkItem?
    private var pendingRunningApplicationRefresh: DispatchWorkItem?
    private var pendingApplicationSnapshot: [PerAppAudioApplication]?
    private var mainPublishScheduled = false
    private var lastPublishDate = Date.distantPast
    private var identityResolutionRevision: UInt64 = 0
    private var meterPresentationSources: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        settingsURL: URL = CamiTunePaths.perAppAudioSettingsURL,
        audioHistoryURL: URL? = nil,
        monitorsRunningApplications: Bool = true
    ) {
        self.settingsURL = settingsURL
        self.audioHistoryURL = audioHistoryURL
            ?? settingsURL.appendingPathExtension("history")
        self.monitorsRunningApplications = monitorsRunningApplications
        settingsByApplication = Self.loadSettings(from: settingsURL)
        knownAudioApplicationIDs = Self.loadAudioHistory(
            from: self.audioHistoryURL
        )
        if monitorsRunningApplications {
            observeWorkspaceApplications()
            scheduleRunningApplicationRefresh(immediate: true)
        }
        publishApplications(force: true)
    }

    deinit {
        pendingPersistence?.cancel()
        pendingHistoryPersistence?.cancel()
        pendingRunningApplicationRefresh?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        let settings = settingsByApplication
        let audioHistory = knownAudioApplicationIDs
        let url = settingsURL
        let historyURL = audioHistoryURL
        persistenceQueue.sync {
            Self.persist(settings, to: url)
            Self.persistAudioHistory(audioHistory, to: historyURL)
        }
    }

    func updateClients(_ clients: [PerAppDriverClient]) {
        let nextClients = Dictionary(
            clients.map { ($0.clientID, $0) },
            uniquingKeysWith: { current, candidate in
                current.generation >= candidate.generation ? current : candidate
            }
        )
        lock.lock()
        let clientsChanged = clientsByID != nextClients
        guard clientsChanged else {
            lock.unlock()
            return
        }
        clientsByID = nextClients
        filterBanks = filterBanks.filter { clientsByID[$0.key] != nil }
        identityResolutionRevision &+= 1
        let revision = identityResolutionRevision
        lock.unlock()

        // Looking up NSRunningApplication, nested bundles, and application
        // metadata can trigger Launch Services disk work. Never do that on the
        // transport reader that is responsible for keeping audio flowing.
        identityQueue.async {
            let resolvedIdentities = Dictionary(
                uniqueKeysWithValues: clients.compactMap { client in
                    Self.resolveApplicationIdentity(for: client).map {
                        (client.clientID, $0)
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.identityResolutionRevision == revision else {
                    self.lock.unlock()
                    return
                }
                self.identitiesByClientID = resolvedIdentities
                var settingsChanged = false
                var audioHistoryChanged = false
                for client in clients {
                    guard let identity = resolvedIdentities[client.clientID] else { continue }
                    let temporaryID = client.applicationKey
                    guard identity.id != temporaryID else { continue }
                    if self.settingsByApplication[identity.id] == nil,
                       let legacy = self.settingsByApplication[temporaryID] {
                        self.settingsByApplication[identity.id] = legacy
                        settingsChanged = true
                    }
                    if let temporaryLevel = self.levelsByApplication.removeValue(forKey: temporaryID) {
                        self.levelsByApplication[identity.id] = max(
                            self.levelsByApplication[identity.id] ?? 0,
                            temporaryLevel
                        )
                    }
                    Self.moveLatestDate(
                        from: temporaryID,
                        to: identity.id,
                        in: &self.lastAudibleDateByApplication
                    )
                    Self.moveLatestDate(
                        from: temporaryID,
                        to: identity.id,
                        in: &self.lastPacketDateByApplication
                    )
                    Self.moveLatestDate(
                        from: temporaryID,
                        to: identity.id,
                        in: &self.lastMeterUpdateByApplication
                    )
                    if self.lastAudibleDateByApplication[identity.id] != nil,
                       identity.bundleID?.isEmpty == false,
                       self.knownAudioApplicationIDs.insert(identity.id).inserted {
                        audioHistoryChanged = true
                    }
                }
                let savedSettings = self.settingsByApplication
                let savedAudioHistory = self.knownAudioApplicationIDs
                self.lock.unlock()
                if settingsChanged {
                    self.schedulePersistence(savedSettings)
                }
                if audioHistoryChanged {
                    self.scheduleAudioHistoryPersistence(savedAudioHistory)
                }
                self.publishApplications(force: true)
            }
        }
    }

    func settings(for applicationID: String) -> PerAppAudioSettings {
        lock.lock()
        defer { lock.unlock() }
        return settingsByApplication[applicationID] ?? PerAppAudioSettings()
    }

    func hasProducedAudio(for applicationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return knownAudioApplicationIDs.contains(applicationID)
    }

    func setVolume(_ volume: Double, for applicationID: String) {
        updateSettings(for: applicationID) {
            $0.volume = min(max(volume, 0), 1)
        }
    }

    func setMeterPresentationActive(_ active: Bool, source: String) {
        lock.lock()
        if active {
            meterPresentationSources.insert(source)
        } else {
            meterPresentationSources.remove(source)
        }
        lock.unlock()
        if active {
            scheduleRunningApplicationRefresh(immediate: true)
            publishApplications(force: true)
        }
    }

    func setMuted(_ muted: Bool, for applicationID: String) {
        updateSettings(for: applicationID) { $0.isMuted = muted }
    }

    func setEQBypassed(_ bypassed: Bool, for applicationID: String) {
        updateSettings(
            for: applicationID,
            resetFilterState: true,
            resetHeadroom: true
        ) { $0.eqBypassed = bypassed }
    }

    func setEqualizerBands(_ bands: [EQBand], for applicationID: String) {
        updateSettings(
            for: applicationID,
            resetFilterState: true,
            resetHeadroom: true
        ) { $0.equalizerBands = bands }
    }

    func ingest(_ packet: PerAppAudioPacket) -> PCMFrame? {
        guard packet.channelCount > 0,
              packet.sampleRate > 0,
              packet.interleaved.count % packet.channelCount == 0 else { return nil }

        lock.lock()
        let completed: PCMFrame?
        if let pendingMix,
           pendingMix.sampleTime != packet.sampleTime ||
            pendingMix.channelCount != packet.channelCount ||
            pendingMix.sampleRate != packet.sampleRate ||
            pendingMix.channelLayout != packet.channelLayout ||
            pendingMix.samples.count != packet.interleaved.count {
            completed = frame(from: pendingMix)
            self.pendingMix = nil
        } else {
            completed = nil
        }

        let now = Date()
        let client = clientsByID[packet.clientID]
        let identity = identitiesByClientID[packet.clientID]
        let applicationID = identity?.id
            ?? client?.applicationKey
            ?? "client:\(packet.clientID)"
        let settings = settingsByApplication[applicationID] ?? PerAppAudioSettings()
        let rawPeak = packet.interleaved.reduce(0.0) { max($0, Double(abs($1))) }
        lastPacketDateByApplication[applicationID] = now
        var audioHistoryToPersist: Set<String>?
        if rawPeak >= Self.applicationActivityFloor {
            lastAudibleDateByApplication[applicationID] = now
            if identity?.bundleID?.isEmpty == false || client?.bundleID?.isEmpty == false,
               knownAudioApplicationIDs.insert(applicationID).inserted {
                audioHistoryToPersist = knownAudioApplicationIDs
            }
        }
        var processed = packet.interleaved
        if settings.isMuted {
            processed = [Float](repeating: 0, count: processed.count)
        } else {
            if !settings.eqBypassed && !settings.equalizerBands.isEmpty {
                var bank = filterBanks[packet.clientID] ?? PerAppFilterBank()
                bank.process(
                    &processed,
                    channelCount: packet.channelCount,
                    sampleRate: packet.sampleRate,
                    bands: settings.equalizerBands
                )
                filterBanks[packet.clientID] = bank
            }
            let headroomKey = HeadroomKey(
                applicationID: applicationID,
                sampleRate: packet.sampleRate,
                bands: settings.equalizerBands
            )
            let eqHeadroom: Float
            if settings.eqBypassed {
                eqHeadroom = 1
            } else {
                eqHeadroom = headroomScalars[headroomKey]
                    ?? Self.headroomScalar(settings, sampleRate: packet.sampleRate)
                headroomScalars[headroomKey] = eqHeadroom
            }
            let scalar = Float(settings.volume) * eqHeadroom
            if scalar != 1 {
                for index in processed.indices { processed[index] *= scalar }
            }
        }
        let outputPeak = processed.reduce(0.0) { max($0, Double(abs($1))) }
        let elapsed = now.timeIntervalSince(
            lastMeterUpdateByApplication[applicationID] ?? now
        )
        let decayedLevel = (levelsByApplication[applicationID] ?? 0)
            * Self.meterDecayFactor(elapsed: elapsed)
        levelsByApplication[applicationID] = max(
            Self.normalizedMeterLevel(forPeak: outputPeak),
            decayedLevel
        )
        lastMeterUpdateByApplication[applicationID] = now

        if self.pendingMix == nil {
            self.pendingMix = PendingMix(
                cycleCounter: packet.cycleCounter,
                sampleTime: packet.sampleTime,
                channelCount: packet.channelCount,
                sampleRate: packet.sampleRate,
                channelLayout: packet.channelLayout,
                sourceBufferedFrames: packet.sourceBufferedFrames,
                sourceCapacityFrames: packet.sourceCapacityFrames,
                clientIDs: [packet.clientID],
                samples: processed,
                lastPacketDate: now
            )
        } else {
            let count = min(self.pendingMix!.samples.count, processed.count)
            for index in 0..<count { self.pendingMix!.samples[index] += processed[index] }
            self.pendingMix!.sourceBufferedFrames = max(
                self.pendingMix!.sourceBufferedFrames,
                packet.sourceBufferedFrames
            )
            self.pendingMix!.clientIDs.insert(packet.clientID)
            self.pendingMix!.lastPacketDate = now
        }
        lock.unlock()
        if let audioHistoryToPersist {
            scheduleAudioHistoryPersistence(audioHistoryToPersist)
        }
        publishApplications()
        return completed
    }

    func flushExpiredMix() -> PCMFrame? {
        lock.lock()
        let now = Date()
        guard let pendingMix else {
            decayLevelsLocked(now: now)
            lock.unlock()
            publishApplications()
            return nil
        }
        let frameDuration = Double(pendingMix.samples.count / pendingMix.channelCount)
            / pendingMix.sampleRate
        guard now.timeIntervalSince(pendingMix.lastPacketDate) >= max(0.003, frameDuration) else {
            lock.unlock()
            return nil
        }
        let completed = frame(from: pendingMix)
        self.pendingMix = nil
        decayLevelsLocked(now: now)
        lock.unlock()
        publishApplications()
        return completed
    }

    func resetRuntime() {
        lock.lock()
        pendingMix = nil
        filterBanks.removeAll()
        levelsByApplication.removeAll()
        lastAudibleDateByApplication.removeAll()
        lastPacketDateByApplication.removeAll()
        lastMeterUpdateByApplication.removeAll()
        lock.unlock()
        publishApplications(force: true)
    }

    private func updateSettings(
        for applicationID: String,
        resetFilterState: Bool = false,
        resetHeadroom: Bool = false,
        change: (inout PerAppAudioSettings) -> Void
    ) {
        lock.lock()
        var settings = settingsByApplication[applicationID] ?? PerAppAudioSettings()
        change(&settings)
        settingsByApplication[applicationID] = settings
        if resetHeadroom {
            headroomScalars = headroomScalars.filter { $0.key.applicationID != applicationID }
        }
        if resetFilterState {
            for clientID in clientsByID.values
                .filter({
                    identitiesByClientID[$0.clientID]?.id == applicationID
                        || $0.applicationKey == applicationID
                })
                .map(\.clientID) {
                filterBanks.removeValue(forKey: clientID)
            }
        }
        let saved = settingsByApplication
        lock.unlock()
        schedulePersistence(saved)
        publishApplications(force: true)
    }

    private func frame(from mix: PendingMix) -> PCMFrame {
        let activeClientCount = max(1, mix.clientIDs.count)
        return PCMFrame(
            interleaved: mix.samples,
            channelCount: mix.channelCount,
            sampleRate: mix.sampleRate,
            channelLayout: mix.channelLayout,
            sourceBufferedFrames: mix.sourceBufferedFrames / activeClientCount,
            sourceCapacityFrames: mix.sourceCapacityFrames
        )
    }

    private func decayLevelsLocked(now: Date) {
        for key in levelsByApplication.keys {
            let elapsed = now.timeIntervalSince(lastMeterUpdateByApplication[key] ?? now)
            levelsByApplication[key, default: 0] *= Self.meterDecayFactor(elapsed: elapsed)
            lastMeterUpdateByApplication[key] = now
            if levelsByApplication[key, default: 0] < 0.001 {
                levelsByApplication[key] = 0
            }
        }
    }

    private func publishApplications(force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force && meterPresentationSources.isEmpty {
            lock.unlock()
            return
        }
        if !force && now.timeIntervalSince(lastPublishDate) < Self.publishInterval {
            lock.unlock()
            return
        }
        lastPublishDate = now
        let clients = Array(clientsByID.values)
        let identities = identitiesByClientID
        let runningApplications = runningApplicationsByID
        let settings = settingsByApplication
        let levels = levelsByApplication
        let knownAudioApplications = knownAudioApplicationIDs
        lock.unlock()

        var visibleIdentities = runningApplications.filter { _, identity in
            let hasProducedAudio = knownAudioApplications.contains(identity.id)
            return Self.shouldPresentApplication(
                isDockApplication: identity.isDockApplication,
                isAccessoryApplication: identity.isAccessoryApplication,
                hasProducedAudio: hasProducedAudio
            )
                && (!Self.isKnownNonAudioSystemApplication(bundleID: identity.bundleID)
                    || hasProducedAudio)
        }
        for client in clients where client.isActive {
            guard let identity = identities[client.clientID] else { continue }
            let hasProducedAudio = knownAudioApplications.contains(identity.id)
            guard identity.isDockApplication || hasProducedAudio else { continue }
            guard !Self.isKnownNonAudioSystemApplication(bundleID: identity.bundleID)
                    || hasProducedAudio else { continue }
            if visibleIdentities[identity.id] == nil {
                visibleIdentities[identity.id] = identity
            }
        }

        let snapshot = visibleIdentities.map { applicationID, identity in
            return PerAppAudioApplication(
                id: applicationID,
                bundleID: identity.bundleID,
                bundleURL: identity.bundleURL,
                processID: identity.processID,
                displayName: identity.displayName,
                isActive: true,
                level: levels[applicationID] ?? 0,
                settings: settings[applicationID] ?? PerAppAudioSettings()
            )
        }
        .sorted {
            if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        lock.lock()
        pendingApplicationSnapshot = snapshot
        guard !mainPublishScheduled else {
            lock.unlock()
            return
        }
        mainPublishScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let latest = self.pendingApplicationSnapshot ?? []
            self.pendingApplicationSnapshot = nil
            self.mainPublishScheduled = false
            self.lock.unlock()
            self.applications = latest
        }
    }

    static func normalizedMeterLevel(forPeak peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(1, max(0, (decibels + 72) / 72))
    }

    private static func meterDecayFactor(elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 1 }
        return pow(0.1, elapsed / meterDecayTime)
    }

    private func observeWorkspaceApplications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleRunningApplicationRefresh()
            })
        }
    }

    private func scheduleRunningApplicationRefresh(immediate: Bool = false) {
        guard monitorsRunningApplications else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let resolved = Dictionary(
                NSWorkspace.shared.runningApplications.compactMap {
                    Self.resolveRunningApplicationIdentity($0).map { ($0.id, $0) }
                },
                uniquingKeysWith: { current, candidate in
                    if current.isDockApplication != candidate.isDockApplication {
                        return current.isDockApplication ? current : candidate
                    }
                    return current.processID <= candidate.processID ? current : candidate
                }
            )
            self.lock.lock()
            self.runningApplicationsByID = resolved
            self.pendingRunningApplicationRefresh = nil
            self.lock.unlock()
            self.publishApplications(force: true)
        }

        lock.lock()
        pendingRunningApplicationRefresh?.cancel()
        pendingRunningApplicationRefresh = work
        lock.unlock()
        runningApplicationQueue.asyncAfter(
            deadline: .now() + (immediate ? 0 : 0.1),
            execute: work
        )
    }

    private static func moveLatestDate(
        from sourceID: String,
        to destinationID: String,
        in dates: inout [String: Date]
    ) {
        guard let source = dates.removeValue(forKey: sourceID) else { return }
        dates[destinationID] = max(dates[destinationID] ?? .distantPast, source)
    }

    private static func resolveApplicationIdentity(
        for client: PerAppDriverClient
    ) -> ApplicationIdentity? {
        guard client.processID > 0,
              client.processID != Int32(ProcessInfo.processInfo.processIdentifier) else {
            return nil
        }
        guard !isSystemAudioService(bundleID: client.bundleID) else { return nil }

        let processExists = Darwin.kill(client.processID, 0) == 0 || errno == EPERM
        let running = processExists
            ? NSRunningApplication(processIdentifier: client.processID)
            : nil
        guard running?.isTerminated != true else { return nil }

        let reportedBundleID = running?.bundleIdentifier ?? client.bundleID
        let canonicalBundleID = canonicalApplicationBundleID(reportedBundleID)
        let outerBundleURL = outermostApplicationURL(from: running?.bundleURL)
            ?? ((canonicalBundleID != reportedBundleID) ? canonicalBundleID.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            } : nil)

        let applicationBundle = outerBundleURL.flatMap(Bundle.init(url:))
        let bundleID = applicationBundle?.bundleIdentifier
            ?? canonicalBundleID
            ?? reportedBundleID
        let ownURL = Bundle.main.bundleURL.standardizedFileURL
        let ownBundleID = Bundle.main.bundleIdentifier
        if outerBundleURL?.standardizedFileURL == ownURL
            || (bundleID != nil && bundleID == ownBundleID) {
            return nil
        }
        guard outerBundleURL != nil || bundleID?.isEmpty == false else { return nil }

        let displayName = (applicationBundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (applicationBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running?.localizedName
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "Application"
        guard !isSystemAudioService(
            bundleID: bundleID,
            displayName: displayName
        ) else { return nil }
        let id = bundleID
            ?? outerBundleURL.map { "app:\($0.standardizedFileURL.path)" }
            ?? "pid:\(client.processID)"
        return ApplicationIdentity(
            id: id,
            bundleID: bundleID,
            bundleURL: outerBundleURL,
            processID: client.processID,
            displayName: displayName,
            isDockApplication: running?.activationPolicy == .regular,
            isAccessoryApplication: running?.activationPolicy == .accessory
        )
    }

    static func shouldPresentApplication(
        isDockApplication: Bool,
        isAccessoryApplication: Bool,
        hasProducedAudio: Bool
    ) -> Bool {
        isDockApplication || (isAccessoryApplication && hasProducedAudio)
    }

    /// Apple ships a small group of document, account, and maintenance apps
    /// that do not own a media playback path. Hide those idle Dock processes,
    /// while `publishApplications` still lets direct audio history override
    /// this conservative classification if macOS changes their behavior.
    static func isKnownNonAudioSystemApplication(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return knownNonAudioSystemApplicationBundleIDs.contains(bundleID)
    }

    private static let knownNonAudioSystemApplicationBundleIDs: Set<String> = [
        "com.apple.activitymonitor",
        "com.apple.addressbook",
        "com.apple.automator",
        "com.apple.bluetoothfileexchange",
        "com.apple.calculator",
        "com.apple.colorsyncutility",
        "com.apple.console",
        "com.apple.digitalcolormeter",
        "com.apple.directoryutility",
        "com.apple.diskutility",
        "com.apple.fontbook",
        "com.apple.ical",
        "com.apple.image_capture",
        "com.apple.keychainaccess",
        "com.apple.migrateassistant",
        "com.apple.passwords",
        "com.apple.reminders",
        "com.apple.scripteditor2",
        "com.apple.stickies",
        "com.apple.systemprofiler"
    ]

    private static func resolveRunningApplicationIdentity(
        _ running: NSRunningApplication
    ) -> ApplicationIdentity? {
        guard running.processIdentifier > 0,
              running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              running.isTerminated == false,
              running.activationPolicy == .regular
                || running.activationPolicy == .accessory else {
            return nil
        }

        let reportedBundleID = running.bundleIdentifier
        guard !isSystemAudioService(
            bundleID: reportedBundleID,
            displayName: running.localizedName
        ) else { return nil }
        let canonicalBundleID = canonicalApplicationBundleID(reportedBundleID)
        let outerBundleURL = outermostApplicationURL(from: running.bundleURL)
        let applicationBundle = outerBundleURL.flatMap(Bundle.init(url:))
        let bundleID = applicationBundle?.bundleIdentifier
            ?? canonicalBundleID
            ?? reportedBundleID
        let displayName = (applicationBundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String)
            ?? (applicationBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running.localizedName
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "Application"
        guard !isSystemAudioService(
            bundleID: bundleID,
            displayName: displayName
        ) else { return nil }
        let id = bundleID
            ?? outerBundleURL.map { "app:\($0.standardizedFileURL.path)" }
            ?? "pid:\(running.processIdentifier)"
        return ApplicationIdentity(
            id: id,
            bundleID: bundleID,
            bundleURL: outerBundleURL,
            processID: running.processIdentifier,
            displayName: displayName,
            isDockApplication: running.activationPolicy == .regular,
            isAccessoryApplication: running.activationPolicy == .accessory
        )
    }

    /// Core Audio hosts third-party AudioServerPlugIns in its own service
    /// process. That process is transport plumbing, not an application the
    /// user can control, so it must never become a per-app volume row.
    static func isSystemAudioService(
        bundleID: String?,
        displayName: String? = nil
    ) -> Bool {
        let candidates = [bundleID, displayName].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return candidates.contains { candidate in
            let normalized = candidate
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            return normalized.contains("core-audio-driver-service")
                || normalized == "coreaudiod"
                || normalized == "com.apple.audio.coreaudiod"
        }
    }

    /// Browser and Electron audio normally originates in a nested helper
    /// process. Collapse its bundle identifier to the owning application even
    /// when Launch Services does not provide a bundle URL for that PID.
    static func canonicalApplicationBundleID(_ bundleID: String?) -> String? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else { return nil }
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let helperIndex = components.firstIndex(where: {
            let component = $0.lowercased()
            return component == "helper" || component.hasPrefix("helper-")
        }), helperIndex > 0 else {
            return bundleID
        }
        return components[..<helperIndex].joined(separator: ".")
    }

    private static func outermostApplicationURL(from bundleURL: URL?) -> URL? {
        guard var candidate = bundleURL?.standardizedFileURL else { return nil }
        var outermost: URL?
        while candidate.path != "/" {
            if candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                outermost = candidate
            }
            candidate.deleteLastPathComponent()
        }
        return outermost
    }

    private static func loadSettings(from url: URL) -> [String: PerAppAudioSettings] {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(
                [String: PerAppAudioSettings].self,
                from: data
              ) else { return [:] }
        return settings
    }

    private static func loadAudioHistory(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(identifiers)
    }

    private static func headroomScalar(
        _ settings: PerAppAudioSettings,
        sampleRate: Double
    ) -> Float {
        guard !settings.equalizerBands.isEmpty else { return 1 }
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(bands: settings.equalizerBands),
            sampleRate: sampleRate,
            count: 600
        )
        let boost = max(0, response.map(\.gainDB).max() ?? 0)
        return Float(pow(10, -boost / 20))
    }

    private func schedulePersistence(_ settings: [String: PerAppAudioSettings]) {
        pendingPersistence?.cancel()
        let url = settingsURL
        let work = DispatchWorkItem {
            Self.persist(settings, to: url)
        }
        pendingPersistence = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scheduleAudioHistoryPersistence(_ identifiers: Set<String>) {
        let url = audioHistoryURL
        let work = DispatchWorkItem {
            Self.persistAudioHistory(identifiers, to: url)
        }
        lock.lock()
        pendingHistoryPersistence?.cancel()
        pendingHistoryPersistence = work
        lock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func persist(
        _ settings: [String: PerAppAudioSettings],
        to settingsURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: settingsURL, options: .atomic)
    }

    private static func persistAudioHistory(
        _ identifiers: Set<String>,
        to historyURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(identifiers.sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: historyURL, options: .atomic)
    }
}

private struct PerAppFilterBank {
    private struct Signature: Hashable {
        var channelCount: Int
        var sampleRate: Double
        var bands: [EQBand]
    }

    private struct State {
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
    }

    private struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    private var signature: Signature?
    private var coefficients: [Coefficients] = []
    private var states: [State] = []

    mutating func process(
        _ samples: inout [Float],
        channelCount: Int,
        sampleRate: Double,
        bands: [EQBand]
    ) {
        let activeBands = bands.filter {
            $0.enabled && $0.frequency > 0 && $0.frequency < sampleRate / 2
        }
        let nextSignature = Signature(
            channelCount: channelCount,
            sampleRate: sampleRate,
            bands: activeBands
        )
        if signature != nextSignature {
            signature = nextSignature
            coefficients = activeBands.compactMap {
                Self.coefficients(for: $0, sampleRate: sampleRate)
            }
            states = [State](repeating: State(), count: coefficients.count * channelCount)
        }
        guard !coefficients.isEmpty else { return }
        for sampleIndex in samples.indices {
            let channel = sampleIndex % channelCount
            var value = Double(samples[sampleIndex])
            for filterIndex in coefficients.indices {
                let stateIndex = filterIndex * channelCount + channel
                var state = states[stateIndex]
                let c = coefficients[filterIndex]
                let output = c.b0 * value + c.b1 * state.x1 + c.b2 * state.x2
                    - c.a1 * state.y1 - c.a2 * state.y2
                state.x2 = state.x1
                state.x1 = value
                state.y2 = state.y1
                state.y1 = output
                states[stateIndex] = state
                value = output
            }
            samples[sampleIndex] = Float(value.isFinite ? value : 0)
        }
    }

    private static func coefficients(for band: EQBand, sampleRate: Double) -> Coefficients? {
        let q: Double
        if let value = band.q, value.isFinite, value > 0 {
            q = value
        } else if let bandwidth = band.bandwidth,
                  bandwidth.isFinite, bandwidth > 0 {
            q = 1 / (2 * sinh(log(2) / 2 * bandwidth))
        } else {
            q = 0.70710678
        }
        let w0 = 2 * Double.pi * band.frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let gain = band.gain ?? 0
        guard gain.isFinite else { return nil }
        let a = pow(10, gain / 40)
        let alpha = sinw / (2 * q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = b0
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cosw; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .lowShelf, .highShelf:
            let squareRootA = sqrt(a)
            let beta = 2 * squareRootA * alpha
            if band.kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cosw + beta)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
                b2 = a * ((a + 1) - (a - 1) * cosw - beta)
                a0 = (a + 1) + (a - 1) * cosw + beta
                a1 = -2 * ((a - 1) + (a + 1) * cosw)
                a2 = (a + 1) + (a - 1) * cosw - beta
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosw + beta)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
                b2 = a * ((a + 1) + (a - 1) * cosw - beta)
                a0 = (a + 1) - (a - 1) * cosw + beta
                a1 = 2 * ((a - 1) - (a + 1) * cosw)
                a2 = (a + 1) - (a - 1) * cosw - beta
            }
        }
        guard a0.isFinite, a0 != 0 else { return nil }
        return Coefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
