import SwiftUI
import UniformTypeIdentifiers

struct DeviceCorrectionEditorView: View {
    let existing: DeviceCorrectionProfile?
    let sampleRate: Double
    let automaticHeadroom: ([EQBand]) -> Double
    let shouldConfirmReplacement: () -> Bool
    let onCancel: () -> Void
    let onLoad: (DeviceCorrectionProfile) -> Void

    private let catalog = DeviceMeasurementCatalog.online

    @State private var deviceName: String
    @State private var searchText: String
    @State private var policy: DeviceCorrectionPolicyKind
    @State private var filterCount: Int
    @State private var catalogEntries: [DeviceCatalogEntry] = []
    @State private var selectedCatalogID: String?
    @State private var sourceMeasurements: [DeviceCorrectionMeasurement] = []
    @State private var measurement: FrequencyResponse?
    @State private var targetSelection: DeviceCorrectionTargetSelection
    @State private var customTarget: FrequencyResponse?
    @State private var deviceMatchSearchText: String
    @State private var selectedDeviceMatchCatalogID: String?
    @State private var deviceMatchConsensus: MeasurementConsensus?
    @State private var generated: DeviceCorrectionProfile?
    @State private var generatedAutomaticHeadroomDB: Double
    @State private var errorMessage: String?
    @State private var isLoadingCatalog = false
    @State private var isLoadingMeasurements = false
    @State private var isLoadingDeviceMatch = false
    @State private var sourceLoadGeneration: UInt64 = 0
    @State private var deviceMatchLoadGeneration: UInt64 = 0
    @State private var showingMeasurementImporter = false
    @State private var showingTargetImporter = false
    @State private var showingReplacementConfirmation = false

    init(
        existing: DeviceCorrectionProfile?,
        sampleRate: Double,
        automaticHeadroom: @escaping ([EQBand]) -> Double,
        shouldConfirmReplacement: @escaping () -> Bool,
        onCancel: @escaping () -> Void,
        onLoad: @escaping (DeviceCorrectionProfile) -> Void
    ) {
        self.existing = existing
        self.sampleRate = sampleRate
        self.automaticHeadroom = automaticHeadroom
        self.shouldConfirmReplacement = shouldConfirmReplacement
        self.onCancel = onCancel
        self.onLoad = onLoad
        _deviceName = State(initialValue: existing?.deviceName ?? "")
        _searchText = State(initialValue: existing?.deviceName ?? "")
        _selectedCatalogID = State(initialValue: existing.map {
            $0.deviceIdentity.stableKey
        })
        _policy = State(initialValue: existing?.policy ?? .recommended)
        _filterCount = State(initialValue: min(16, max(3, existing?.filters.count ?? 10)))
        _measurement = State(initialValue: existing?.measurement)
        _targetSelection = State(initialValue: existing?.targetSelection ?? .flat)
        _customTarget = State(initialValue:
            existing?.targetSelection.preset == .custom ? existing?.target : nil
        )
        let matchMetadata = existing?.targetSelection.preset == .deviceMatch
            ? existing?.targetSelection.deviceMatchTarget
            : nil
        _deviceMatchSearchText = State(initialValue: matchMetadata?.deviceName ?? "")
        _selectedDeviceMatchCatalogID = State(
            initialValue: matchMetadata?.deviceIdentity.stableKey
        )
        _deviceMatchConsensus = State(initialValue: matchMetadata.map {
            MeasurementConsensus(
                response: existing?.target ?? .flat(),
                confidence: $0.measurementConfidence,
                sources: $0.sources,
                snapshots: $0.measurementSnapshots
            )
        })
        _generated = State(initialValue: existing)
        _generatedAutomaticHeadroomDB = State(
            initialValue: existing.map { automaticHeadroom($0.filters) } ?? 0
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Correction")
                        .font(.title2.bold())
                    Text("Select one device configuration and combine its compatible measurements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Device and source data") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Search earphones", text: $searchText)
                                .textFieldStyle(.roundedBorder)

                            if isLoadingCatalog {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading device catalog…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if shouldShowSearchResults {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(searchResults) { entry in
                                            Button {
                                                select(entry)
                                            } label: {
                                                Text(entry.displayName)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .contentShape(Rectangle())
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 6)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .frame(maxHeight: 170)
                                .background(
                                    Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                            }

                            if isLoadingMeasurements {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Combining compatible measurements…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !sourceMeasurements.isEmpty {
                                let evidenceCount = Set(sourceMeasurements.map {
                                    $0.source.laboratoryCorrelationKey
                                }).count
                                Text("Ready from \(evidenceCount) compatible independent lab group\(evidenceCount == 1 ? "" : "s").")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if sourceMeasurements.isEmpty,
                               let existing,
                               existing.sources.contains(where: { $0.providerID != "local" }) {
                                Button("Refresh Measurements") {
                                    refreshMeasurements(from: existing)
                                }
                                .disabled(isLoadingMeasurements)
                                .help("Download these saved measurement references again without searching for the device.")
                            }

                            responseRow(
                                title: "Measurement",
                                response: measurement,
                                emptyText: "Choose a search result or import your own CSV",
                                buttonTitle: "Import Custom CSV…"
                            ) { showingMeasurementImporter = true }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Correction target", selection: targetPresetBinding) {
                                    ForEach(DeviceCorrectionTargetPreset.allCases, id: \.self) {
                                        Text($0.title).tag($0)
                                    }
                                }
                                .pickerStyle(.menu)

                                Text(targetSelection.preset.shortDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if targetSelection.preset == .jm1PopAvgDFTilt {
                                    HStack(spacing: 10) {
                                        Text("Tilt")
                                            .font(.caption.weight(.medium))
                                        Slider(value: targetTiltBinding, in: -2...1, step: 0.1)
                                        Text("\(targetSelection.tiltDBPerOctave, format: .number.precision(.fractionLength(1))) dB/oct")
                                            .font(.caption.monospacedDigit())
                                            .frame(width: 92, alignment: .trailing)
                                    }
                                }

                                if targetSelection.preset == .deviceMatch {
                                    deviceMatchControls
                                }

                                Text(targetCompatibilityMessage)
                                    .font(.caption)
                                    .foregroundStyle(targetIsIncompatible ? .orange : .secondary)

                                if targetSelection.preset == .custom {
                                    responseRow(
                                        title: "Custom target",
                                        response: customTarget,
                                        emptyText: "No target CSV imported",
                                        buttonTitle: "Import Custom Target…"
                                    ) { showingTargetImporter = true }
                                    Picker(
                                        "Target CSV fixture",
                                        selection: customTargetRigFamilyBinding
                                    ) {
                                        Text("Choose fixture…")
                                            .tag(DeviceCorrectionRigFamily?.none)
                                        Text(DeviceCorrectionRigFamily.iec711.title)
                                            .tag(DeviceCorrectionRigFamily?.some(.iec711))
                                        Text(DeviceCorrectionRigFamily.bk5128.title)
                                            .tag(DeviceCorrectionRigFamily?.some(.bk5128))
                                    }
                                    .pickerStyle(.menu)
                                } else if let generated {
                                    Text("Resolved curve: \(generated.target.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Correction policy") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Policy", selection: policyBinding) {
                                ForEach(DeviceCorrectionPolicyKind.allCases, id: \.self) {
                                    Text($0.title).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(policyExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Stepper(value: filterCountBinding, in: 3...16) {
                                Text("PEQ filters: \(filterCount)")
                            }
                        }
                        .padding(6)
                    }

                    HStack {
                        Button("Generate Correction") { generate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                measurement == nil
                                    || trimmedDeviceName.isEmpty
                                    || isLoadingMeasurements
                                    || isLoadingDeviceMatch
                                    || (targetSelection.preset == .custom
                                        && (customTarget == nil
                                            || targetSelection.customTargetRigIdentity == nil))
                                    || (targetSelection.preset == .deviceMatch
                                        && deviceMatchConsensus == nil)
                                    || targetIsIncompatible
                            )
                        if generated == nil, existing != nil {
                            Text("Regenerate after changing measurement, target, policy, or filter count.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let generated {
                        GroupBox("Preview") {
                            VStack(alignment: .leading, spacing: 10) {
                                CorrectionResponseGraph(profile: generated, sampleRate: sampleRate)
                                    .frame(height: 260)
                                HStack(spacing: 16) {
                                    Label("Measurement", systemImage: "minus")
                                        .foregroundStyle(.secondary)
                                    Label("Target", systemImage: "minus")
                                        .foregroundStyle(.blue)
                                    Label("Corrected", systemImage: "minus")
                                        .foregroundStyle(.green)
                                    Label("Equalizer", systemImage: "minus")
                                        .foregroundStyle(.orange)
                                    Label("Residual error", systemImage: "minus")
                                        .foregroundStyle(.red)
                                }
                                .font(.caption)
                                Divider()
                                generatedEqualizerValues(generated)
                            }
                            .padding(6)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Load into Equalizer") { requestLoadIntoEqualizer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(generated == nil || trimmedDeviceName.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 620, idealHeight: 720)
        .task { await loadCatalog() }
        .onChange(of: searchText) { newValue in
            guard newValue != deviceName else { return }
            sourceLoadGeneration &+= 1
            selectedCatalogID = nil
            deviceName = ""
            sourceMeasurements = []
            measurement = nil
            clearDeviceMatchTarget(clearSearch: false)
            generated = nil
            isLoadingMeasurements = false
        }
        .onChange(of: deviceMatchSearchText) { newValue in
            guard newValue != targetSelection.deviceMatchTarget?.deviceName,
                  !(selectedDeviceMatchCatalogID != nil && isLoadingDeviceMatch) else {
                return
            }
            deviceMatchLoadGeneration &+= 1
            selectedDeviceMatchCatalogID = nil
            deviceMatchConsensus = nil
            targetSelection.deviceMatchTarget = nil
            generated = nil
            isLoadingDeviceMatch = false
        }
        .alert(
            "Replace existing equalizer?",
            isPresented: $showingReplacementConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Replace Equalizer", role: .destructive) {
                loadIntoEqualizer()
            }
        } message: {
            Text("Loading this correction will replace the current global EQ bands and user preamp. It will remain unsaved until you press the main Equalizer Save button.")
        }
        .fileImporter(
            isPresented: $showingMeasurementImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importResponse(result, asTarget: false)
        }
        .fileImporter(
            isPresented: $showingTargetImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importResponse(result, asTarget: true)
        }
        .onDisappear {
            sourceLoadGeneration &+= 1
            deviceMatchLoadGeneration &+= 1
        }
    }

    private var trimmedDeviceName: String {
        deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [DeviceCatalogEntry] {
        DeviceCatalogSearch.results(in: catalogEntries, matching: searchText)
    }

    private var shouldShowSearchResults: Bool {
        !DeviceNameNormalizer.key(for: searchText).isEmpty
            && selectedCatalogID == nil
            && !searchResults.isEmpty
    }

    private var deviceMatchSearchResults: [DeviceCatalogEntry] {
        DeviceCatalogSearch.results(
            in: catalogEntries,
            matching: deviceMatchSearchText,
            limit: max(40, catalogEntries.count)
        ).filter { entry in
            entry.identity.stableKey != sourceDeviceIdentityKey
                && !DeviceMatchPlanner.compatibleReferences(
                    in: entry,
                    sourceReferences: targetSources
                ).isEmpty
        }.prefix(40).map { $0 }
    }

    private var shouldShowDeviceMatchSearchResults: Bool {
        measurement != nil
            && !DeviceNameNormalizer.key(for: deviceMatchSearchText).isEmpty
            && selectedDeviceMatchCatalogID == nil
            && !deviceMatchSearchResults.isEmpty
    }

    private var sourceDeviceIdentityKey: String? {
        sourceMeasurements.compactMap(\.source.deviceIdentity).first?.stableKey
            ?? existing?.deviceIdentity.stableKey
    }

    private var deviceMatchSources: [DeviceMeasurementReference] {
        deviceMatchConsensus?.sources
            ?? targetSelection.deviceMatchTarget?.sources
            ?? []
    }

    private var policyBinding: Binding<DeviceCorrectionPolicyKind> {
        Binding(get: { policy }, set: {
            policy = $0
            generated = nil
        })
    }

    private var filterCountBinding: Binding<Int> {
        Binding(get: { filterCount }, set: {
            filterCount = $0
            generated = nil
        })
    }

    private var targetPresetBinding: Binding<DeviceCorrectionTargetPreset> {
        Binding(get: { targetSelection.preset }, set: {
            if $0 != .deviceMatch {
                clearDeviceMatchTarget(clearSearch: true)
            }
            targetSelection.preset = $0
            generated = nil
            errorMessage = nil
        })
    }

    private var targetTiltBinding: Binding<Double> {
        Binding(get: { targetSelection.tiltDBPerOctave }, set: {
            targetSelection.tiltDBPerOctave = min(1, max(-2, $0))
            generated = nil
            errorMessage = nil
        })
    }

    private var customTargetRigFamilyBinding: Binding<DeviceCorrectionRigFamily?> {
        Binding(
            get: { targetSelection.customTargetRigIdentity?.family },
            set: { family in
                targetSelection.customTargetRigIdentity = family.map { selectedFamily in
                    targetSources.lazy.map(\.resolvedRigIdentity).first {
                        $0.family == selectedFamily
                    } ?? MeasurementRigIdentity.canonical(for: selectedFamily)
                }
                generated = nil
                errorMessage = nil
            }
        )
    }

    private var targetSources: [DeviceMeasurementReference] {
        if !sourceMeasurements.isEmpty { return sourceMeasurements.map(\.source) }
        return existing?.sources ?? []
    }

    private var targetCompatibilityMessage: String {
        DeviceCorrectionTargetCatalog().compatibilityMessage(
            for: targetSelection,
            sources: targetSources,
            deviceMatchSources: deviceMatchSources
        )
    }

    private var targetIsIncompatible: Bool {
        if targetSelection.preset == .deviceMatch {
            guard targetSelection.deviceMatchTarget != nil else { return false }
            return !DeviceMatchPlanner.isCompatible(
                sourceReferences: targetSources,
                targetReferences: deviceMatchSources
            )
        }
        let measurementFamily = DeviceCorrectionRigFamily.identify(from: targetSources)
        if targetSelection.preset == .custom,
           let targetFamily = targetSelection.customTargetRigIdentity?.family,
           measurementFamily != .unknown,
           targetFamily != measurementFamily {
            return true
        }
        guard measurementFamily == .bk5128 else {
            return false
        }
        return [.harmanInEar2019V2, .iefNeutral2023, .etymotic]
            .contains(targetSelection.preset)
    }

    private var policyExplanation: String {
        switch policy {
        case .recommended:
            return "Uses frequency-dependent confidence, stronger cut limits, restrained boosts, and smoothing to avoid correcting unreliable narrow features."
        case .exactTarget:
            return "Tracks the selected target more closely with wider gain limits. Use this only with a measurement you trust."
        }
    }

    @ViewBuilder
    private var deviceMatchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if measurement == nil {
                Text("Choose the source device first. CamiTune will only offer target devices with compatible structured measurement rigs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search target earphones", text: $deviceMatchSearchText)
                    .textFieldStyle(.roundedBorder)

                if shouldShowDeviceMatchSearchResults {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(deviceMatchSearchResults) { entry in
                                Button {
                                    selectDeviceMatch(entry)
                                } label: {
                                    Text(entry.displayName)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    .background(
                        Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }

                if isLoadingDeviceMatch {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Combining target-device measurements…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let metadata = targetSelection.deviceMatchTarget,
                          let consensus = deviceMatchConsensus {
                    let evidenceCount = Set(consensus.sources.map {
                        $0.laboratoryCorrelationKey
                    }).count
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metadata.deviceName)
                                .font(.headline)
                            Text("\(consensus.response.points.count) points · \(evidenceCount) independent lab group\(evidenceCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { refreshDeviceMatch() }
                            .disabled(isLoadingDeviceMatch)
                    }
                } else if !DeviceNameNormalizer.key(for: deviceMatchSearchText).isEmpty,
                          deviceMatchSearchResults.isEmpty {
                    Text("No compatible target measurements were found for this source fixture and configuration type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func responseRow(
        title: String,
        response: FrequencyResponse?,
        emptyText: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let response {
                    Text("\(response.name) · \(response.points.count) points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(buttonTitle, action: action)
        }
    }

    @ViewBuilder
    private func generatedEqualizerValues(_ profile: DeviceCorrectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Equalizer values")
                    .font(.headline)
                Spacer()
                Text("Automatic headroom \(generatedAutomaticHeadroomDB, format: .number.precision(.fractionLength(2))) dB")
                    .font(.caption.monospacedDigit().weight(.medium))
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Filter")
                    Text("Type")
                    Text("Frequency")
                    Text("Gain")
                    Text("Q")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(profile.filters.indices, id: \.self) { index in
                    let band = profile.filters[index]
                    GridRow {
                        Text("\(index + 1)")
                        Text(filterLabel(band.kind))
                        Text("\(band.frequency, format: .number.precision(.fractionLength(0...1))) Hz")
                        Text("\(band.gain ?? 0, format: .number.precision(.fractionLength(1))) dB")
                        Text("\(band.q ?? 0.707, format: .number.precision(.fractionLength(2)))")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func filterLabel(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NO"
        case .allPass: return "AP"
        }
    }

    private func importResponse(
        _ result: Result<[URL], Error>,
        asTarget: Bool
    ) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let response = try FrequencyResponseCSVImporter().parse(
                text,
                name: url.deletingPathExtension().lastPathComponent
            )
            if asTarget {
                clearDeviceMatchTarget(clearSearch: true)
                customTarget = response
                targetSelection.preset = .custom
                targetSelection.customTargetRigIdentity = nil
            }
            else {
                sourceLoadGeneration &+= 1
                isLoadingMeasurements = false
                clearDeviceMatchTarget(clearSearch: true)
                sourceMeasurements = [DeviceCorrectionMeasurement.local(
                    response: response,
                    originalData: Data(text.utf8)
                )]
                measurement = response
                deviceName = response.name
                searchText = response.name
                selectedCatalogID = "local:\(DeviceNameNormalizer.key(for: response.name))"
            }
            generated = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generate() {
        guard let measurement else { return }
        do {
            let engine = DeviceCorrectionEngine()
            let resolution = try DeviceCorrectionTargetCatalog().resolve(
                selection: targetSelection,
                sources: targetSources,
                customResponse: customTarget,
                deviceMatchConsensus: deviceMatchConsensus
            )
            if sourceMeasurements.isEmpty, let existing {
                generated = try engine.generate(
                    deviceName: trimmedDeviceName,
                    consensus: MeasurementConsensus(
                        response: measurement,
                        confidence: existing.measurementConfidence,
                        sources: existing.sources,
                        snapshots: existing.measurementSnapshots
                    ),
                    target: resolution.response,
                    targetSelection: targetSelection,
                    policy: policy,
                    filterCount: filterCount,
                    sampleRate: sampleRate,
                    preservingID: existing.id,
                    preservingSources: existing.sources,
                    targetConfidence: resolution.confidence
                )
            } else {
                generated = try engine.generate(
                    deviceName: trimmedDeviceName,
                    measurements: sourceMeasurements,
                    target: resolution.response,
                    targetSelection: targetSelection,
                    policy: policy,
                    filterCount: filterCount,
                    sampleRate: sampleRate,
                    preservingID: existing?.id,
                    targetConfidence: resolution.confidence
                )
            }
            generatedAutomaticHeadroomDB = generated.map {
                automaticHeadroom($0.filters)
            } ?? 0
            errorMessage = nil
        } catch {
            generated = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadIntoEqualizer() {
        guard var generated else { return }
        generated.deviceName = trimmedDeviceName
        generated.isEnabled = true
        onLoad(generated)
    }

    private func requestLoadIntoEqualizer() {
        if shouldConfirmReplacement() {
            showingReplacementConfirmation = true
        } else {
            loadIntoEqualizer()
        }
    }

    private func refreshMeasurements(from provenance: DeviceCorrectionProfile) {
        sourceLoadGeneration &+= 1
        let loadGeneration = sourceLoadGeneration
        isLoadingMeasurements = true
        errorMessage = nil
        let entry = DeviceCatalogEntry(
            displayName: provenance.deviceName,
            measurements: provenance.sources,
            identity: provenance.deviceIdentity
        )
        Task { @MainActor in
            do {
                let refreshedCatalog = try? await catalog.entries(refresh: true)
                let currentEntry = refreshedCatalog?.first {
                    $0.identity == provenance.deviceIdentity
                } ?? entry
                let loaded = try await catalog.measurements(
                    for: currentEntry,
                    refresh: true
                )
                guard sourceLoadGeneration == loadGeneration else { return }
                let consensus = try MeasurementConsensusBuilder().build(
                    deviceName: provenance.deviceName,
                    measurements: loaded
                )
                let retainedSourceIDs = Set(consensus.sources.map(\.id))
                sourceMeasurements = loaded.filter {
                    retainedSourceIDs.contains($0.source.id)
                }
                measurement = consensus.response
                generated = nil
                isLoadingMeasurements = false
            } catch {
                guard sourceLoadGeneration == loadGeneration else { return }
                errorMessage = "Measurements could not be refreshed: \(error.localizedDescription)"
                isLoadingMeasurements = false
            }
        }
    }

    @MainActor
    private func loadCatalog() async {
        guard catalogEntries.isEmpty, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalogEntries = try await catalog.entries()
        } catch {
            errorMessage = "Online device data is unavailable. You can still import a custom CSV."
        }
    }

    private func select(_ entry: DeviceCatalogEntry) {
        sourceLoadGeneration &+= 1
        let loadGeneration = sourceLoadGeneration
        clearDeviceMatchTarget(clearSearch: true)
        deviceName = entry.displayName
        searchText = entry.displayName
        selectedCatalogID = entry.id
        sourceMeasurements = []
        measurement = nil
        generated = nil
        errorMessage = nil
        isLoadingMeasurements = true

        Task { @MainActor in
            do {
                let loaded = try await catalog.measurements(for: entry)
                guard sourceLoadGeneration == loadGeneration,
                      selectedCatalogID == entry.id else { return }
                let consensus = try MeasurementConsensusBuilder().build(
                    deviceName: entry.displayName,
                    measurements: loaded
                )
                let retainedSourceIDs = Set(consensus.sources.map(\.id))
                sourceMeasurements = loaded.filter {
                    retainedSourceIDs.contains($0.source.id)
                }
                measurement = consensus.response
                errorMessage = nil
                isLoadingMeasurements = false
            } catch {
                guard sourceLoadGeneration == loadGeneration,
                      selectedCatalogID == entry.id else { return }
                sourceMeasurements = []
                measurement = nil
                errorMessage = error.localizedDescription
                isLoadingMeasurements = false
            }
        }
    }

    private func selectDeviceMatch(_ entry: DeviceCatalogEntry) {
        loadDeviceMatch(entry, refresh: false)
    }

    private func refreshDeviceMatch() {
        guard let metadata = targetSelection.deviceMatchTarget else { return }
        let savedEntry = DeviceCatalogEntry(
            displayName: metadata.deviceName,
            measurements: metadata.sources,
            identity: metadata.deviceIdentity
        )
        let currentEntry = catalogEntries.first {
            $0.identity == metadata.deviceIdentity
        } ?? savedEntry
        loadDeviceMatch(currentEntry, refresh: true)
    }

    private func loadDeviceMatch(
        _ entry: DeviceCatalogEntry,
        refresh: Bool
    ) {
        let compatibleReferences = DeviceMatchPlanner.compatibleReferences(
            in: entry,
            sourceReferences: targetSources
        )
        guard !compatibleReferences.isEmpty else {
            errorMessage = "The target device has no measurements using the source device's exact form and structured fixture calibration."
            return
        }
        guard entry.identity.stableKey != sourceDeviceIdentityKey else {
            errorMessage = "Choose a different target device for Device Match."
            return
        }

        let compatibleEntry = DeviceCatalogEntry(
            displayName: entry.displayName,
            measurements: compatibleReferences,
            identity: entry.identity
        )
        let previousConsensus = deviceMatchConsensus
        let previousMetadata = targetSelection.deviceMatchTarget
        deviceMatchLoadGeneration &+= 1
        let loadGeneration = deviceMatchLoadGeneration
        isLoadingDeviceMatch = true
        deviceMatchSearchText = entry.displayName
        selectedDeviceMatchCatalogID = entry.id
        if !refresh {
            deviceMatchConsensus = nil
            targetSelection.deviceMatchTarget = nil
        }
        generated = nil
        errorMessage = nil

        Task { @MainActor in
            do {
                let loaded = try await catalog.measurements(
                    for: compatibleEntry,
                    refresh: refresh
                )
                guard deviceMatchLoadGeneration == loadGeneration,
                      selectedDeviceMatchCatalogID == entry.id else { return }
                let consensus = try MeasurementConsensusBuilder().build(
                    deviceName: entry.displayName,
                    measurements: loaded
                )
                guard DeviceMatchPlanner.isCompatible(
                    sourceReferences: targetSources,
                    targetReferences: consensus.sources
                ) else {
                    throw DeviceCorrectionTargetCatalog.TargetError.incompatibleDeviceMatchRig
                }
                deviceMatchConsensus = consensus
                targetSelection.deviceMatchTarget = DeviceMatchTargetMetadata(
                    deviceName: entry.displayName,
                    deviceIdentity: entry.identity,
                    measurementConfidence: consensus.confidence,
                    sources: consensus.sources,
                    measurementSnapshots: consensus.snapshots
                )
                errorMessage = nil
                isLoadingDeviceMatch = false
            } catch {
                guard deviceMatchLoadGeneration == loadGeneration,
                      selectedDeviceMatchCatalogID == entry.id else { return }
                deviceMatchConsensus = refresh ? previousConsensus : nil
                targetSelection.deviceMatchTarget = refresh ? previousMetadata : nil
                selectedDeviceMatchCatalogID = refresh ? entry.id : nil
                errorMessage = "Target measurements could not be loaded: \(error.localizedDescription)"
                isLoadingDeviceMatch = false
            }
        }
    }

    private func clearDeviceMatchTarget(clearSearch: Bool) {
        deviceMatchLoadGeneration &+= 1
        if clearSearch { deviceMatchSearchText = "" }
        selectedDeviceMatchCatalogID = nil
        deviceMatchConsensus = nil
        targetSelection.deviceMatchTarget = nil
        isLoadingDeviceMatch = false
        generated = nil
    }
}

private struct CorrectionResponseGraph: View {
    let profile: DeviceCorrectionProfile
    let sampleRate: Double

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 48,
                y: 8,
                width: max(1, geometry.size.width - 60),
                height: max(1, geometry.size.height - 46)
            )
            let displayFrequencies = frequencies(count: min(
                4_096,
                max(1_000, Int(ceil(plot.width * 3)))
            ))
            let measurement = measurementSeries(at: displayFrequencies)
            let target = targetSeries(at: displayFrequencies)
            let corrected = correctedSeries(at: displayFrequencies)
            let equalizer = equalizerSeries(at: displayFrequencies)
            let error = errorSeries(at: displayFrequencies)
            let levelRange = levelRange(for: [
                measurement, target, corrected, equalizer, error
            ])
            let levelTicks = ticks(for: levelRange)
            ZStack {
                Path { path in
                    for gain in levelTicks {
                        let lineY = y(gain, plot: plot, range: levelRange)
                        path.move(to: CGPoint(x: plot.minX, y: lineY))
                        path.addLine(to: CGPoint(x: plot.maxX, y: lineY))
                    }
                    for frequency in [20.0, 100, 1_000, 10_000, 20_000] {
                        let lineX = x(frequency, plot: plot)
                        path.move(to: CGPoint(x: lineX, y: plot.minY))
                        path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)

                responsePath(measurement, plot: plot, range: levelRange)
                    .stroke(
                        Color.secondary,
                        style: responseStroke(lineWidth: 1.2)
                    )
                responsePath(target, plot: plot, range: levelRange)
                    .stroke(
                        Color.blue,
                        style: responseStroke(lineWidth: 1.4, dash: [5, 3])
                    )
                responsePath(corrected, plot: plot, range: levelRange)
                    .stroke(
                        Color.green,
                        style: responseStroke(lineWidth: 2)
                    )
                responsePath(equalizer, plot: plot, range: levelRange)
                    .stroke(
                        Color.orange,
                        style: responseStroke(lineWidth: 1.4)
                    )
                responsePath(error, plot: plot, range: levelRange)
                    .stroke(
                        Color.red,
                        style: responseStroke(lineWidth: 1.3, dash: [3, 3])
                    )

                ForEach(levelTicks, id: \.self) { gain in
                    Text(levelLabel(gain))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(
                            x: plot.minX - 15,
                            y: y(gain, plot: plot, range: levelRange)
                        )
                }
                ForEach([20, 100, 1_000, 10_000, 20_000], id: \.self) { frequency in
                    Text(frequencyLabel(frequency))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: x(Double(frequency), plot: plot), y: plot.maxY + 10)
                }
                Text("Relative level (dB)")
                    .font(.system(size: 9).weight(.medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(-90))
                    .position(x: 8, y: plot.midY)
                Text("Frequency (Hz)")
                    .font(.system(size: 9).weight(.medium))
                    .foregroundStyle(.secondary)
                    .position(x: plot.midX, y: geometry.size.height - 5)
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func frequencies(count: Int) -> [Double] {
        // Display density only. Policy and optimizer grids remain at 181 points.
        (0..<count).map { 20 * pow(1_000, Double($0) / Double(count - 1)) }
    }

    private func measurementSeries(at frequencies: [Double]) -> [(Double, Double)] {
        let normalized = profile.measurement.normalized()
        return frequencies.compactMap { frequency in
            normalized.displayMagnitude(at: frequency).map { (frequency, $0) }
        }
    }

    private func targetSeries(at frequencies: [Double]) -> [(Double, Double)] {
        let normalized = profile.target.normalized()
        return frequencies.compactMap { frequency in
            normalized.displayMagnitude(at: frequency).map { (frequency, $0) }
        }
    }

    private func correctedSeries(at frequencies: [Double]) -> [(Double, Double)] {
        let normalized = profile.measurement.normalized()
        let parsed = ParsedEQ(preampDB: 0, bands: profile.filters, warnings: [])
        let calculator = EQResponseCalculator()
        return frequencies.compactMap { frequency in
            normalized.displayMagnitude(at: frequency).map {
                (frequency, $0 + calculator.gainDB(at: frequency, parsed: parsed, sampleRate: sampleRate))
            }
        }
    }

    private func equalizerSeries(at frequencies: [Double]) -> [(Double, Double)] {
        let parsed = ParsedEQ(preampDB: 0, bands: profile.filters, warnings: [])
        let calculator = EQResponseCalculator()
        return frequencies.map { frequency in
            (frequency, calculator.gainDB(at: frequency, parsed: parsed, sampleRate: sampleRate))
        }
    }

    private func errorSeries(at frequencies: [Double]) -> [(Double, Double)] {
        let normalizedMeasurement = profile.measurement.normalized()
        let normalizedTarget = profile.target.normalized()
        let parsed = ParsedEQ(preampDB: 0, bands: profile.filters, warnings: [])
        let calculator = EQResponseCalculator()
        return frequencies.compactMap { frequency in
            guard let measured = normalizedMeasurement.displayMagnitude(at: frequency),
                  let target = normalizedTarget.displayMagnitude(at: frequency) else { return nil }
            let corrected = measured + calculator.gainDB(
                at: frequency,
                parsed: parsed,
                sampleRate: sampleRate
            )
            return (frequency, corrected - target)
        }
    }

    private func responsePath(
        _ points: [(Double, Double)],
        plot: CGRect,
        range: ClosedRange<Double>
    ) -> Path {
        let positions = points.map {
            CGPoint(
                x: x($0.0, plot: plot),
                y: y($0.1, plot: plot, range: range)
            )
        }
        return Path { path in
            guard let first = positions.first else { return }
            path.move(to: first)
            guard positions.count > 1 else { return }
            if positions.count == 2 {
                path.addLine(to: positions[1])
                return
            }
            for index in 0..<(positions.count - 1) {
                let previous = positions[max(0, index - 1)]
                let start = positions[index]
                let end = positions[index + 1]
                let following = positions[min(positions.count - 1, index + 2)]
                let minimumY = min(start.y, end.y)
                let maximumY = max(start.y, end.y)
                let control1 = CGPoint(
                    x: min(end.x, max(start.x, start.x + (end.x - previous.x) / 6)),
                    y: min(maximumY, max(minimumY, start.y + (end.y - previous.y) / 6))
                )
                let control2 = CGPoint(
                    x: min(end.x, max(start.x, end.x - (following.x - start.x) / 6)),
                    y: min(maximumY, max(minimumY, end.y - (following.y - start.y) / 6))
                )
                path.addCurve(to: end, control1: control1, control2: control2)
            }
        }
    }

    private func responseStroke(
        lineWidth: CGFloat,
        dash: [CGFloat] = []
    ) -> StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: dash
        )
    }

    private func x(_ frequency: Double, plot: CGRect) -> Double {
        plot.minX + min(plot.width, max(0, log(frequency / 20) / log(1_000) * plot.width))
    }

    private func levelRange(
        for series: [[(Double, Double)]]
    ) -> ClosedRange<Double> {
        let maximumMagnitude = series.lazy.flatMap { $0 }.map {
            abs($0.1)
        }.filter(\.isFinite).max() ?? 18
        let extent = max(18, ceil(maximumMagnitude * 1.08 / 6) * 6)
        return -extent...extent
    }

    private func ticks(for range: ClosedRange<Double>) -> [Double] {
        let extent = range.upperBound
        return [-extent, -extent / 2, 0, extent / 2, extent]
    }

    private func y(
        _ gain: Double,
        plot: CGRect,
        range: ClosedRange<Double>
    ) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, gain))
        let position = (range.upperBound - clamped)
            / (range.upperBound - range.lowerBound)
        return plot.minY + position * plot.height
    }

    private func levelLabel(_ gain: Double) -> String {
        let rounded = Int(gain.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    private func frequencyLabel(_ frequency: Int) -> String {
        switch frequency {
        case 1_000: return "1k"
        case 10_000: return "10k"
        case 20_000: return "20k"
        default: return "\(frequency)"
        }
    }
}
