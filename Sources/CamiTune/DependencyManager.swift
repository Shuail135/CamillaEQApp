import Foundation

@MainActor
final class DependencyManager: ObservableObject {
    enum Status: Equatable {
        case checking
        case missing
        case installed(String?)
        case working(String)
        case failed(String)
    }

    @Published var camillaDSPStatus: Status = .checking
    @Published var audioDriverStatus: Status = .checking
    @Published var setupMessage: String = ""
    @Published var setupInProgress = false
    @Published var setupFailed = false

    private let coreAudio: CoreAudioManager
    private static let coreAudioUIDCapability = "coreaudio-uid-v1"

    init(coreAudio: CoreAudioManager) {
        self.coreAudio = coreAudio
        refresh()
    }

    var supportDirectory: URL {
        let base = CamiTunePaths.supportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var camillaDSPBinary: URL { supportDirectory.appendingPathComponent("bin/camilladsp") }
    private var camillaDSPCapabilityMarker: URL {
        supportDirectory.appendingPathComponent("bin/camilladsp.capabilities")
    }
    private var managedDriverURL: URL {
        supportDirectory
            .appendingPathComponent("Drivers", isDirectory: true)
            .appendingPathComponent("CamillaAudio.driver", isDirectory: true)
    }

    private func createSupportLayout() throws {
        for directory in ["bin", "configs", "coeffs", "logs"] {
            try FileManager.default.createDirectory(
                at: supportDirectory.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func refresh() {
        try? createSupportLayout()
        if FileManager.default.isExecutableFile(atPath: camillaDSPBinary.path),
           (try? String(contentsOf: camillaDSPCapabilityMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == Self.coreAudioUIDCapability {
            camillaDSPStatus = .installed(version(of: camillaDSPBinary))
        } else if FileManager.default.isExecutableFile(atPath: camillaDSPBinary.path) {
            camillaDSPStatus = .failed(
                "Installed build lacks required Core Audio UID support. Select Install / Repair Everything."
            )
        } else {
            camillaDSPStatus = .missing
        }
        coreAudio.refresh()
        if coreAudio.isSystemAudioBridgePresentationSupported {
            let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
            audioDriverStatus = .installed("System Audio Bridge \(version)")
        } else if coreAudio.systemAudioBridge != nil {
            let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
            audioDriverStatus = .failed("Driver \(version) is outdated; select Install / Repair Everything.")
        } else {
            audioDriverStatus = .missing
        }
        if case .installed = camillaDSPStatus, case .installed = audioDriverStatus, setupMessage.isEmpty {
            setupMessage = "Dependencies are ready."
        }
    }

    func recheck() async {
        guard !setupInProgress else { return }
        setupFailed = false
        setupInProgress = true
        setupMessage = "Checking CamillaDSP and the system-audio routing driver…"
        camillaDSPStatus = .checking
        audioDriverStatus = .checking
        defer { setupInProgress = false }

        for attempt in 0..<8 {
            refresh()
            if coreAudio.isSystemAudioBridgePresentationSupported { break }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(500)) }
        }

        var missing: [String] = []
        if case .installed = camillaDSPStatus {} else { missing.append("CamillaDSP") }
        if case .installed = audioDriverStatus {} else { missing.append("System Audio Bridge") }

        if missing.isEmpty {
            setupFailed = false
            setupMessage = "Setup complete. CamillaDSP and the audio routing driver are ready."
        } else {
            setupFailed = true
            setupMessage = "Recheck complete. Not detected: " + missing.joined(separator: ", ") + "."
        }
    }

    func installCamillaDSP() async {
        setupFailed = false
        setupInProgress = true
        setupMessage = "Installing the bundled UID-capable CamillaDSP build…"
        defer { setupInProgress = false }
        camillaDSPStatus = .working("Installing CamiTune's UID-capable CamillaDSP build…")
        do {
            try createSupportLayout()
            guard let binary = Bundle.main.url(
                forResource: "camilladsp",
                withExtension: nil,
                subdirectory: "CamillaDSP"
            ) else { throw SetupError.bundledCamillaDSPMissing }
            let binDir = camillaDSPBinary.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: camillaDSPBinary)
            try? FileManager.default.removeItem(at: camillaDSPCapabilityMarker)
            try FileManager.default.copyItem(at: binary, to: camillaDSPBinary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: camillaDSPBinary.path)
            _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", camillaDSPBinary.path])
            try Self.coreAudioUIDCapability.write(
                to: camillaDSPCapabilityMarker,
                atomically: true,
                encoding: .utf8
            )
            setupMessage = "UID-capable CamillaDSP is installed and verified."
            refresh()
        } catch {
            setupFailed = true
            camillaDSPStatus = .failed(error.localizedDescription)
            setupMessage = "CamillaDSP installation failed: \(error.localizedDescription)"
        }
    }

    func installAudioDriver() async {
        setupFailed = false
        setupInProgress = true
        setupMessage = "Installing the bundled System Audio Bridge driver…"
        defer { setupInProgress = false }
        audioDriverStatus = .working("Waiting for macOS administrator approval…")
        do {
            guard let bundledDriver = Bundle.main.url(
                forResource: "CamillaAudio",
                withExtension: "driver",
                subdirectory: "Drivers"
            ) else {
                throw SetupError.bundledDriverMissing
            }
            _ = try run("/usr/bin/codesign", ["--verify", "--strict", bundledDriver.path])

            // Keep CamiTune's own copy of the driver with the rest of its
            // managed dependencies. macOS loads HAL drivers from /Library, so
            // the privileged install below remains necessary, but this copy
            // gives the app a single owned location for future cleanup.
            try FileManager.default.createDirectory(
                at: managedDriverURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: managedDriverURL.path) {
                try FileManager.default.removeItem(at: managedDriverURL)
            }
            try FileManager.default.copyItem(at: bundledDriver, to: managedDriverURL)
            _ = try run("/usr/bin/codesign", ["--verify", "--strict", managedDriverURL.path])

            coreAudio.destroyAllProfileRoutingDevices()
            let destination = "/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver"
            let legacyDestinations = [
                "/Library/Audio/Plug-Ins/HAL/CamillaEQAudio.driver",
                "/Library/Audio/Plug-Ins/HAL/CamillaAudioBridge.driver",
                "/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver"
            ]
            let removalTargets = ([destination] + legacyDestinations)
                .map(shellQuote)
                .joined(separator: " ")
            let command = [
                "/bin/rm -rf \(removalTargets)",
                "/usr/bin/ditto \(shellQuote(managedDriverURL.path)) \(shellQuote(destination))",
                "/usr/sbin/chown -R root:wheel \(shellQuote(destination))",
                "/bin/chmod -R go-w \(shellQuote(destination))",
                "(/usr/bin/xattr -dr com.apple.quarantine \(shellQuote(destination)) || true)",
                "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"
            ].joined(separator: " && ")
            let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            try run("/usr/bin/osascript", ["-e", script])

            // The copy can finish before CoreAudio publishes the new device.
            // Poll the live device list so setup completes without relaunching the app.
            if await waitForAudioDriver() {
                let version = coreAudio.installedSystemAudioBridgeVersion ?? "unknown"
                audioDriverStatus = .installed("System Audio Bridge \(version)")
                setupMessage = "Dependencies are ready."
            } else {
                setupFailed = true
                setupMessage = "System Audio Bridge was installed, but CoreAudio has not exposed it yet. Restart the Mac, then select Recheck."
                audioDriverStatus = .failed("Installed; restart macOS, then select Recheck.")
            }
        } catch {
            setupFailed = true
            audioDriverStatus = .failed(error.localizedDescription)
            setupMessage = "System Audio Bridge installation failed: \(error.localizedDescription)"
        }
    }

    func installEverything() async {
        setupInProgress = true
        setupMessage = "Setting up CamiTune dependencies…"
        await installCamillaDSP()
        if case .installed = audioDriverStatus {} else { await installAudioDriver() }
        setupInProgress = false
        refresh()
        if case .installed = camillaDSPStatus, case .installed = audioDriverStatus {
            setupFailed = false
            setupMessage = "Setup complete. CamillaDSP and System Audio Bridge are ready."
        } else {
            setupFailed = true
        }
    }

    func validateConfiguration(_ yaml: String) throws {
        guard FileManager.default.isExecutableFile(atPath: camillaDSPBinary.path) else {
            throw SetupError.binaryMissing
        }
        try createSupportLayout()
        let validationURL = supportDirectory.appendingPathComponent("configs/validation.yml")
        try yaml.write(to: validationURL, atomically: true, encoding: .utf8)
        _ = try run(camillaDSPBinary.path, ["--check", validationURL.path])
    }

    private func waitForAudioDriver() async -> Bool {
        for attempt in 0..<30 {
            coreAudio.refresh()
            if coreAudio.isSystemAudioBridgePresentationSupported { return true }
            if attempt < 29 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return false
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw SetupError.commandFailed(output) }
        return output
    }

    private func version(of binary: URL) -> String? {
        (try? run(binary.path, ["--version"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    enum SetupError: LocalizedError {
        case binaryMissing
        case bundledCamillaDSPMissing
        case bundledDriverMissing
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "The UID-capable CamillaDSP executable is not installed."
            case .bundledCamillaDSPMissing:
                return "This CamiTune build does not contain the required UID-capable CamillaDSP executable. Rebuild CamiTune with build-app.sh."
            case .bundledDriverMissing: return "This app bundle does not contain CamillaAudio.driver. Reinstall CamiTune."
            case .commandFailed(let output): return output.isEmpty ? "Installer command failed." : output
            }
        }
    }
}
