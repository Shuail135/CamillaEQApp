import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var profileStore: ProfileStore
    @State private var selection: String
    @State private var renameProfileID: UUID?
    @State private var renameDraft = ""
    @FocusState private var focusedRenameID: UUID?

    init(state: AppState) {
        self.state = state
        self._profileStore = ObservedObject(wrappedValue: state.profiles)
        let saved = UserDefaults.standard.string(forKey: "lastSidebarSelection")
        let restored: String
        if saved == "setup" {
            restored = "setup"
        } else if let saved,
                  let id = UUID(uuidString: saved),
                  state.profiles.profiles.contains(where: { $0.id == id }) {
            restored = saved
        } else {
            restored = state.profiles.selectedProfileID?.uuidString ?? "setup"
        }
        self._selection = State(initialValue: restored)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Setup", systemImage: "wrench.and.screwdriver").tag("setup")
                Section("Output profiles") {
                    ForEach(profileStore.profiles) { profile in
                        HStack(spacing: 7) {
                            Image(systemName: "speaker.wave.2")
                            if renameProfileID == profile.id {
                                TextField("Profile name", text: $renameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedRenameID, equals: profile.id)
                                    .onSubmit { commitRename() }
                                    .onExitCommand { cancelRename() }
                            } else {
                                Text(profile.name)
                            }
                        }
                        .tag(profile.id.uuidString)
                        .contextMenu {
                            Button("Rename") {
                                renameProfileID = profile.id
                                renameDraft = profile.name
                                DispatchQueue.main.async {
                                    focusedRenameID = profile.id
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                let id = profile.id
                                cancelRename()
                                selection = "setup"
                                Task {
                                    if state.activeProfileID == id {
                                        await state.deactivate(manual: true)
                                    }
                                    profileStore.deleteProfile(id: id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("CamillaEQApp")
            .safeAreaInset(edge: .bottom) {
                Menu {
                    ForEach(state.coreAudio.outputDevices.filter { $0.name != AudioDeviceInfo.blackHoleName }) { device in
                        Button(device.name) {
                            profileStore.addProfile(for: device)
                            selection = profileStore.selectedProfileID?.uuidString ?? "setup"
                        }
                    }
                } label: {
                    Label("Add Output Profile", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding()
            }
        } detail: {
            if selection == "setup" {
                SetupView(state: state)
            } else if let id = UUID(uuidString: selection),
                      let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditorView(state: state, profile: $profileStore.profiles[index])
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").font(.largeTitle)
                    Text("Choose a profile").font(.title2)
                }.foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 620)
        .onChange(of: selection) { newSelection in
            UserDefaults.standard.set(newSelection, forKey: "lastSidebarSelection")
            if let id = UUID(uuidString: newSelection) {
                profileStore.selectedProfileID = id
            }
        }
        .onChange(of: focusedRenameID) { newFocus in
            if renameProfileID != nil, newFocus != renameProfileID {
                commitRename()
            }
        }
        .alert("CamillaEQApp", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renameProfileID,
           !name.isEmpty,
           let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
            profileStore.profiles[index].name = name
        }
        renameProfileID = nil
        focusedRenameID = nil
    }

    private func cancelRename() {
        renameProfileID = nil
        focusedRenameID = nil
        renameDraft = ""
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Setup").font(.largeTitle.bold())
                Text("CamillaEQApp uses CamillaDSP as the hidden DSP engine and BlackHole 2ch as the system-audio loopback. CamillaGUI is not required.")
                    .foregroundStyle(.secondary)

                dependencyCard(
                    title: "CamillaDSP",
                    status: state.dependencies.camillaDSPStatus,
                    detail: "Installed privately under ~/Library/Application Support/CamillaEQApp/bin.",
                    action: { Task { await state.dependencies.installCamillaDSP() } }
                )

                dependencyCard(
                    title: "BlackHole 2ch",
                    status: state.dependencies.blackHoleStatus,
                    detail: "The official BlackHole package requires macOS administrator approval. CamillaEQApp keeps its virtual volume at 1.0.",
                    action: { Task { await state.dependencies.installBlackHole() } }
                )

                HStack {
                    Button("Install / Repair Everything") {
                        Task { await state.dependencies.installEverything() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Recheck") { state.dependencies.refresh() }
                }

                if !state.dependencies.setupMessage.isEmpty {
                    HStack(spacing: 10) {
                        if state.dependencies.setupInProgress {
                            ProgressView().controlSize(.small)
                        } else if state.dependencies.setupFailed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(state.dependencies.setupMessage)
                            .font(.callout.weight(.medium))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Toggle("Start CamillaEQApp when I log in", isOn: Binding(
                                get: { state.loginItem.isEnabled },
                                set: { state.loginItem.setEnabled($0) }
                            ))
                            .disabled(state.loginItem.isUpdating)

                            if state.loginItem.isUpdating {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Text(state.loginItem.statusMessage)
                            .font(.caption)
                            .foregroundStyle(state.loginItem.requiresApproval ? .orange : .secondary)

                        Text("This starts the app after you sign in to macOS. Keep the app in a permanent location so macOS can find it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { state.loginItem.refresh() }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("First use").font(.title2.bold())
                    Text("1. Install both dependencies. Installation alone does not change audio routing.\n2. Restart the Mac if BlackHole was just installed.\n3. Add your physical output as a profile from the sidebar.\n4. Adjust the visual equalizer, or import Equalizer APO text from a file or the clipboard.\n5. Turn on System-wide EQ. This starts CamillaDSP, saves configs/active.yml, and routes macOS through BlackHole.\n6. Approve Audio Input / Microphone permission if macOS asks; it is used for BlackHole capture and the live spectrum display.")
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dependencyCard(title: String, status: DependencyManager.Status, detail: String, action: @escaping () -> Void) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        statusIcon(status)
                        Text(title).font(.title3.bold())
                    }
                    Text(statusText(status)).font(.callout)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isInstalled(status) {
                    Button("Install", action: action).disabled(isWorking(status))
                }
            }.padding(6)
        }
    }

    private func statusText(_ status: DependencyManager.Status) -> String {
        switch status {
        case .checking: return "Checking…"
        case .missing: return "Not installed"
        case .installed(let version): return version ?? "Installed"
        case .working(let message): return message
        case .failed(let message): return message
        }
    }

    private func isInstalled(_ status: DependencyManager.Status) -> Bool {
        if case .installed = status { return true }; return false
    }
    private func isWorking(_ status: DependencyManager.Status) -> Bool {
        if case .working = status { return true }; return false
    }
    @ViewBuilder private func statusIcon(_ status: DependencyManager.Status) -> some View {
        if isInstalled(status) { Image(systemName: "checkmark.circle.fill") }
        else if case .failed = status { Image(systemName: "exclamationmark.triangle.fill") }
        else if isWorking(status) { ProgressView().controlSize(.small) }
        else { Image(systemName: "circle") }
    }
}

struct ProfileEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    @State private var parsedForGraph = ParsedEQ()
    @State private var preampDB = 0.0
    @State private var graphicBands: [EQBand] = []
    @State private var showTextImporter = false
    @State private var eqIsSaved = true
    @State private var suppressEQChanges = false
    @State private var liveApplyTask: Task<Void, Never>?

    private var profileIsActive: Bool { state.isActive && state.activeProfileID == profile.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name)
                        .font(.largeTitle.bold())
                    Spacer()
                    Toggle("System-wide EQ", isOn: Binding(
                        get: { profileIsActive },
                        set: { newValue in
                            Task {
                                if newValue { await state.activate(profile: profileWithCurrentEQ()) }
                                else { await state.deactivate(manual: true) }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                }

                routingAndDevice

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Audio levels").font(.title3.bold())
                        SignalMetersView(meters: state.meters)
                    }.padding(6)
                }

                LiveSpectrumPanels(
                    spectrum: state.spectrum,
                    parsedEQ: parsedForGraph,
                    sampleRate: profile.sampleRate
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Equalizer").font(.title3.bold())
                            Text(eqIsSaved ? "Saved" : "Not saved")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(eqIsSaved ? Color.green : Color.secondary)
                            Spacer()
                            Button("Import .txt") { showTextImporter = true }
                            Button("Paste APO Text") { importFromClipboard() }
                            Button { saveGraphicEQ() } label: {
                                Text("Save")
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 5)
                                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Supports Equalizer APO text with Preamp and PK/PEQ, LS, HS, LP/LPQ, HP/HPQ, NO, and AP filters, just like the original text editor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text("Bands")
                            Picker("Bands", selection: Binding(
                                get: { graphicBands.count },
                                set: { setBandCount($0) }
                            )) {
                                ForEach(1...20, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 64)
                        }
                        PreampControl(preampDB: $preampDB) {
                            calculateAutomaticPreamp()
                        }

                        if !graphicBands.isEmpty {
                            GeometryReader { viewport in
                                let minimumColumnWidth = 96.0
                                let fixedWidth = 48.0 + CGFloat(max(0, graphicBands.count - 1)) * 5
                                let minimumContentWidth = fixedWidth + CGFloat(graphicBands.count) * minimumColumnWidth
                                let requiresScrolling = minimumContentWidth > viewport.size.width + 1
                                let contentWidth = max(viewport.size.width, minimumContentWidth)
                                let columnWidth = max(
                                    minimumColumnWidth,
                                    (contentWidth - fixedWidth) / CGFloat(max(1, graphicBands.count))
                                )

                                PersistentHorizontalScrollView(
                                    contentWidth: contentWidth,
                                    contentHeight: requiresScrolling ? 386 : 378,
                                    showsScroller: requiresScrolling
                                ) {
                                    GraphicEqualizerBands(
                                        bands: $graphicBands,
                                        spectrum: state.spectrum,
                                        setKind: setKind,
                                        columnWidth: columnWidth
                                    )
                                    .frame(width: contentWidth)
                                    .padding(.bottom, requiresScrolling ? 8 : 0)
                                }
                            }
                            .frame(height: 402)
                        } else {
                            Text("Choose a band count above.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 90)
                        }
                    }.padding(6)
                }
            }
            .padding(28)
        }
        .onAppear { loadGraphicEQ() }
        .onChange(of: profile.id) { _ in loadGraphicEQ() }
        .onChange(of: preampDB) { _ in graphicEQChanged() }
        .onChange(of: graphicBands) { _ in graphicEQChanged() }
        .onDisappear { liveApplyTask?.cancel() }
        .fileImporter(isPresented: $showTextImporter, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try importAPOText(String(contentsOf: url, encoding: .utf8))
            } catch {
                state.errorMessage = "Could not import Equalizer APO text: \(error.localizedDescription)"
            }
        }
    }

    private var routingAndDevice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Routing & device behavior").font(.title3.bold())
                HStack {
                    VStack(alignment: .leading) {
                        Text("System audio input").font(.caption).foregroundStyle(.secondary)
                        Text(AudioDeviceInfo.blackHoleName)
                    }
                    Image(systemName: "arrow.right")
                    VStack(alignment: .leading) {
                        Text("Physical audio output").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { profile.outputDeviceUID },
                            set: { newUID in
                                if let device = state.coreAudio.device(uid: newUID) {
                                    state.profiles.setOutputDevice(profileID: profile.id, device: device)
                                }
                            }
                        )) {
                            ForEach(state.coreAudio.outputDevices.filter { $0.name != AudioDeviceInfo.blackHoleName }) { device in
                                Text(device.name).tag(device.id)
                            }
                        }.labelsHidden().frame(maxWidth: 320)
                    }
                    Spacer()
                    Text(profileIsActive ? "ACTIVE" : "BYPASSED")
                        .font(.caption.bold())
                }
                Toggle("Automatically activate when this physical output becomes the macOS default", isOn: Binding(
                    get: { profile.autoActivate },
                    set: { enabled in
                        state.profiles.setAutoActivate(profileID: profile.id, enabled: enabled)
                    }
                ))
                Toggle("Automatically activate when BlackHole is selected and this physical output is connected", isOn: Binding(
                    get: { profile.autoActivateWhenBlackHoleSelected ?? false },
                    set: { enabled in
                        state.profiles.setAutoActivateWhenBlackHoleSelected(profileID: profile.id, enabled: enabled)
                    }
                ))
                HStack {
                    Text("Processing sample rate")
                    Spacer()
                    Picker("Sample rate", selection: Binding(
                        get: { profile.sampleRate },
                        set: { newRate in
                            guard newRate != profile.sampleRate else { return }
                            profile.sampleRate = newRate
                            if profileIsActive {
                                let updatedProfile = profileWithCurrentEQ()
                                Task { await state.apply(profile: updatedProfile) }
                            }
                        }
                    )) {
                        ForEach([44_100, 48_000, 88_200, 96_000, 176_400, 192_000], id: \.self) { rate in
                            Text(rateLabel(rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }.padding(6)
        }
    }

    private func loadGraphicEQ() {
        guard let parsed = try? EqualizerAPOParser().parse(profile.equalizerAPOText) else { return }
        suppressEQChanges = true
        liveApplyTask?.cancel()
        preampDB = parsed.preampDB
        graphicBands = parsed.bands
        parsedForGraph = parsed
        eqIsSaved = true
        DispatchQueue.main.async { suppressEQChanges = false }
    }

    private func graphicEQChanged() {
        guard !suppressEQChanges else { return }
        parsedForGraph = ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        eqIsSaved = false
        guard profileIsActive else { return }
        liveApplyTask?.cancel()
        let updatedProfile = profileWithCurrentEQ()
        liveApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await state.apply(profile: updatedProfile)
        }
    }

    private func saveGraphicEQ() {
        liveApplyTask?.cancel()
        profile.equalizerAPOText = serializeGraphicEQ()
        eqIsSaved = true
        if profileIsActive {
            let updatedProfile = profile
            Task { await state.apply(profile: updatedProfile) }
        }
    }

    private func profileWithCurrentEQ() -> DeviceProfile {
        var updated = profile
        updated.equalizerAPOText = serializeGraphicEQ()
        return updated
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            state.errorMessage = "The clipboard does not contain Equalizer APO text."
            return
        }
        do { try importAPOText(text) }
        catch { state.errorMessage = "Invalid Equalizer APO text: \(error.localizedDescription)" }
    }

    private func importAPOText(_ text: String) throws {
        let parsed = try EqualizerAPOParser().parse(text)
        suppressEQChanges = true
        preampDB = parsed.preampDB
        graphicBands = parsed.bands
        parsedForGraph = parsed
        eqIsSaved = false
        DispatchQueue.main.async {
            suppressEQChanges = false
            graphicEQChanged()
        }
    }

    private func setBandCount(_ count: Int) {
        let target = min(20, max(0, count))
        let oldCount = graphicBands.count
        let customized = graphicBands.enumerated().compactMap { index, band in
            isDefaultBand(band, index: index, count: oldCount) ? nil : band
        }
        let resolvedTarget = max(target, customized.count)
        var candidateFrequencies = distributedFrequencies(count: resolvedTarget)

        // A customized band occupies the nearest normal EQ slot. Remove that
        // slot, then recreate only the untouched defaults. User-entered
        // frequency, gain, Q, and filter values are never altered.
        for custom in customized where !candidateFrequencies.isEmpty {
            let nearest = candidateFrequencies.indices.min {
                abs(log(candidateFrequencies[$0] / max(custom.frequency, 1)))
                    < abs(log(candidateFrequencies[$1] / max(custom.frequency, 1)))
            }
            if let nearest { candidateFrequencies.remove(at: nearest) }
        }

        var rebuilt = customized
        rebuilt.append(contentsOf: candidateFrequencies.map {
            EQBand(kind: .peaking, frequency: $0, gain: 0, q: 1)
        })
        rebuilt.sort { $0.frequency < $1.frequency }
        if let first = rebuilt.indices.first,
           isUntouchedValues(rebuilt[first]) {
            rebuilt[first].kind = .lowShelf
        }
        if let last = rebuilt.indices.last,
           last != rebuilt.indices.first,
           isUntouchedValues(rebuilt[last]) {
            rebuilt[last].kind = .highShelf
        }
        graphicBands = rebuilt
    }

    private func distributedFrequencies(count: Int) -> [Double] {
        let minimum = 31.0
        let maximum = 16_000.0
        return (0..<count).map { index in
            let position = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            return minimum * pow(maximum / minimum, position)
        }
    }

    private func isDefaultBand(_ band: EQBand, index: Int, count: Int) -> Bool {
        guard count > 0 else { return false }
        let expected = distributedFrequencies(count: count)[index]
        let expectedKind: EQBand.Kind = count > 1 && index == 0
            ? .lowShelf
            : (count > 1 && index == count - 1 ? .highShelf : .peaking)
        return abs(log(max(band.frequency, 1) / expected)) < 0.015
            && abs((band.gain ?? 0)) < 0.0001
            && abs((band.q ?? 1) - 1) < 0.0001
            && band.kind == expectedKind
    }

    private func isUntouchedValues(_ band: EQBand) -> Bool {
        abs((band.gain ?? 0)) < 0.0001 && abs((band.q ?? 1) - 1) < 0.0001
    }

    private func calculateAutomaticPreamp() {
        let withoutPreamp = ParsedEQ(preampDB: 0, bands: graphicBands, warnings: [])
        let response = EQResponseCalculator().calculate(
            parsed: withoutPreamp,
            sampleRate: Double(profile.sampleRate),
            count: 1_200
        )
        let maximumBoost = response.map(\.gainDB).max() ?? 0
        preampDB = max(-12, min(0, -maximumBoost))
    }

    private func setKind(_ kind: EQBand.Kind, for band: inout EQBand) {
        band.kind = kind
        band.q = band.q ?? 0.707
        band.bandwidth = nil
        band.gain = usesGain(kind) ? (band.gain ?? 0) : nil
    }

    private func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }

    private func filterLabel(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peaking"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        case .allPass: return "All pass"
        }
    }

    private func serializeGraphicEQ() -> String {
        var lines = ["Preamp: \(formatEQNumber(preampDB)) dB"]
        for (index, band) in graphicBands.enumerated() {
            var line = "Filter \(index + 1): ON \(filterToken(band.kind)) Fc \(formatEQNumber(max(1, band.frequency))) Hz"
            if usesGain(band.kind) { line += " Gain \(formatEQNumber(band.gain ?? 0)) dB" }
            line += " Q \(formatEQNumber(max(0.05, band.q ?? 0.707)))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func filterToken(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LPQ"
        case .highPass: return "HPQ"
        case .notch: return "NO"
        case .allPass: return "AP"
        }
    }

    private func formatEQNumber(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    private func rateLabel(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }
}

private struct PersistentHorizontalScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let showsScroller: Bool
    let content: Content

    init(
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        showsScroller: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.showsScroller = showsScroller
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = showsScroller

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView
        configureScroller(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        context.coordinator.hostingView?.frame.size = CGSize(width: contentWidth, height: contentHeight)
        scrollView.documentView?.frame.size = CGSize(width: contentWidth, height: contentHeight)
        configureScroller(scrollView)
    }

    private func configureScroller(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasHorizontalScroller = showsScroller
        scrollView.horizontalScroller?.isHidden = !showsScroller
        DispatchQueue.main.async {
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.hasHorizontalScroller = showsScroller
            scrollView.horizontalScroller?.isHidden = !showsScroller
        }
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

private struct LiveSpectrumPanels: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let parsedEQ: ParsedEQ
    let sampleRate: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    Text("Audio Input Spectrum").font(.headline)
                    LineGraph(
                        points: inputPoints,
                        xRange: 20...20_000,
                        yRange: -100...0,
                        fillsArea: true
                    )
                    .frame(height: 220)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Post-EQ Spectrum").font(.headline)
                    HStack(spacing: 12) {
                        Text("post-EQ").foregroundStyle(.green)
                        Text("EQ response").foregroundStyle(.blue)
                    }
                    .font(.caption)
                    SpectrumWithResponseGraph(
                        spectrum: outputPoints,
                        response: responsePoints.map { ($0.frequency, $0.gainDB) },
                        xRange: 20...20_000,
                        spectrumRange: -100...0,
                        responseRange: -12...12
                    )
                    .frame(height: 220)
                }
                .padding(6)
            }
        }
    }

    private var inputPoints: [(Double, Double)] {
        spectrum.points.map { ($0.frequency, $0.db) }
    }

    private var responsePoints: [EQResponsePoint] {
        EQResponseCalculator().calculate(parsed: parsedEQ, sampleRate: Double(sampleRate))
    }

    private var outputPoints: [(Double, Double)] {
        let response = responsePoints
        guard !response.isEmpty else { return inputPoints }
        let minimumFrequency = response[0].frequency
        let maximumFrequency = response[response.count - 1].frequency
        let logSpan = log(maximumFrequency / minimumFrequency)
        return spectrum.points.map { point in
            let position = log(max(point.frequency, minimumFrequency) / minimumFrequency) / logSpan
            let index = min(response.count - 1, max(0, Int(position * Double(response.count - 1))))
            return (point.frequency, min(0, point.db + response[index].gainDB))
        }
    }
}
