import SwiftUI

struct PerChannelProcessingView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile

    @State private var selectedChannelIndex = 0
    @State private var gainDB = 0.0
    @State private var limiterEnabled = false
    // Per-channel EQ is opt-in; new and migrated profiles begin with zero bands.
    @State private var bands: [EQBand] = []
    @State private var pendingBandCount: Int?
    @State private var showBandReductionConfirmation = false
    @State private var filterResponse: [EQResponsePoint] = []
    @State private var totalResponse: [EQResponsePoint] = []
    @State private var suppressChanges = false
    @State private var isSaved = true
    @State private var liveApplyTask: Task<Void, Never>?
    @State private var runtimeVisualsActive = false

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    private var editableChannels: [ChannelProcessing] {
        // The current bridge/runtime is stereo. Keeping these as semantic channel
        // records allows the same editor to expand when the runtime exposes a
        // larger channel layout.
        [
            profile.processing.channels.first(where: { $0.index == 0 })
                ?? ChannelProcessing(index: 0, role: .left),
            profile.processing.channels.first(where: { $0.index == 1 })
                ?? ChannelProcessing(index: 1, role: .right)
        ]
    }

    private var selectedChannel: ChannelProcessing {
        editableChannels.first(where: { $0.index == selectedChannelIndex })
            ?? editableChannels[0]
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Per-channel EQ & Gain").font(.title3.bold())
                    Text(isSaved ? "Saved" : "Not saved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSaved ? Color.green : Color.secondary)
                    Spacer()
                    Button("Reset channel") { resetSelectedChannel() }
                        .disabled(gainDB == 0 && bands.isEmpty && !limiterEnabled)
                    Button { saveSelectedChannel() } label: {
                        Text("Save")
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Text("Global processing runs first. These settings then affect only the selected physical channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Channel", selection: Binding(
                    get: { selectedChannelIndex },
                    set: { selectChannel($0) }
                )) {
                    ForEach(editableChannels) { channel in
                        Text("\(channel.role.shortName) · Ch \(channel.index)")
                            .tag(channel.index)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                HStack(spacing: 8) {
                    Text(selectedChannel.role.groupName)
                        .font(.headline)
                    Text("\(selectedChannel.role.displayName) (\(selectedChannel.role.shortName))")
                    Text("Channel \(selectedChannel.index)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                PreampGainControl(
                    gainDB: $gainDB,
                    limiterEnabled: $limiterEnabled,
                    meters: state.meters,
                    profileID: profile.id,
                    title: "Channel gain",
                    channelIndex: selectedChannelIndex,
                    visualEffectsEnabled: runtimeVisualsActive
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Combined channel response")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("gain + channel filters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    LineGraph(
                        points: totalResponse.map { ($0.frequency, $0.gainDB) },
                        xRange: 20...20_000,
                        yRange: -24...24,
                        zeroLine: true,
                        lineColor: .blue
                    )
                    .frame(height: 120)
                }

                HStack(spacing: 8) {
                    Text("EQ bands")
                    Picker("EQ bands", selection: Binding(
                        get: { bands.count },
                        set: { requestBandCount($0) }
                    )) {
                        ForEach(0...20, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                }

                if bands.isEmpty {
                    HStack {
                        Text("No channel-specific filters. The channel gain still applies.")
                            .foregroundStyle(.secondary)
                        Button("Add 8 bands") {
                            bands = EQEditorSupport.resizedBands(bands, count: 8)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                } else {
                    let columnWidth = 96.0
                    let contentWidth = GraphicEqualizerBands.requiredContentWidth(
                        bandCount: bands.count,
                        columnWidth: columnWidth
                    )
                    OverflowAwareHorizontalScrollView(
                        contentWidth: contentWidth,
                        height: 402
                    ) {
                        GraphicEqualizerBands(
                            bands: $bands,
                            spectrum: state.spectrum,
                            profileID: profile.id,
                            responsePoints: filterResponse,
                            setKind: EQEditorSupport.setKind,
                            columnWidth: columnWidth,
                            showsSpectrumLevels: false
                        )
                    }
                }
            }
            .padding(6)
        }
        .alert("Recalculate Equalizer Bands?", isPresented: $showBandReductionConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingBandCount = nil
            }
            Button("Recalculate", role: .destructive) {
                applyPendingBandReduction()
            }
        } message: {
            Text(bandReductionConfirmationMessage)
        }
        .onAppear {
            runtimeVisualsActive = true
            loadSelectedChannel()
        }
        .onChange(of: gainDB) { _ in channelSettingsChanged() }
        .onChange(of: limiterEnabled) { _ in channelSettingsChanged() }
        .onChange(of: bands) { _ in channelSettingsChanged() }
        .onChange(of: profile.sampleRate) { _ in updateResponses() }
        .onDisappear {
            runtimeVisualsActive = false
            liveApplyTask?.cancel()
            preserveSelectedDraft()
        }
    }

    private func selectChannel(_ index: Int) {
        guard index != selectedChannelIndex else { return }
        liveApplyTask?.cancel()
        preserveSelectedDraft()
        selectedChannelIndex = index
        loadSelectedChannel()
    }

    private func requestBandCount(_ count: Int) {
        guard count != bands.count else { return }
        if EQEditorSupport.shouldRefitWhenReducing(bands, to: count) {
            pendingBandCount = count
            showBandReductionConfirmation = true
            return
        }
        bands = EQEditorSupport.resizedBands(bands, count: count)
    }

    private var bandReductionConfirmationMessage: String {
        let target = pendingBandCount ?? bands.count
        return "Every current band has an active value. Reducing from \(bands.count) to \(target) bands will recalculate frequency, gain, and Q to approximate the same channel-EQ response."
    }

    private func applyPendingBandReduction() {
        guard let target = pendingBandCount else { return }
        pendingBandCount = nil
        bands = EQEditorSupport.responseFittedBands(
            bands,
            count: target,
            sampleRate: Double(profile.sampleRate)
        )
    }

    private func loadSelectedChannel() {
        suppressChanges = true
        liveApplyTask?.cancel()
        let draft = state.channelEQDraft(
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
        let limiterDraft = state.channelLimiterDraft(
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
        if let draft, let parsed = try? EqualizerAPOParser().parse(draft) {
            gainDB = parsed.preampDB
            bands = EQEditorSupport.organizedBands(parsed.bands)
            limiterEnabled = limiterDraft
                ?? profile.processing.settings(forChannel: selectedChannelIndex)?.limiterEnabled
                ?? false
        } else {
            let settings = profile.processing.settings(forChannel: selectedChannelIndex) ?? .identity
            gainDB = settings.gainDB
            bands = EQEditorSupport.organizedBands(settings.bands)
            limiterEnabled = limiterDraft ?? settings.limiterEnabled
        }
        updateResponses()
        isSaved = draft == nil && limiterDraft == nil
        DispatchQueue.main.async { suppressChanges = false }
    }

    private func channelSettingsChanged() {
        guard !suppressChanges else { return }
        updateResponses()
        isSaved = false
        preserveSelectedDraft()
        guard profileIsActive else { return }
        liveApplyTask?.cancel()
        liveApplyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            applySessionDraftsLive()
        }
    }

    private func saveSelectedChannel() {
        liveApplyTask?.cancel()
        var updated = profile
        do {
            try updated.setChannelProcessing(
                index: selectedChannel.index,
                role: selectedChannel.role,
                gainDB: gainDB,
                bands: bands,
                limiterEnabled: limiterEnabled
            )
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }

        profile = updated
        state.clearChannelEQDraft(
            for: profile.id,
            channelIndex: selectedChannel.index
        )
        isSaved = true
        if profileIsActive { applySessionDraftsLive() }
    }

    private func resetSelectedChannel() {
        gainDB = 0
        bands = []
        limiterEnabled = false
    }

    private func preserveSelectedDraft() {
        guard !isSaved else { return }
        state.setChannelEQDraft(
            EqualizerAPOSerializer().serialize(
                ParsedEQ(preampDB: gainDB, bands: bands, warnings: [])
            ),
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
        state.setChannelLimiterDraft(
            limiterEnabled,
            for: profile.id,
            channelIndex: selectedChannelIndex
        )
    }

    private func applySessionDraftsLive() {
        do {
            let liveProfile = try state.applyingSessionEQDrafts(to: profile)
            Task { await state.apply(profile: liveProfile) }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func updateResponses() {
        filterResponse = EQResponseCalculator().calculate(
            parsed: ParsedEQ(preampDB: 0, bands: bands, warnings: []),
            sampleRate: Double(profile.sampleRate)
        )
        totalResponse = EQResponseCalculator().calculate(
            parsed: ParsedEQ(preampDB: gainDB, bands: bands, warnings: []),
            sampleRate: Double(profile.sampleRate)
        )
    }
}

private extension ChannelRole {
    var groupName: String {
        switch self {
        case .left, .right: return "Front"
        case .center: return "Center"
        case .lowFrequencyEffects: return "Subwoofer"
        case .leftSurround, .rightSurround: return "Surround"
        case .leftRearSurround, .rightRearSurround: return "Rear"
        case .unknown: return "Other"
        }
    }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Center"
        case .lowFrequencyEffects: return "Low-frequency effects"
        case .leftSurround: return "Left surround"
        case .rightSurround: return "Right surround"
        case .leftRearSurround: return "Left rear surround"
        case .rightRearSurround: return "Right rear surround"
        case .unknown: return "Unknown"
        }
    }

    var shortName: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .center: return "C"
        case .lowFrequencyEffects: return "LFE"
        case .leftSurround: return "Ls"
        case .rightSurround: return "Rs"
        case .leftRearSurround: return "Lrs"
        case .rightRearSurround: return "Rrs"
        case .unknown: return "?"
        }
    }
}
