import Foundation
import Accelerate

final class SpectrumAnalyzer: ObservableObject, @unchecked Sendable {
    @Published var points: [SpectrumPoint] = []
    @Published var status: String = "Analyzer idle"

    private var pipeWriter: AudioPipeWriter?
    private var fftSetup: FFTSetup?
    private let fftSize = 4096
    private let fftHopSize = 2048
    private let log2n: vDSP_Length = 12
    private var lastPublish = Date.distantPast
    private var smoothedDB: [Double] = []
    private let displayBinCount = 180
    private let sampleLock = NSLock()
    private var pendingSamples: [Float] = []
    private var receivedBuffer = false
    private var sourceName = "System Audio Bridge"

    deinit {
        pipeWriter?.stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    @MainActor
    func startExternal(audioSink: FileHandle, sourceName: String) {
        stop()
        self.sourceName = sourceName
        let writer = AudioPipeWriter(handle: audioSink)
        writer.start()
        pipeWriter = writer
        if fftSetup == nil { fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) }
        resetReceivedBuffer()
        status = "Waiting for audio from \(sourceName)…"
    }

    func ingestExternal(interleaved: [Float], channelCount: Int, sampleRate: Double) {
        guard channelCount > 0,
              sampleRate > 0,
              interleaved.count >= channelCount else { return }
        let frameCount = interleaved.count / channelCount
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[frame * channelCount + channel]
            }
            mono[frame] = sum / Float(channelCount)
        }
        accept(mono: mono, interleaved: interleaved, sampleRate: sampleRate)
    }

    @MainActor
    func stop() {
        pipeWriter?.stop()
        pipeWriter = nil
        points = []
        sampleLock.lock()
        pendingSamples.removeAll(keepingCapacity: true)
        smoothedDB.removeAll(keepingCapacity: true)
        receivedBuffer = false
        sampleLock.unlock()
        status = "Analyzer idle"
    }

    private func accept(mono: [Float], interleaved: [Float], sampleRate: Double) {
        if markFirstBufferReceived() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = "Live FFT from \(self.sourceName)"
            }
        }
        interleaved.withUnsafeBytes { bytes in pipeWriter?.enqueue(Data(bytes)) }

        sampleLock.lock()
        pendingSamples.append(contentsOf: mono)
        guard pendingSamples.count >= fftSize else {
            sampleLock.unlock()
            return
        }
        let samples = Array(pendingSamples.prefix(fftSize))
        // Keep half the window for the next analysis frame. The 50% overlap
        // provides about 23 spectrum frames per second at 48 kHz, making
        // musical changes visible without sacrificing frequency resolution.
        pendingSamples.removeFirst(fftHopSize)
        sampleLock.unlock()
        process(samples: samples, sampleRate: sampleRate)
    }

    private func process(samples input: [Float], sampleRate: Double) {
        // Update often enough for continuous motion, while using a slower
        // envelope below so the graph remains useful as an EQ tuning guide.
        // Audio continues to CamillaDSP at full rate.
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 0.05 else { return }
        lastPublish = now

        var samples = input
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        guard let setup = fftSetup else { return }
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBytes { raw in
                    let complex = raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                var mags = [Float](repeating: 0, count: half)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                let scale = 1.0 / Float(fftSize * fftSize)
                let minimumFrequency = 20.0
                let maximumFrequency = min(20_000.0, sampleRate / 2)
                let frequencyPerBin = sampleRate / Double(fftSize)
                var current = [Double](repeating: -120, count: displayBinCount)

                // Collapse the linear FFT into evenly spaced logarithmic bins.
                // Taking the strongest component in each band keeps musical
                // fundamentals visible without drawing thousands of flickering
                // one-pixel spikes.
                for displayIndex in 0..<displayBinCount {
                    let lowerT = Double(displayIndex) / Double(displayBinCount)
                    let upperT = Double(displayIndex + 1) / Double(displayBinCount)
                    let lowerFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, lowerT)
                    let upperFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, upperT)
                    let lowerBin = max(1, Int(floor(lowerFrequency / frequencyPerBin)))
                    let upperBin = min(half - 1, max(lowerBin, Int(ceil(upperFrequency / frequencyPerBin))))
                    guard lowerBin <= upperBin else { continue }
                    var strongest: Float = 0
                    for fftIndex in lowerBin...upperBin { strongest = max(strongest, mags[fftIndex]) }
                    current[displayIndex] = max(-120, 10 * log10(Double(max(strongest * scale, 1e-12))))
                }

                // Five-point frequency-domain averaging removes narrow-bin
                // sparkle while preserving broad tonal shapes used for EQ.
                if current.count > 4 {
                    var spatial = current
                    for index in 2..<(current.count - 2) {
                        spatial[index] = current[index - 2] * 0.08
                            + current[index - 1] * 0.22
                            + current[index] * 0.40
                            + current[index + 1] * 0.22
                            + current[index + 2] * 0.08
                    }
                    current = spatial
                }

                if smoothedDB.count != current.count {
                    smoothedDB = current
                } else {
                    for index in current.indices {
                        let rising = current[index] > smoothedDB[index]
                        let difference = abs(current[index] - smoothedDB[index])
                        // React strongly to meaningful musical changes while
                        // retaining gentler motion for tiny bin fluctuations.
                        let amount: Double
                        if rising {
                            amount = difference > 8 ? 0.42 : (difference > 3 ? 0.30 : 0.18)
                        } else {
                            amount = difference > 8 ? 0.18 : (difference > 3 ? 0.12 : 0.07)
                        }
                        smoothedDB[index] += (current[index] - smoothedDB[index]) * amount
                    }
                }

                let mapped = smoothedDB.enumerated().map { index, db in
                    let t = (Double(index) + 0.5) / Double(displayBinCount)
                    let frequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, t)
                    return SpectrumPoint(frequency: frequency, db: db)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.points = mapped
                }
            }
        }
    }

    private func markFirstBufferReceived() -> Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        guard !receivedBuffer else { return false }
        receivedBuffer = true
        return true
    }

    private func resetReceivedBuffer() {
        sampleLock.lock()
        receivedBuffer = false
        sampleLock.unlock()
    }

}

private final class AudioPipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var buffers: [Data] = []
    private var queuedBytes = 0
    private var stopping = false
    private var worker: Thread?
    private let maximumQueuedBytes = 4 * 1024 * 1024

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "CamillaEQApp CamillaDSP PCM Writer"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()
    }

    func enqueue(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else { return }
        // Four MiB is over ten seconds at 48 kHz stereo float. Reaching this
        // means the DSP pipe has stopped; bound memory rather than destabilize
        // the app. Normal operation keeps this queue near one buffer.
        guard queuedBytes + data.count <= maximumQueuedBytes else { return }
        buffers.append(data)
        queuedBytes += data.count
        condition.signal()
    }

    func stop() {
        condition.lock()
        stopping = true
        buffers.removeAll()
        queuedBytes = 0
        condition.broadcast()
        condition.unlock()
        worker?.cancel()
        worker = nil
    }

    private func run() {
        while !Thread.current.isCancelled {
            condition.lock()
            while buffers.isEmpty && !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                return
            }
            let data = buffers.removeFirst()
            queuedBytes -= data.count
            condition.unlock()
            do {
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}
