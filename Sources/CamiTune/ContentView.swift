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
        if let saved, saved == "setup" || saved == "default-profiles" {
            restored = saved
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
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle.fill").frame(width: 18)
                        Text("Add Output")
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Label("Default Profiles", systemImage: "speaker.wave.2.fill")
                    .tag("default-profiles")

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
            } else if selection == "default-profiles" {
                DefaultProfilesView(state: state)
            } else if let id = UUID(uuidString: selection),
                      let index = profileStore.profiles.firstIndex(where: { $0.id == id }) {
                ProfileEditorView(
                    state: state,
                    coreAudio: coreAudio,
                    profile: $profileStore.profiles[index]
                )
                .id(id)
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
        let profileID = state.addProfile(for: device)
        selection = profileID?.uuidString ?? "setup"
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
                    detail: "UID-capable build bundled with CamiTune; installed under ~/Library/Application Support/CamiTune/bin.",
                    action: {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installCamillaDSP()
                        }
                    }
                )

                dependencyCard(
                    title: "System Audio Bridge Driver",
                    status: dependencies.audioDriverStatus,
                    detail: "Installed under ~/Library/Application Support/CamiTune/Drivers; installation asks once for macOS administrator approval.",
                    action: {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installAudioDriver()
                        }
                    }
                )

                HStack {
                    Button("Install / Repair Everything") {
                        Task {
                            guard await state.prepareForDependencyRepair() else { return }
                            await dependencies.installEverything()
                        }
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
                    Text("1. Select Install / Repair Everything, then approve the macOS administrator prompt.\n2. Restart the Mac only if Setup says the new audio device is not visible yet.\n3. Add your physical output as a profile from the sidebar.\n4. Select Default Profiles in the sidebar to choose which profile starts with each physical output.\n5. Adjust the visual equalizer, or import Equalizer APO text from a file or the clipboard.")
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

struct DefaultProfilesView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var profileStore: ProfileStore
    @ObservedObject private var coreAudio: CoreAudioManager

    init(state: AppState) {
        self.state = state
        self._profileStore = ObservedObject(wrappedValue: state.profiles)
        self._coreAudio = ObservedObject(wrappedValue: state.coreAudio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default Profiles").font(.largeTitle.bold())
            Text("Choose the profile that starts when each physical output is selected in macOS. Only one profile can be the hardware default; other profiles can still use their profile-named audio devices.")
                .foregroundStyle(.secondary)

            Divider()

            if knownPhysicalOutputs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "speaker.slash").font(.largeTitle)
                    Text("No Physical Outputs").font(.title2.bold())
                    Text("Add an output profile in the main CamiTune window first.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(knownPhysicalOutputs) { device in
                            GroupBox {
                                HStack(alignment: .center, spacing: 18) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).font(.headline)
                                        Text(device.uid)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Picker("Starts profile", selection: automaticProfileBinding(for: device)) {
                                        Text("None").tag(UUID?.none)
                                        ForEach(profiles(for: device.uid)) { profile in
                                            Text(profile.isEnabled ? profile.name : "\(profile.name) (Disabled)")
                                                .tag(Optional(profile.id))
                                        }
                                    }
                                    .frame(width: 280)
                                }
                                .padding(6)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var knownPhysicalOutputs: [PhysicalOutputIdentity] {
        var devicesByUID: [String: PhysicalOutputIdentity] = [:]
        for selection in profileStore.physicalDeviceDefaults {
            devicesByUID[selection.physicalDevice.uid] = selection.physicalDevice
        }
        for profile in profileStore.profiles where devicesByUID[profile.outputDeviceUID] == nil {
            devicesByUID[profile.outputDeviceUID] = profile.outputDevice
        }
        for device in coreAudio.physicalOutputDevices {
            devicesByUID[device.id] = PhysicalOutputIdentity(uid: device.id, name: device.name)
        }
        return devicesByUID.values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.uid < $1.uid
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func profiles(for physicalDeviceUID: String) -> [DeviceProfile] {
        profileStore.profiles
            .filter { $0.outputDeviceUID == physicalDeviceUID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func automaticProfileBinding(for device: PhysicalOutputIdentity) -> Binding<UUID?> {
        Binding(
            get: {
                let profileID = profileStore.automaticProfileID(forPhysicalDeviceUID: device.uid)
                return profiles(for: device.uid).contains(where: { $0.id == profileID }) ? profileID : nil
            },
            set: { profileID in
                Task {
                    await state.setAutomaticProfile(for: device, profileID: profileID)
                }
            }
        )
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
    @State private var limiterEnabled = false
    @State private var automaticSystemHeadroomDB = 0.0
    @State private var graphicBands: [EQBand] = []
    @State private var pendingBandCount: Int?
    @State private var showBandReductionConfirmation = false
    @State private var showTextImporter = false
    @State private var showDeviceCorrectionEditor = false
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

    private enum AutomaticActivationChoice: Hashable {
        case physicalOutput
        case profileAudioDevice
        case manual
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
                    .accessibilityLabel("Enable Profile")
                    .help("Make this profile available for activation")
                }

                Text("The switch activates this profile. Its selected activation conditions decide when the EQ runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                routingAndDevice

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meters & status").font(.title3.bold())
                        SignalMetersView(meters: state.meters, profileID: profile.id)
                        Divider()
                        AudioRuntimeStatusView(monitor: state.meters, profileID: profile.id)
                    }.padding(6)
                }

                LiveSpectrumPanels(
                    spectrum: state.spectrum,
                    profileID: profile.id,
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
                            Button("Device Correction…") {
                                showDeviceCorrectionEditor = true
                            }
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
                        Text("Imports ON/OFF PK/PEQ, LS/LSC, HS/HSC, LP/LPQ, HP/HPQ, NO, and AP filters using Q, BW Oct, or 6/12 dB shelf slopes. APO Preamp is ignored; use User Preamp instead. Other valid APO commands are skipped.")
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
                        PreampGainControl(
                            gainDB: $preampDB,
                            limiterEnabled: $limiterEnabled,
                            meters: state.meters,
                            profileID: profile.id
                        )
                        Text("Automatic system headroom: \(automaticSystemHeadroomDB, format: .number.precision(.fractionLength(2))) dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !graphicBands.isEmpty {
                            let columnWidth = 96.0
                            let contentWidth = GraphicEqualizerBands.requiredContentWidth(
                                bandCount: graphicBands.count,
                                columnWidth: columnWidth
                            )
                            OverflowAwareHorizontalScrollView(
                                contentWidth: contentWidth,
                                height: 402
                            ) {
                                GraphicEqualizerBands(
                                    bands: $graphicBands,
                                    spectrum: state.spectrum,
                                    profileID: profile.id,
                                    responsePoints: filterResponsePointsForGraph,
                                    setKind: setKind,
                                    columnWidth: columnWidth
                                )
                            }

                            Divider()
                            SimpleEQControlsView(bands: $graphicBands)
                        } else {
                            Text("Choose a band count above.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 90)
                        }
                    }.padding(6)
                }

                PerChannelProcessingView(
                    state: state,
                    profile: $profile
                )
            }
            .padding(28)
        }
        .onAppear {
            state.setRuntimeVisuals(profileID: profile.id, active: true)
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
        .onChange(of: limiterEnabled) { _ in graphicEQChanged() }
        .onChange(of: graphicBands) { _ in graphicEQChanged() }
        .onChange(of: profile.sampleRate) { _ in updateGraphResponses() }
        .onChange(of: state.eqDraftRevision) { _ in updateAutomaticSystemHeadroom() }
        .onDisappear {
            state.setRuntimeVisuals(profileID: profile.id, active: false)
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
        .sheet(isPresented: $showDeviceCorrectionEditor) {
            DeviceCorrectionEditorView(
                existing: currentDeviceCorrectionProvenance,
                sampleRate: Double(profile.sampleRate),
                automaticHeadroom: automaticHeadroomForCorrection,
                shouldConfirmReplacement: {
                    EQEditorSupport.hasMeaningfulProcessing(ParsedEQ(
                        preampDB: preampDB,
                        bands: graphicBands,
                        warnings: []
                    ))
                },
                onCancel: { showDeviceCorrectionEditor = false },
                onLoad: loadDeviceCorrectionEQ
            )
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
                                    Task {
                                        await state.setOutputDevice(
                                            profileID: profile.id,
                                            device: device
                                        )
                                    }
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
                Divider()
                Text("Automatic activation").font(.headline)
                Picker("How this profile starts", selection: automaticActivationBinding) {
                    Text("Physical output — when \(profile.outputDeviceName) is selected")
                        .tag(AutomaticActivationChoice.physicalOutput)
                    Text("Profile audio device — when \(profileRoutingName) is selected")
                        .tag(AutomaticActivationChoice.profileAudioDevice)
                    Text("Manual only — activate from CamiTune")
                        .tag(AutomaticActivationChoice.manual)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(automaticActivationExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if automaticActivationChoice == .manual {
                    Button(profileIsActive ? "Deactivate EQ" : "Activate EQ Now") {
                        Task {
                            if profileIsActive {
                                await state.deactivate(manual: true)
                            } else {
                                await state.activate(profile: profile)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !profileIsActive &&
                            (!profile.isEnabled || coreAudio.device(uid: profile.outputDeviceUID) == nil)
                    )
                }

                if let otherProfile = physicalActivationOwner, otherProfile.id != profile.id {
                    Label(
                        "\(profile.outputDeviceName) currently starts \(otherProfile.name). Choose Physical output above only if you want this profile to become the new default.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
                HStack {
                    Text("Processing sample rate")
                    Spacer()
                    Picker("Sample rate", selection: Binding(
                        get: { profile.sampleRate },
                        set: { newRate in
                            guard newRate != profile.sampleRate else { return }
                            guard state.processingSampleRateProblem(
                                rate: newRate,
                                outputUID: profile.outputDeviceUID
                            ) == nil else {
                                state.reportProcessingSampleRateProblem(
                                    rate: newRate,
                                    outputUID: profile.outputDeviceUID
                                )
                                return
                            }
                            profile.sampleRate = newRate
                            updateGraphResponses()
                            if profileIsActive {
                                let updatedProfile = profileWithCurrentEQ()
                                Task { await state.apply(profile: updatedProfile) }
                            }
                        }
                    )) {
                        ForEach([44_100, 48_000, 88_200, 96_000, 176_400, 192_000], id: \.self) { rate in
                            let unsupported = state.processingSampleRateProblem(
                                rate: rate,
                                outputUID: profile.outputDeviceUID
                            ) != nil
                            Text(unsupported ? "\(rateLabel(rate)) — Unsupported" : rateLabel(rate))
                                .tag(rate)
                                .disabled(unsupported)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                Text("Higher rates increase CPU and bandwidth use but do not improve lower-rate source audio; 48 kHz is the recommended default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem = state.processingSampleRateProblem(
                    rate: profile.sampleRate,
                    outputUID: profile.outputDeviceUID
                ) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }.padding(6)
        }
    }

    private var physicalActivationOwner: DeviceProfile? {
        guard let profileID = state.profiles.automaticProfileID(
            forPhysicalDeviceUID: profile.outputDeviceUID
        ) else { return nil }
        return state.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var automaticActivationChoice: AutomaticActivationChoice {
        if physicalActivationOwner?.id == profile.id { return .physicalOutput }
        if profile.autoActivateWhenProfileDeviceSelected { return .profileAudioDevice }
        return .manual
    }

    private var automaticActivationBinding: Binding<AutomaticActivationChoice> {
        Binding(
            get: { automaticActivationChoice },
            set: { choice in
                Task { await setAutomaticActivation(choice) }
            }
        )
    }

    private var automaticActivationExplanation: String {
        switch automaticActivationChoice {
        case .physicalOutput:
            return "This is the default profile for this hardware. Selecting the physical output in macOS routes audio through this EQ."
        case .profileAudioDevice:
            return "The physical output remains available for direct playback. Select the profile-named audio device in macOS when you want this EQ."
        case .manual:
            return "Changing the macOS audio output will not start this profile automatically."
        }
    }

    private func setAutomaticActivation(_ choice: AutomaticActivationChoice) async {
        switch choice {
        case .physicalOutput:
            await state.setAutomaticProfile(
                for: profile.outputDevice,
                profileID: profile.id
            )
        case .profileAudioDevice:
            await state.setAutoActivateWhenProfileDeviceSelected(id: profile.id, enabled: true)
        case .manual:
            if physicalActivationOwner?.id == profile.id {
                await state.setAutomaticProfile(for: profile.outputDevice, profileID: nil)
            }
            await state.setAutoActivateWhenProfileDeviceSelected(id: profile.id, enabled: false)
        }
    }

    private func loadGraphicEQ() {
        let draft = state.eqDraft(for: profile.id)
        let limiterDraft = state.limiterDraft(for: profile.id)
        let parsed: ParsedEQ
        let persistedLimiterEnabled: Bool
        var migratedDeviceCorrection = false
        do {
            let processing = try profile.resolvedProcessing()
            persistedLimiterEnabled = processing.limiterEnabled
            if let draft {
                parsed = try EqualizerAPOParser().parse(draft)
            } else {
                if processing.deviceCorrection != nil {
                    parsed = processing.globalEqualizerIncludingDeviceCorrection
                    migratedDeviceCorrection = true
                    state.setDeviceCorrectionProvenanceDraft(
                        processing.deviceCorrection,
                        for: profile.id
                    )
                    state.markEQDraftAsReplacingDeviceCorrection(for: profile.id)
                    state.setEQDraft(
                        EqualizerAPOSerializer().serialize(parsed),
                        for: profile.id
                    )
                } else {
                    parsed = processing.globalEqualizer
                }
            }
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }
        suppressEQChanges = true
        liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(parsed.bands)
        preampDB = parsed.preampDB
        limiterEnabled = limiterDraft ?? persistedLimiterEnabled
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(
            preampDB: parsed.preampDB,
            bands: organizedBands,
            warnings: parsed.warnings
        )
        updateGraphResponses()
        eqIsSaved = draft == nil && limiterDraft == nil && !migratedDeviceCorrection
        DispatchQueue.main.async { suppressEQChanges = false }
    }

    private func graphicEQChanged() {
        guard !suppressEQChanges else { return }
        parsedForGraph = ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        updateGraphResponses()
        eqIsSaved = false
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        state.setLimiterDraft(limiterEnabled, for: profile.id)
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
        profile.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        profile.processing.setLimiterEnabled(limiterEnabled)
        if state.eqDraftReplacesDeviceCorrection(for: profile.id) {
            profile.processing.setDeviceCorrection(nil)
        }
        state.applyDeviceCorrectionProvenanceDraft(
            to: &profile.processing,
            for: profile.id
        )
        state.clearEQDraft(for: profile.id)
        eqIsSaved = true
        if profileIsActive {
            let updatedProfile = (try? state.applyingSessionEQDrafts(to: profile)) ?? profile
            Task { await state.apply(profile: updatedProfile) }
        }
    }

    private func profileWithCurrentEQ() -> DeviceProfile {
        var updated = profile
        updated.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
        updated.processing.setLimiterEnabled(limiterEnabled)
        return (try? state.applyingSessionEQDrafts(to: updated)) ?? updated
    }

    private func preserveUnsavedEQDraft() {
        guard !eqIsSaved else { return }
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        state.setLimiterDraft(limiterEnabled, for: profile.id)
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
        let preservedUserPreampDB = preampDB
        let parsed = try EqualizerAPOParser().parse(text, preampPolicy: .ignore)
        state.clearTransientError()
        // A valid APO document may contain only commands that CamiTune cannot
        // represent yet (for example Include or Convolution). Treat that as a
        // successful no-op instead of replacing the current EQ with a flat graph.
        guard parsed.importedDirectiveCount > 0 else { return }
        suppressEQChanges = true
        let organizedBands = EQEditorSupport.organizedBands(parsed.bands)
        // APO Preamp must never become User Preamp. Reapply the captured value
        // before and after SwiftUI processes the bands mutation so an import
        // cannot leak gain through a deferred view update.
        preampDB = preservedUserPreampDB
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(
            preampDB: preservedUserPreampDB,
            bands: organizedBands,
            warnings: parsed.warnings
        )
        updateGraphResponses()
        eqIsSaved = false
        state.setDeviceCorrectionProvenanceDraft(nil, for: profile.id)
        DispatchQueue.main.async {
            preampDB = preservedUserPreampDB
            suppressEQChanges = false
            graphicEQChanged()
        }
    }

    private func setBandCount(_ count: Int) {
        guard count != graphicBands.count else { return }
        if EQEditorSupport.shouldRefitWhenReducing(graphicBands, to: count) {
            pendingBandCount = count
            showBandReductionConfirmation = true
            return
        }
        graphicBands = EQEditorSupport.resizedBands(graphicBands, count: count)
    }

    private var bandReductionConfirmationMessage: String {
        let target = pendingBandCount ?? graphicBands.count
        return "Every current band has an active value. Reducing from \(graphicBands.count) to \(target) bands will recalculate frequency, gain, and Q to approximate the same overall EQ response."
    }

    private func applyPendingBandReduction() {
        guard let target = pendingBandCount else { return }
        pendingBandCount = nil
        graphicBands = EQEditorSupport.responseFittedBands(
            graphicBands,
            count: target,
            sampleRate: Double(profile.sampleRate)
        )
    }

    private func updateGraphResponses() {
        let calculator = EQResponseCalculator()
        var combined = parsedForGraph
        if !state.eqDraftReplacesDeviceCorrection(for: profile.id),
           let correction = profile.processing.deviceCorrection,
           correction.isEnabled {
            combined.bands.insert(contentsOf: correction.filters, at: 0)
        }
        responsePointsForGraph = calculator.calculate(
            parsed: combined,
            sampleRate: Double(profile.sampleRate)
        )
        filterResponsePointsForGraph = calculator.calculate(
            parsed: ParsedEQ(preampDB: 0, bands: graphicBands, warnings: []),
            sampleRate: Double(profile.sampleRate)
        )
        updateAutomaticSystemHeadroom()
    }

    private func loadDeviceCorrectionEQ(_ correction: DeviceCorrectionProfile) {
        suppressEQChanges = true
        liveApplyTask?.cancel()
        let organizedBands = EQEditorSupport.organizedBands(correction.filters)
        preampDB = 0
        graphicBands = organizedBands
        parsedForGraph = ParsedEQ(
            preampDB: 0,
            bands: organizedBands,
            warnings: []
        )
        state.markEQDraftAsReplacingDeviceCorrection(for: profile.id)
        state.setDeviceCorrectionProvenanceDraft(correction, for: profile.id)
        state.setEQDraft(serializeGraphicEQ(), for: profile.id)
        eqIsSaved = false
        showDeviceCorrectionEditor = false
        updateGraphResponses()
        DispatchQueue.main.async {
            suppressEQChanges = false
            graphicEQChanged()
        }
    }

    private func updateAutomaticSystemHeadroom() {
        do {
            var current = profile
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
            current = try state.applyingSessionEQDrafts(to: current)
            // The visible editor is authoritative even before its draft write is
            // published; channel drafts still come from AppState.
            current.setGlobalEqualizer(preampDB: preampDB, bands: graphicBands)
            automaticSystemHeadroomDB = try ProcessingGraphBuilder().build(
                profile: current
            ).automaticHeadroomDB
        } catch {
            automaticSystemHeadroomDB = 0
        }
    }

    private func automaticHeadroomForCorrection(_ filters: [EQBand]) -> Double {
        do {
            var candidate = profile
            candidate = try state.applyingSessionEQDrafts(to: candidate)
            candidate.processing.setDeviceCorrection(nil)
            candidate.setGlobalEqualizer(preampDB: 0, bands: filters)
            return try ProcessingGraphBuilder().build(profile: candidate).automaticHeadroomDB
        } catch {
            return 0
        }
    }

    private var currentDeviceCorrectionProvenance: DeviceCorrectionProfile? {
        state.deviceCorrectionProvenance(
            for: profile.id,
            persisted: profile.processing.globalEqualizerProvenance
                ?? profile.processing.deviceCorrection
        )
    }

    private func setKind(_ kind: EQBand.Kind, for band: inout EQBand) {
        EQEditorSupport.setKind(kind, for: &band)
    }

    private func serializeGraphicEQ() -> String {
        EqualizerAPOSerializer().serialize(
            ParsedEQ(preampDB: preampDB, bands: graphicBands, warnings: [])
        )
    }

    private func rateLabel(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }
}

private struct LiveSpectrumPanels: View {
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let responsePoints: [EQResponsePoint]

    var body: some View {
        let graphResponse = responsePoints.map { ($0.frequency, $0.gainDB) }
        HStack(alignment: .top, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    Text("Pre-EQ Spectrum").font(.headline)
                    LivePreEQSpectrumGraph(spectrum: spectrum, profileID: profileID)
                        .frame(height: 220)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity)

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Estimated Post-Global EQ Spectrum").font(.headline)
                    HStack(spacing: 12) {
                        Text("post-EQ").foregroundStyle(.green)
                        Text("EQ response").foregroundStyle(.blue)
                    }
                    .font(.caption)
                    LivePostEQSpectrumGraph(
                        spectrum: spectrum,
                        profileID: profileID,
                        response: graphResponse
                    )
                    .frame(height: 220)
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 284)
    }

}

struct OverflowAwareHorizontalScrollView<Content: View>: View {
    let contentWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let needsScrolling = contentWidth > geometry.size.width + 0.5
            if needsScrolling {
                ScrollView(.horizontal, showsIndicators: true) {
                    content()
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.bottom, 8)
                        .background(PersistentHorizontalScroller())
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            } else {
                content()
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .frame(height: height)
    }
}

private struct PersistentHorizontalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(from: nsView)
    }

    private func configure(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    scrollView.hasHorizontalScroller = true
                    scrollView.autohidesScrollers = false
                    scrollView.scrollerStyle = .legacy
                    scrollView.horizontalScrollElasticity = .none
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

private struct LivePreEQSpectrumGraph: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let profileID: UUID

    var body: some View {
        LineGraph(
            points: inputPoints,
            xRange: 20...20_000,
            yRange: -100...0,
            fillsArea: true
        )
    }

    private var inputPoints: [(Double, Double)] {
        guard spectrum.activeProfileID == profileID else { return [] }
        return spectrum.points.map { ($0.frequency, $0.db) }
    }
}

private struct LivePostEQSpectrumGraph: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    let profileID: UUID
    let response: [(Double, Double)]

    var body: some View {
        SpectrumWithResponseGraph(
            spectrum: outputPoints,
            response: response,
            xRange: 20...20_000,
            spectrumRange: -100...0,
            responseRange: -12...12
        )
    }

    private var outputPoints: [(Double, Double)] {
        guard spectrum.activeProfileID == profileID else { return [] }
        guard !response.isEmpty else { return inputPoints }
        let minimumFrequency = response[0].0
        let maximumFrequency = response[response.count - 1].0
        let logSpan = log(maximumFrequency / minimumFrequency)
        return spectrum.points.map { point in
            let position = log(max(point.frequency, minimumFrequency) / minimumFrequency) / logSpan
            let index = min(response.count - 1, max(0, Int(position * Double(response.count - 1))))
            return (point.frequency, min(0, point.db + response[index].1))
        }
    }

    private var inputPoints: [(Double, Double)] {
        spectrum.points.map { ($0.frequency, $0.db) }
    }
}
