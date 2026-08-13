import Foundation
import Darwin

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
    @Published var blackHoleStatus: Status = .checking
    @Published var setupMessage: String = ""
    @Published var setupInProgress = false
    @Published var setupFailed = false

    private let coreAudio: CoreAudioManager

    init(coreAudio: CoreAudioManager) {
        self.coreAudio = coreAudio
        refresh()
    }

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamillaEQApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var camillaDSPBinary: URL { supportDirectory.appendingPathComponent("bin/camilladsp") }

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
        if FileManager.default.isExecutableFile(atPath: camillaDSPBinary.path) {
            camillaDSPStatus = .installed(version(of: camillaDSPBinary))
        } else {
            camillaDSPStatus = .missing
        }
        coreAudio.refresh()
        blackHoleStatus = coreAudio.blackHole == nil ? .missing : .installed(nil)
        if case .installed = camillaDSPStatus, case .installed = blackHoleStatus, setupMessage.isEmpty {
            setupMessage = "Dependencies are ready. Add an output profile, then enable System-wide EQ to start audio routing."
        }
    }

    func installCamillaDSP() async {
        setupFailed = false
        setupInProgress = true
        setupMessage = "Installing CamillaDSP: preparing download…"
        defer { setupInProgress = false }
        camillaDSPStatus = .working("Downloading official CamillaDSP release…")
        do {
            try createSupportLayout()
            let arch = ProcessInfo.processInfo.machineHardwareName
            let desired = arch == "arm64" ? "camilladsp-macos-aarch64.tar.gz" : "camilladsp-macos-amd64.tar.gz"
            guard arch == "arm64" || arch == "x86_64" else {
                throw SetupError.unsupportedArchitecture(arch)
            }

            // The filenames are part of CamillaDSP's documented macOS release
            // interface. Using GitHub's stable latest/download redirect avoids the
            // unauthenticated API rate limit, which made first-run installs fail.
            let assetURL = URL(string: "https://github.com/HEnquist/camilladsp/releases/latest/download/\(desired)")!
            let archive = try await download(assetURL, filename: desired)
            defer { try? FileManager.default.removeItem(at: archive) }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CamillaEQApp-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            try run("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path])
            guard let binary = findFile(named: "camilladsp", under: temp) else { throw SetupError.binaryMissing }
            let binDir = camillaDSPBinary.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: camillaDSPBinary)
            try FileManager.default.copyItem(at: binary, to: camillaDSPBinary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: camillaDSPBinary.path)
            _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", camillaDSPBinary.path])
            setupMessage = "CamillaDSP is installed and verified. Add an output profile, then enable System-wide EQ to create and start the active configuration."
            refresh()
        } catch {
            setupFailed = true
            camillaDSPStatus = .failed(error.localizedDescription)
            setupMessage = "CamillaDSP installation failed: \(error.localizedDescription)"
        }
    }

    func installBlackHole() async {
        setupFailed = false
        setupInProgress = true
        setupMessage = "Installing BlackHole 2ch: retrieving current package information…"
        defer { setupInProgress = false }
        blackHoleStatus = .working("Downloading official BlackHole 2ch installer…")
        do {
            // BlackHole's GitHub release assets are source archives, not the 2ch
            // installer. Homebrew's cask metadata points at the publisher-hosted,
            // current signed package and is also what `brew install blackhole-2ch`
            // uses.
            let cask = try await blackHoleCask()
            guard cask.url.pathExtension.lowercased() == "pkg" else {
                throw SetupError.invalidInstallerURL(cask.url.absoluteString)
            }
            let pkg = try await download(cask.url, filename: cask.url.lastPathComponent)
            defer { try? FileManager.default.removeItem(at: pkg) }
            _ = try run("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
            blackHoleStatus = .working("macOS administrator approval is required…")

            let command = "/usr/sbin/installer -pkg \(shellQuote(pkg.path)) -target /"
            let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            try run("/usr/bin/osascript", ["-e", script])

            // CoreAudio may need a moment (or in some setups a logout/restart) to expose the new driver.
            try? await Task.sleep(for: .seconds(2))
            coreAudio.refresh()
            if coreAudio.blackHole != nil {
                blackHoleStatus = .installed(nil)
                setupMessage = "Dependencies are ready. Add an output profile, then enable System-wide EQ to start audio routing."
            } else {
                setupMessage = "BlackHole was installed, but macOS must be restarted before audio routing can be activated."
                blackHoleStatus = .failed("BlackHole installed, but CoreAudio has not exposed it yet. Restart the Mac, then reopen CamillaEQApp.")
            }
        } catch {
            setupFailed = true
            blackHoleStatus = .failed(error.localizedDescription)
            setupMessage = "BlackHole installation failed: \(error.localizedDescription)"
        }
    }

    func installEverything() async {
        setupInProgress = true
        setupMessage = "Setting up CamillaEQApp dependencies…"
        if case .installed = camillaDSPStatus {} else { await installCamillaDSP() }
        if case .installed = blackHoleStatus {} else { await installBlackHole() }
        setupInProgress = false
        refresh()
        if case .installed = camillaDSPStatus, case .installed = blackHoleStatus {
            setupFailed = false
            setupMessage = "Setup complete. Both CamillaDSP and BlackHole 2ch are ready."
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

    private func blackHoleCask() async throws -> BlackHoleCask {
        let url = URL(string: "https://formulae.brew.sh/api/cask/blackhole-2ch.json")!
        var request = URLRequest(url: url)
        request.setValue("CamillaEQApp", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, source: url)
        return try JSONDecoder().decode(BlackHoleCask.self, from: data)
    }

    private func download(_ url: URL, filename: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("CamillaEQApp", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try validate(response: response, source: url)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private func validate(response: URLResponse, source: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SetupError.invalidResponse(source.host ?? source.absoluteString)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SetupError.httpFailure(http.statusCode, source.host ?? source.absoluteString)
        }
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

    private func findFile(named name: String, under root: URL) -> URL? {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = e?.nextObject() as? URL {
            if item.lastPathComponent == name { return item }
        }
        return nil
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private struct BlackHoleCask: Decodable { let url: URL }

    enum SetupError: LocalizedError {
        case binaryMissing
        case unsupportedArchitecture(String)
        case invalidInstallerURL(String)
        case invalidResponse(String)
        case httpFailure(Int, String)
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "CamillaDSP archive did not contain the camilladsp executable."
            case .unsupportedArchitecture(let arch): return "This Mac architecture is not supported: \(arch)."
            case .invalidInstallerURL(let url): return "The BlackHole download metadata did not provide a .pkg installer: \(url)"
            case .invalidResponse(let host): return "The download server returned an invalid response (\(host))."
            case .httpFailure(let status, let host): return "The download failed with HTTP \(status) from \(host). Check the internet connection and try again."
            case .commandFailed(let output): return output.isEmpty ? "Installer command failed." : output
            }
        }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return machine.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
