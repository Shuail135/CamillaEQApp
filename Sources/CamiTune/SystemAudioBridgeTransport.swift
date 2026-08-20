import Foundation
import CoreAudio
import SystemAudioBridgeC

final class SystemAudioBridgeTransport: ObservableObject, @unchecked Sendable {
    struct Statistics: Sendable {
        var bufferedFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var underrunCount: UInt64 = 0
        var activeChannels: UInt32 = 0
        var sampleRate: Double = 0
        var ringCapacityFrames: UInt32 = 0
        var rateAdjustmentPPM: Double = 0
        var rateMatchBufferedFrames: UInt64 = 0
    }

    @Published private(set) var status = "Driver transport idle"
    @Published private(set) var statistics = Statistics()
    @Published private(set) var runtimeError: String?

    private let state = NSCondition()
    private var transport: SABRClientTransportRef?
    private var deviceObjectID: AudioObjectID?
    private var worker: Thread?
    private var stopping = false
    private var workerFinished = true
    private var pcmRouter: PCMRouter?
    private var expectedChannelCount: UInt32 = 2
    private var expectedSampleRate = 48_000.0

    deinit { stop() }

    @MainActor
    func start(
        deviceObjectID: AudioObjectID,
        expectedChannelCount: UInt32,
        expectedSampleRate: Double,
        pcmRouter: PCMRouter
    ) throws {
        stop()
        guard expectedChannelCount > 0,
              expectedChannelCount <= sabr_client_transport_max_channels() else {
            throw TransportError.invalidChannelCount(expectedChannelCount)
        }
        guard let transport = sabr_client_transport_create(
            sabr_client_transport_max_channels(),
            sabr_client_transport_default_frame_capacity()
        ) else {
            throw TransportError.couldNotCreateSharedRegion
        }

        let result = sabr_client_transport_connect(transport, deviceObjectID)
        guard result == noErr else {
            sabr_client_transport_destroy(transport)
            throw TransportError.coreAudio(result)
        }

        state.lock()
        self.transport = transport
        self.deviceObjectID = deviceObjectID
        self.pcmRouter = pcmRouter
        self.expectedChannelCount = expectedChannelCount
        self.expectedSampleRate = expectedSampleRate
        stopping = false
        workerFinished = false
        state.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "System Audio Bridge Transport"
        thread.qualityOfService = .userInteractive
        worker = thread
        runtimeError = nil
        status = "Waiting for System Audio Bridge frames…"
        thread.start()
    }

    func stop() {
        state.lock()
        stopping = true
        // The worker only polls the shared ring and never performs blocking I/O.
        // Wait for it to release the mapped region before destroying that
        // region; a timeout here could otherwise turn a slow shutdown into a
        // use-after-unmap crash.
        while !workerFinished { state.wait() }
        let transport = self.transport
        let deviceObjectID = self.deviceObjectID
        self.transport = nil
        self.deviceObjectID = nil
        self.pcmRouter = nil
        worker = nil
        state.unlock()

        if let transport, let deviceObjectID {
            sabr_client_transport_disconnect(transport, deviceObjectID)
        }
        if let transport { sabr_client_transport_destroy(transport) }
        Task { @MainActor [weak self] in
            self?.status = "Driver transport idle"
            self?.statistics = Statistics()
            self?.runtimeError = nil
        }
    }

    private func run() {
        let maximumFrames: UInt32 = 2048
        let channelCapacity = sabr_client_transport_max_channels()
        var samples = [Float](
            repeating: 0,
            count: Int(maximumFrames * channelCapacity)
        )
        var lastStatisticsUpdate = Date()
        var reportedStreaming = false
        var reportedMismatch: UInt32?
        var reportedSampleRateMismatch: Double?

        while !shouldStop() {
            guard let transport = currentTransport() else { break }
            var occupancy = SABRClientTransportStatistics()
            sabr_client_transport_get_statistics(transport, &occupancy)
            let availableFrames = occupancy.writeFrame >= occupancy.readFrame
                ? occupancy.writeFrame - occupancy.readFrame
                : 0
            let sourceBufferedFrames = Int(min(
                availableFrames,
                UInt64(occupancy.frameCapacity)
            ))
            var channels: UInt32 = 0
            var sampleRate = 0.0
            let frames = samples.withUnsafeMutableBufferPointer { buffer in
                sabr_client_transport_read(
                    transport,
                    buffer.baseAddress,
                    channelCapacity,
                    maximumFrames,
                    &channels,
                    &sampleRate
                )
            }
            if frames == 0 {
                usleep(1_000)
            } else if channels == expectedChannelCount,
                      abs(sampleRate - expectedSampleRate) < 0.5 {
                let sampleCount = Int(frames * channels)
                let reportedChannels = channels
                let interleaved = Array(samples.prefix(sampleCount))
                currentPCMRouter()?.route(PCMFrame(
                    interleaved: interleaved,
                    channelCount: Int(channels),
                    sampleRate: sampleRate,
                    sourceBufferedFrames: sourceBufferedFrames,
                    sourceCapacityFrames: Int(occupancy.frameCapacity)
                ))
                if !reportedStreaming {
                    reportedStreaming = true
                    reportedMismatch = nil
                    reportedSampleRateMismatch = nil
                    Task { @MainActor [weak self] in
                        self?.status = "Streaming \(reportedChannels) channels from System Audio Bridge"
                    }
                }
            } else if channels != expectedChannelCount {
                let reportedChannels = channels
                let expectedChannels = expectedChannelCount
                if reportedMismatch != reportedChannels {
                    reportedStreaming = false
                    reportedMismatch = reportedChannels
                    Task { @MainActor [weak self] in
                        self?.status = "Driver channel mismatch: received \(reportedChannels), expected \(expectedChannels)"
                    }
                }
                usleep(1_000)
            } else {
                let actualRate = sampleRate
                let requestedRate = expectedSampleRate
                if reportedSampleRateMismatch != actualRate {
                    reportedStreaming = false
                    reportedSampleRateMismatch = actualRate
                    let message = "System Audio Bridge is producing \(Self.rateDescription(actualRate)), but CamillaDSP expects \(Self.rateDescription(requestedRate)). Audio was stopped to prevent wrong-speed playback. Choose a rate supported by the physical output."
                    Task { @MainActor [weak self] in
                        self?.status = "Sample-rate mismatch"
                        self?.runtimeError = message
                    }
                }
                usleep(1_000)
            }

            if Date().timeIntervalSince(lastStatisticsUpdate) >= 0.5 {
                publishStatistics(transport)
                lastStatisticsUpdate = Date()
            }
        }

        state.lock()
        workerFinished = true
        state.broadcast()
        state.unlock()
    }

    private func publishStatistics(_ transport: SABRClientTransportRef) {
        var raw = SABRClientTransportStatistics()
        sabr_client_transport_get_statistics(transport, &raw)
        let rateMatching = currentPCMRouter()?.statistics
        let value = Statistics(
            bufferedFrames: raw.writeFrame >= raw.readFrame ? raw.writeFrame - raw.readFrame : 0,
            droppedFrames: raw.droppedFrames,
            underrunCount: raw.underrunCount,
            activeChannels: raw.activeChannels,
            sampleRate: raw.sampleRate,
            ringCapacityFrames: raw.frameCapacity,
            rateAdjustmentPPM: rateMatching?.rateAdjustmentPPM ?? 0,
            rateMatchBufferedFrames: rateMatching?.rateMatchBufferedFrames ?? 0
        )
        Task { @MainActor [weak self] in self?.statistics = value }
    }

    private func shouldStop() -> Bool {
        state.lock()
        defer { state.unlock() }
        return stopping
    }

    private func currentTransport() -> SABRClientTransportRef? {
        state.lock()
        defer { state.unlock() }
        return transport
    }

    private func currentPCMRouter() -> PCMRouter? {
        state.lock()
        defer { state.unlock() }
        return pcmRouter
    }

    private static func rateDescription(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1_000)
    }

    enum TransportError: LocalizedError {
        case invalidChannelCount(UInt32)
        case couldNotCreateSharedRegion
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidChannelCount(let count):
                return "The driver transport does not support \(count) channels."
            case .couldNotCreateSharedRegion:
                return "CamiTune could not create the private driver audio transport."
            case .coreAudio(let status):
                if status == kAudioHardwareUnknownPropertyError {
                    return "The installed System Audio Bridge does not support this app's transport protocol (Core Audio \(Self.describe(status))). Use Setup → Install / Repair Everything to replace the driver."
                }
                return "System Audio Bridge rejected the transport connection (Core Audio \(Self.describe(status)))."
            }
        }

        private static func describe(_ status: OSStatus) -> String {
            let value = UInt32(bitPattern: status)
            let bytes = [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ]
            let printable = bytes.allSatisfy { (32...126).contains($0) }
            let fourCC = printable ? ", '\(String(bytes: bytes, encoding: .ascii)!)'" : ""
            return "\(status), 0x\(String(value, radix: 16, uppercase: true))\(fourCC)"
        }
    }
}
