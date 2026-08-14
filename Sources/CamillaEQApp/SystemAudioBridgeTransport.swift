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
    }

    @Published private(set) var status = "Driver transport idle"
    @Published private(set) var statistics = Statistics()

    private let state = NSCondition()
    private var transport: SABRClientTransportRef?
    private var deviceObjectID: AudioObjectID?
    private var worker: Thread?
    private var stopping = false
    private var workerFinished = true
    private weak var spectrum: SpectrumAnalyzer?
    private var expectedChannelCount: UInt32 = 2

    deinit { stop() }

    @MainActor
    func start(
        deviceObjectID: AudioObjectID,
        expectedChannelCount: UInt32,
        audioSink: FileHandle,
        spectrum: SpectrumAnalyzer
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

        spectrum.startExternal(audioSink: audioSink, sourceName: "System Audio Bridge")
        state.lock()
        self.transport = transport
        self.deviceObjectID = deviceObjectID
        self.spectrum = spectrum
        self.expectedChannelCount = expectedChannelCount
        stopping = false
        workerFinished = false
        state.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "System Audio Bridge Transport"
        thread.qualityOfService = .userInteractive
        worker = thread
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
        self.spectrum = nil
        worker = nil
        state.unlock()

        if let transport, let deviceObjectID {
            sabr_client_transport_disconnect(transport, deviceObjectID)
        }
        if let transport { sabr_client_transport_destroy(transport) }
        Task { @MainActor [weak self] in
            self?.status = "Driver transport idle"
            self?.statistics = Statistics()
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

        while !shouldStop() {
            guard let transport = currentTransport() else { break }
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
            } else if channels == expectedChannelCount {
                let sampleCount = Int(frames * channels)
                let reportedChannels = channels
                spectrum?.ingestExternal(
                    interleaved: Array(samples.prefix(sampleCount)),
                    channelCount: Int(channels),
                    sampleRate: sampleRate
                )
                if !reportedStreaming {
                    reportedStreaming = true
                    reportedMismatch = nil
                    Task { @MainActor [weak self] in
                        self?.status = "Streaming \(reportedChannels) channels from System Audio Bridge"
                    }
                }
            } else {
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
        let value = Statistics(
            bufferedFrames: raw.writeFrame >= raw.readFrame ? raw.writeFrame - raw.readFrame : 0,
            droppedFrames: raw.droppedFrames,
            underrunCount: raw.underrunCount,
            activeChannels: raw.activeChannels,
            sampleRate: raw.sampleRate
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

    enum TransportError: LocalizedError {
        case invalidChannelCount(UInt32)
        case couldNotCreateSharedRegion
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidChannelCount(let count):
                return "The driver transport does not support \(count) channels."
            case .couldNotCreateSharedRegion:
                return "CamillaEQApp could not create the private driver audio transport."
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
