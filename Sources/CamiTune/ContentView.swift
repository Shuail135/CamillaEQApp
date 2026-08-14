import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var profileStore: ProfileStore
    @ObservedObject private var coreAudio: CoreAudioManager
    @ObservedObject private var updateChecker: AppUpdateChecker
    @State private var selection: String
    @State private var renameProfileID: UUID?
    @State private var renameDraft = ""
    @State private var showingOutputPicker = false
    @State private var pendingOutputUID: String?
    @FocusState private var focusedRenameID: UUID?

    init(state: AppState) {
        self.state = state
        self._profileStore = ObservedObject(wrappedValue: state.profiles)
        self._coreAudio = ObservedObject(wrappedValue: state.coreAudio)
        self._updateChecker = ObservedObject(wrappedValue: state.updateChecker)
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

                Button {
                    beginAddingOutput()
                } label: {
                    Label("Add Output", systemImage: "plus.circle.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Section("Output profiles") {
                    ForEach(profileStore.profiles) { profile in
                        HStack(spacing: 7) {
                            Image(systemName: "speaker.wave.2")
                                .foregroundStyle(
                                    profile.isEnabled ? Color.blue : Color.primary
                                )
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
                            if profile.isEnabled {
                                Button {
                                    Task { await state.setProfileEnabled(id: profile.id, enabled: false) }
                                } label: {
                                    Label("Deactivate Profile", systemImage: "stop.circle")
                                }
                            } else {
                                Button {
                                    Task { await state.setProfileEnabled(id: profile.id, enabled: true) }
                                } label: {
                                    Label("Activate Profile", systemImage: "play.circle")
                                }
                            }
                            Divider()
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
            .navigationTitle("CamiTune")
        } detail: {
            if selection == "setup" {
                SetupView(state: state)
            } else if let id = UUID(uuidString: selection),
                      let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditorView(
                    state: state,
                    coreAudio: coreAudio,
                    profile: $profileStore.profiles[index]
                )
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
        .sheet(isPresented: $showingOutputPicker) {
            AddOutputProfileSheet(
                devices: coreAudio.physicalOutputDevices,
                selectedUID: $pendingOutputUID,
                onCancel: {
                    showingOutputPicker = false
                    pendingOutputUID = nil
                },
                onAdd: addSelectedOutput
            )
        }
        .alert("CamiTune", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("Update Available", isPresented: Binding(
            get: { updateChecker.availableUpdate != nil },
            set: { isPresented in
                if !isPresented, updateChecker.availableUpdate != nil {
                    updateChecker.remindLater()
                }
            }
        )) {
            Button("Skip This Version") {
                updateChecker.skipAvailableVersion()
            }
            Button("Remind Me Later", role: .cancel) {
                updateChecker.remindLater()
            }
            Button("Update") {
                updateChecker.beginUpdate()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            if let update = updateChecker.availableUpdate {
                Text("CamiTune \(update.version) is available. You are currently using version \(updateChecker.installedVersion).")
            }
        }
        .alert(item: $updateChecker.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .overlay {
            if updateChecker.isDownloadingUpdate {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Downloading Update…")
                            .font(.headline)
                        Text("CamiTune will validate the download, then close. Reopen it to use the update.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 18)
                }
            }
        }
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renameProfileID,
           !name.isEmpty,
           profileStore.profiles.contains(where: { $0.id == id }) {
            state.renameProfile(id: id, to: name)
        }
        renameProfileID = nil
        focusedRenameID = nil
    }

    private func cancelRename() {
        renameProfileID = nil
        focusedRenameID = nil
        renameDraft = ""
    }

    private func beginAddingOutput() {
        coreAudio.refresh()
        let devices = coreAudio.physicalOutputDevices
        pendingOutputUID = devices.first(where: { $0.id == coreAudio.defaultOutputUID })?.id
            ?? devices.first?.id
        showingOutputPicker = true
    }

    private func addSelectedOutput() {
        guard let pendingOutputUID,
              let device = coreAudio.physicalOutputDevices.first(where: {
                  $0.id == pendingOutputUID
              }) else { return }
        profileStore.addProfile(for: device)
        if let profileID = profileStore.selectedProfileID {
            Task { await state.setAutoActivate(id: profileID, enabled: true) }
        }
        selection = profileStore.selectedProfileID?.uuidString ?? "setup"
        showingOutputPicker = false
        self.pendingOutputUID = nil
    }
}

private struct AddOutputProfileSheet: View {
    let devices: [AudioDeviceInfo]
    @Binding var selectedUID: String?
    let onCancel: () -> Void
    let onAdd: () -> Void

    private var selectedDevice: AudioDeviceInfo? {
        devices.first(where: { $0.id == selectedUID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add Output Profile")
                .font(.largeTitle.bold())
            Text("Choose the physical audio device that this profile will play through.")
                .foregroundStyle(.secondary)

            GroupBox {
                if devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "speaker.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No physical audio outputs are connected.")
                            .font(.headline)
                        Text("Connect an output device, then try again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(selection: $selectedUID) {
                        ForEach(devices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.wave.2")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(device.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } label: {
                Text("Audio outputs")
                    .font(.title3.bold())
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Profile", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDevice == nil)
            }
        }
        .padding(32)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 440, idealHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var dependencies: DependencyManager
    @ObservedObject private var loginItem: LoginItemManager

    init(state: AppState) {
        self.state = state
        self._dependencies = ObservedObject(wrappedValue: state.dependencies)
        self._loginItem = ObservedObject(wrappedValue: state.loginItem)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Setup").font(.largeTitle.bold())

                dependencyCard(
                    title: "CamillaDSP",
                    status: dependencies.camillaDSPStatus,
                    detail: "Installed under ~/Library/Application Support/CamiTune/bin.",
                    action: { Task { await dependencies.installCamillaDSP() } }
                )

                dependencyCard(
                    title: "System Audio Bridge Driver",
                    status: dependencies.audioDriverStatus,
                    detail: "Installed under ~/Library/Application Support/CamiTune/Driver; Installation asks once for macOS administrator approval.",
                    action: { Task { await dependencies.installAudioDriver() } }
                )

                HStack {
                    Button("Install / Repair Everything") {
                        Task { await dependencies.installEverything() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dependencies.setupInProgress)
                    Button("Recheck") {
                        Task { await dependencies.recheck() }
                    }
                    .disabled(dependencies.setupInProgress)
                }

                if !dependencies.setupMessage.isEmpty {
                    HStack(spacing: 10) {
                        if dependencies.setupInProgress {
                            ProgressView().controlSize(.small)
                        } else if dependencies.setupFailed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(dependencies.setupMessage)
                            .font(.callout.weight(.medium))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Toggle("Start CamiTune when I log in", isOn: Binding(
                                get: { loginItem.isEnabled },
                                set: { loginItem.setEnabled($0) }
                            ))
                            .disabled(loginItem.isUpdating)

                            if loginItem.isUpdating {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Text(loginItem.statusMessage)
                            .font(.caption)
                            .foregroundStyle(loginItem.requiresApproval ? .orange : .secondary)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { loginItem.refresh() }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("First use").font(.title2.bold())
                    Text("1. Select Install / Repair Everything, then approve the macOS administrator prompt.\n2. Restart the Mac only if Setup says the new audio device is not visible yet.\n3. Add your physical output as a profile from the sidebar.\n4. Adjust the visual equalizer, or import Equalizer APO text from a file or the clipboard.\n5. Enable either automatic activation condition for the profile.")
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
    @ObservedObject var coreAudio: CoreAudioManager
    @Binding var profile: DeviceProfile
    @State private var parsedForGraph = ParsedEQ()
    @State private var responsePointsForGraph: [EQResponsePoint] = []
    @State private var filterResponsePointsForGraph: [EQResponsePoint] = []
    @State private var preampDB = 0.0
    @State private var graphicBands: [EQBand] = []
    @State private var showTextImporter = false
    @State private var eqIsSaved = true
    @State private var suppressEQChanges = false
    @State private var liveApplyTask: Task<Void, Never>?
    @State private var isRenamingProfile = false
    @State private var renamingProfileID: UUID?
    @State private var profileNameDraft = ""
    @State private var focusClearingMonitor: Any?
    @FocusState private var profileNameFocused: Bool

    private var profileIsActive: Bool { state.isActive && state.activeProfileID == profile.id }
    private var profileRoutingName: String {
        ProfileRoutingDescriptor.descriptors(for: state.profiles.profiles)[profile.id]?.name
            ?? profile.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    if isRenamingProfile {
                        TextField("Profile name", text: $profileNameDraft)
                            .font(.largeTitle.bold())
                            .textFieldStyle(.plain)
                            .frame(minWidth: 180, maxWidth: 480)
                            .focused($profileNameFocused)
                            .onSubmit { commitProfileRename() }
                            .onExitCommand { cancelProfileRename() }
                    } else {
                        Text(profile.name)
                            .font(.largeTitle.bold())
                            .contentShape(Rectangle())
                            .onTapGesture { beginProfileRename() }
                            .help("Click to rename this profile")
                    }
                    if coreAudio.device(uid: profile.outputDeviceUID) == nil {
                        Label("Disconnected", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { profile.isEnabled },
                        set: { newValue in
                            Task { await state.setProfileEnabled(id: profile.id, enabled: newValue) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Activate Profile")
                    .help("Activate or deactivate this profile")
                }

                Text("The switch activates this profile. Its selected activation conditions decide when the EQ runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                routingAndDevice

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Audio levels").font(.title3.bold())
                        SignalMetersView(meters: state.meters)
                    }.padding(6)
                }

                LiveSpectrumPanels(
                    spectrum: state.spectrum,
                    responsePoints: responsePointsForGraph
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
                        Text("Supports Equalizer APO Preamp plus ON/OFF PK/PEQ, LS/LSC, HS/HSC, LP/LPQ, HP/HPQ, NO, and AP filters using Q or BW Oct.")
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

                                ScrollView(.horizontal, showsIndicators: requiresScrolling) {
                                    GraphicEqualizerBands(
                                        bands: $graphicBands,
                                        spectrum: state.spectrum,
                                        responsePoints: filterResponsePointsForGraph,
                                        setKind: setKind,
                                        columnWidth: columnWidth
                                    )
                                    .frame(width: contentWidth)
                                    .padding(.bottom, requiresScrolling ? 8 : 0)
                                }
                                .transaction { transaction in
                                    transaction.animation = nil
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
        .onAppear {
            loadGraphicEQ()
            installFocusClearingMonitor()
        }
        .onChange(of: profile.id) { _ in
            commitProfileRename()
            loadGraphicEQ()
        }
        .onChange(of: profileNameFocused) { isFocused in
            if isRenamingProfile && !isFocused { commitProfileRename() }
        }
        .onChange(of: preampDB) { _ in graphicEQChanged() }
        .onChange(of: graphicBands) { _ in graphicEQChanged() }
        .onDisappear {
            commitProfileRename()
            liveApplyTask?.cancel()
            preserveUnsavedEQDraft()
            removeFocusClearingMonitor()
        }
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

    private func beginProfileRename() {
        profileNameDraft = profile.name
        renamingProfileID = profile.id
        isRenamingProfile = true
        DispatchQueue.main.async { profileNameFocused = true }
    }

    private func commitProfileRename() {
        guard isRenamingProfile else { return }
        let trimmedName = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty,
           let profileID = renamingProfileID,
           state.profiles.profiles.contains(where: { $0.id == profileID }) {
            state.renameProfile(id: profileID, to: trimmedName)
        }
        isRenamingProfile = false
        renamingProfileID = nil
        profileNameFocused = false
    }

    private func cancelProfileRename() {
        isRenamingProfile = false
        renamingProfileID = nil
        profileNameFocused = false
        profileNameDraft = ""
    }

    private func installFocusClearingMonitor() {
        guard focusClearingMonitor == nil else { return }
        focusClearingMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let keyWindow = NSApp.keyWindow,
                  event.window === keyWindow,
                  let contentView = keyWindow.contentView else { return event }

            let location = contentView.convert(event.locationInWindow, from: nil)
            let clickedView = contentView.hitTest(location)
            if !Self.isTextInput(clickedView) {
                keyWindow.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeFocusClearingMonitor() {
        guard let focusClearingMonitor else { return }
        NSEvent.removeMonitor(focusClearingMonitor)
        self.focusClearingMonitor = nil
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var currentView = view
        while let view = currentView {
            if view is NSTextField || view is NSTextView { return true }
            currentView = view.superview
        }
        return false
    }

    private var routingAndDevice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Routing & device behavior").font(.title3.bold())
                HStack {
                    VStack(alignment: .leading) {
                        Text("System audio route").font(.caption).foregroundStyle(.secondary)
                        Text(profileRoutingName)
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
                            if coreAudio.device(uid: profile.outputDeviceUID) == nil {
                                Text("\(profile.outputDeviceName) (Disconnected)")
                                    .tag(profile.outputDeviceUID)
                            }
                            ForEach(coreAudio.physicalOutputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }.labelsHidden().frame(maxWidth: 320)
                    }
                    Spacer()
                    Text(profileIsActive ? "Activated" : "Not Activated")
                        .font(.caption.bold())
                        .foregroundStyle(profileIsActive ? Color.green : Color.secondary)
                }
                Toggle("Activate EQ when \(profile.outputDeviceName) is selected as the macOS audio output", isOn: Binding(
                    get: { profile.autoActivate },
                    set: { enabled in
                        Task { await state.setAutoActivate(id: profile.id, enabled: enabled) }
                    }
                ))
                Toggle("Activate EQ when \(profileRoutingName) is selected as the macOS audio output", isOn: Binding(
                    get: { profile.autoActivateWhenProfileDeviceSelected },
                    set: { enabled in
                        Task {
                            await state.setAutoActivateWhenProfileDeviceSelected(
                                id: profile.id,
                                enabled: enabled
                            )
                        }
                    }
                ))
                Text("The first condition routes the physical output through CamillaDSP. \n The second keeps the original physical output available for direct audio and activates EQ only when the profile-named output is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Processing sample rate")
                    Spacer()
                    Picker("Sample rate", selection: Binding(
                        get: { profile.sampleRate },
                        set: { newRate in
                            guard newRate != profile.sampleRate else { return }
                            profile.sampleRate = newRate
                            updateGraphResponses()
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
        let draft = state.eqDraft(for: profile.id)
        let source = draft ?? profile.equalizerAPOText
        guard let parsed = try? EqualizerAPOParser().parse(source) else { return }
        suppressEQChanges = true
        liveApplyTask?.cancel()
        preampDB = parsed.preampDB
        graphicBands = parsed.bands
        parsedForGraph = parsed
        updateGraphResponses()
        eqIsSaved = draft == nil
        DispatchQueue.main.async { suppressEQChanges = false }
    }

    private func graphicEQChanged() {
        guard !suppressEQChanges else { return }
        parsedForGraph = ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        updateGraphResponses()
        eqIsSaved = false
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        guard profileIsActive else { return }
        liveApplyTask?.cancel()
        let updatedProfile = profileWithCurrentEQ()
        liveApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.apply(profile: updatedProfile)
        }
    }

    private func saveGraphicEQ() {
        liveApplyTask?.cancel()
        profile.equalizerAPOText = serializeGraphicEQ()
        state.clearEQDraft(for: profile.id)
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

    private func preserveUnsavedEQDraft() {
        guard !eqIsSaved else { return }
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
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
        state.errorMessage = nil
        suppressEQChanges = true
        preampDB = parsed.preampDB
        graphicBands = parsed.bands
        parsedForGraph = parsed
        updateGraphResponses()
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

    private func updateGraphResponses() {
        let response = EQResponseCalculator().calculate(
            parsed: parsedForGraph,
            sampleRate: Double(profile.sampleRate)
        )
        responsePointsForGraph = response
        filterResponsePointsForGraph = response.map {
            EQResponsePoint(frequency: $0.frequency, gainDB: $0.gainDB - parsedForGraph.preampDB)
        }
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
            && band.enabled
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
            let stateToken = band.enabled ? "ON" : "OFF"
            var line = "Filter \(index + 1): \(stateToken) \(filterToken(band.kind)) Fc \(formatEQNumber(max(1, band.frequency))) Hz"
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

private struct LiveSpectrumPanels: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let responsePoints: [EQResponsePoint]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    Text("Pre-EQ Spectrum").font(.headline)
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
