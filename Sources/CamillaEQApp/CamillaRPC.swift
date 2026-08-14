import Foundation

actor CamillaRPC {
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let url: URL
    private var requestInProgress = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(port: UInt16) {
        self.url = URL(string: "ws://127.0.0.1:\(port)")!
    }

    func connect() async throws {
        if task != nil { return }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        task = socket
        do {
            _ = try await request("GetVersion")
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            task = nil
            throw error
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func request(_ payload: Any) async throws -> [String: Any] {
        // Actor isolation alone is not enough here: actors are reentrant at
        // every await. Keep each WebSocket send/receive pair together so a
        // meter poll cannot consume the response to a state or config command.
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        try Task.checkCancellation()
        guard let task else { throw RPCError.notConnected }
        // CamillaDSP uses both JSON objects (for commands with values) and
        // top-level JSON strings (for commands such as "GetVersion"). Without
        // fragmentsAllowed Foundation raises an Objective-C exception for the
        // latter, terminating the entire app instead of throwing a Swift error.
        guard JSONSerialization.isValidJSONObject(payload) || payload is String else {
            throw RPCError.invalidRequest
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
        let message = try await task.receive()
        let responseData: Data
        switch message {
        case .string(let value): responseData = Data(value.utf8)
        case .data(let value): responseData = value
        @unknown default: throw RPCError.invalidResponse("unsupported WebSocket message type")
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RPCError.invalidResponse("the reply was not a JSON command object")
        }
        return object
    }

    private func acquireRequestSlot() async {
        if !requestInProgress {
            requestInProgress = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestInProgress = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    func setConfig(yaml: String) async throws {
        let result = try await request(["SetConfig": yaml])
        try ensureOK(result, command: "SetConfig")
    }

    func setVolume(_ db: Double) async throws {
        let result = try await request(["SetVolume": db])
        try ensureOK(result, command: "SetVolume")
    }

    func exit() async {
        _ = try? await request("Exit")
        disconnect()
    }

    func signalLevels() async throws -> SignalLevels {
        let response = try await request("GetSignalLevels")
        let command = try successfulBody(response, command: "GetSignalLevels")
        guard let value = command["value"] as? [String: Any] else {
            throw RPCError.invalidResponse("GetSignalLevels had no level data")
        }
        func doubles(_ any: Any?) -> [Double] {
            if let values = any as? [Double] { return values }
            if let values = any as? [NSNumber] { return values.map(\.doubleValue) }
            return []
        }
        return SignalLevels(
            capturePeak: doubles(value["capture_peak"]),
            captureRMS: doubles(value["capture_rms"]),
            playbackPeak: doubles(value["playback_peak"]),
            playbackRMS: doubles(value["playback_rms"])
        )
    }

    func state() async throws -> String {
        let response = try await request("GetState")
        let command = try successfulBody(response, command: "GetState")
        guard let value = command["value"] as? String else {
            throw RPCError.invalidResponse("GetState had no state value")
        }
        return value
    }

    private func ensureOK(_ response: [String: Any], command: String) throws {
        _ = try successfulBody(response, command: command)
    }

    private func successfulBody(
        _ response: [String: Any],
        command: String
    ) throws -> [String: Any] {
        guard let body = response[command] as? [String: Any] else {
            throw RPCError.invalidResponse("expected a \(command) reply")
        }
        if String(describing: body["result"] ?? "") != "Ok" {
            throw RPCError.commandFailed(String(describing: body["result"] ?? command))
        }
        return body
    }

    enum RPCError: LocalizedError {
        case notConnected
        case invalidRequest
        case invalidResponse(String)
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "CamillaDSP websocket is not connected."
            case .invalidRequest: return "CamillaEQApp attempted to send an invalid command to CamillaDSP."
            case .invalidResponse(let detail): return "CamillaDSP returned an invalid response: \(detail)."
            case .commandFailed(let value): return "CamillaDSP command failed: \(value)"
            }
        }
    }
}

struct SignalLevels {
    var capturePeak: [Double]
    var captureRMS: [Double]
    var playbackPeak: [Double]
    var playbackRMS: [Double]
}

@MainActor
final class MeterModel: ObservableObject {
    @Published var capturePeak: [Double] = [-150, -150]
    @Published var captureRMS: [Double] = [-150, -150]
    @Published var playbackPeak: [Double] = [-150, -150]
    @Published var playbackRMS: [Double] = [-150, -150]

    private var pollingTask: Task<Void, Never>?
    private var hasReceivedLevels = false

    func start(rpc: CamillaRPC) {
        stop()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let levels = try await rpc.signalLevels()
                    guard let self else { return }
                    if self.hasReceivedLevels {
                        self.capturePeak = self.smooth(current: self.capturePeak, target: levels.capturePeak, attack: 0.72, release: 0.16)
                        self.captureRMS = self.smooth(current: self.captureRMS, target: levels.captureRMS, attack: 0.42, release: 0.20)
                        self.playbackPeak = self.smooth(current: self.playbackPeak, target: levels.playbackPeak, attack: 0.72, release: 0.16)
                        self.playbackRMS = self.smooth(current: self.playbackRMS, target: levels.playbackRMS, attack: 0.42, release: 0.20)
                    } else {
                        self.capturePeak = levels.capturePeak
                        self.captureRMS = levels.captureRMS
                        self.playbackPeak = levels.playbackPeak
                        self.playbackRMS = levels.playbackRMS
                        self.hasReceivedLevels = true
                    }
                } catch {
                    // A transient websocket miss should not tear down the audio engine.
                }
                // Ten polls per second is visually smooth and leaves ample
                // control-socket capacity for live configuration updates.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        hasReceivedLevels = false
        capturePeak = [-150, -150]
        captureRMS = [-150, -150]
        playbackPeak = [-150, -150]
        playbackRMS = [-150, -150]
    }

    private func smooth(
        current: [Double],
        target: [Double],
        attack: Double,
        release: Double
    ) -> [Double] {
        let channelCount = max(current.count, target.count)
        return (0..<channelCount).map { channel in
            let previous = channel < current.count ? current[channel] : -150
            let next = channel < target.count ? target[channel] : -150
            let amount = next > previous ? attack : release
            return previous + (next - previous) * amount
        }
    }
}
