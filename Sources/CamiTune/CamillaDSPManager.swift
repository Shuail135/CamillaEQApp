import Foundation
import Darwin

@MainActor
final class CamillaDSPManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    // Keep the app's private engine separate from the conventional CamillaGUI
    // port (1234), which may already be occupied by a manual/legacy setup.
    private let controlPort: UInt16
    let rpc: CamillaRPC
    private var process: Process?
    private var inputPipe: Pipe?
    private var hasAppliedConfig = false

    init() {
        let port = UInt16.random(in: 20_000...49_999)
        controlPort = port
        rpc = CamillaRPC(port: port)
    }

    func start(binary: URL) async throws {
        if let process, process.isRunning {
            if !isRunning { try await connectWithRetry() }
            return
        }

        terminateStalePrivateEngines(binary: binary)

        let logDirectory = supportDirectory().appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("camilladsp.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let p = Process()
        p.executableURL = binary
        p.arguments = ["--address", "127.0.0.1", "--port", String(controlPort), "--wait", "--gain=-20", "--logfile", logURL.path]
        p.standardOutput = handle
        p.standardError = handle
        let pipe = Pipe()
        p.standardInput = pipe
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isRunning = false
            }
        }
        try p.run()
        inputPipe = pipe
        process = p
        hasAppliedConfig = false
        try await connectWithRetry()
        isRunning = true
    }

    func audioInputHandle() throws -> FileHandle {
        guard let handle = inputPipe?.fileHandleForWriting else { throw CamillaError.inputUnavailable }
        return handle
    }

    /// Closing stdin first unblocks any PCM writer waiting on a full pipe. It
    /// is intentionally separate from process teardown so the router can join
    /// its delivery worker without depending on CamillaDSP's control socket.
    func closeAudioInput() {
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
    }

    func apply(yaml: String) async throws {
        do {
            let configDirectory = supportDirectory().appendingPathComponent("configs", isDirectory: true)
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try yaml.write(
                to: configDirectory.appendingPathComponent("active.yml"),
                atomically: true,
                encoding: .utf8
            )
            try await rpc.setConfig(yaml: yaml)
            // Startup uses -20 dB as a safety guard. Once a valid graph is active,
            // its derived response-processing headroom replaces that guard.
            // Intentional User-preamp boost is monitored and optionally limited.
            if !hasAppliedConfig {
                try await rpc.setVolume(0)
                hasAppliedConfig = true
            }
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func apply(configuration: CamillaDSPConfiguration) async throws {
        try await apply(yaml: configuration.yaml)
    }

    func apply(patch: CamillaDSPRuntimePatch) async throws {
        do {
            try await rpc.patchConfig(patch)
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func forceStopAndWait() {
        guard let childProcess = process else {
            hasAppliedConfig = false
            isRunning = false
            return
        }

        closeAudioInput()
        if childProcess.isRunning {
            childProcess.terminate()
            // App termination cannot await an async task. Give only this app's
            // child process a short grace period, then guarantee it cannot be
            // orphaned and keep CoreAudio/control ports open after quit.
            for _ in 0..<10 where childProcess.isRunning {
                usleep(50_000)
            }
            if childProcess.isRunning {
                kill(childProcess.processIdentifier, SIGKILL)
            }
            childProcess.waitUntilExit()
        }
        self.process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    func stop() async {
        closeAudioInput()
        // Disconnecting first also aborts a stuck in-flight RPC. Waiting for an
        // "Exit" reply here could otherwise make profile switching hang forever.
        await rpc.disconnect()
        if let childProcess = process {
            if childProcess.isRunning {
                childProcess.terminate()
                for _ in 0..<8 where childProcess.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if childProcess.isRunning {
                    kill(childProcess.processIdentifier, SIGKILL)
                }
            }
            childProcess.waitUntilExit()
        }
        process = nil
        hasAppliedConfig = false
        isRunning = false
    }

    private func connectWithRetry() async throws {
        var finalError: Error?
        for _ in 0..<30 {
            do {
                try await rpc.connect()
                return
            } catch {
                finalError = error
                await rpc.disconnect()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        throw finalError ?? CamillaError.connectionTimeout
    }

    private func terminateStalePrivateEngines(binary: URL) {
        // Only match CamillaDSP instances launched from this app's private
        // Application Support binary. Do not touch Homebrew or user-managed
        // CamillaDSP installations.
        // Match all historical command-line variants of this exact private
        // executable. Older app builds used port 1234 and did not pass
        // --address, so restricting the argument pattern left orphan engines
        // competing for the routing stream indefinitely.
        let pattern = "^\(NSRegularExpression.escapedPattern(for: binary.path))( |$)"
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-TERM", "-f", pattern]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }

    private func supportDirectory() -> URL {
        let base = CamiTunePaths.supportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    enum CamillaError: LocalizedError {
        case connectionTimeout
        case inputUnavailable
        var errorDescription: String? {
            switch self {
            case .connectionTimeout: return "CamillaDSP did not open its local control socket."
            case .inputUnavailable: return "CamillaDSP's audio input pipe is unavailable."
            }
        }
    }
}
