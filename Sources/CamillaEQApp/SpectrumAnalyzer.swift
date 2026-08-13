import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

final class SpectrumAnalyzer: ObservableObject, @unchecked Sendable {
    @Published var points: [SpectrumPoint] = []
    @Published var status: String = "Analyzer idle"

    private var captureDeviceID: AudioDeviceID?
    private var captureIOProcID: AudioDeviceIOProcID?
    private var directSampleRate: Double = 0
    private var captureUnit: AudioUnit?
    private var captureFormat: AVAudioFormat?
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
    private var startupCheck: Task<Void, Never>?
    private var receivedBuffer = false
    private var inputCompensation: Float = 1

    deinit {
        stopCaptureBackends()
        pipeWriter?.stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    @MainActor
    func waitUntilReceiving(timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if hasReceivedBuffer() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return hasReceivedBuffer()
    }

    @MainActor
    private func requestAudioInputPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    @MainActor
    func start(deviceObjectID: UInt32, audioSink: FileHandle) async throws {
        stop()
        status = "Requesting Audio Input permission for the live spectrum…"
        guard await requestAudioInputPermission() else {
            status = "Audio Input permission denied. Enable CamillaEQApp in System Settings › Privacy & Security › Microphone, then reactivate EQ."
            throw AnalyzerError.permissionDenied
        }
        status = "Attaching analyzer to BlackHole 2ch…"
        do {
            let writer = AudioPipeWriter(handle: audioSink)
            writer.start()
            pipeWriter = writer
            if fftSetup == nil { fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) }
            resetReceivedBuffer()

            do {
                try startDirectCapture(deviceObjectID: deviceObjectID)
                status = "Direct BlackHole analyzer started at \(Int(directSampleRate)) Hz; waiting for audio buffers…"
                scheduleCaptureCheck(deviceObjectID: deviceObjectID, retryAUHAL: true)
            } catch {
                try startAUHALCapture(deviceObjectID: deviceObjectID)
                status = "AUHAL BlackHole analyzer started at \(Int(captureFormat?.sampleRate ?? 0)) Hz; waiting for audio buffers…"
                scheduleCaptureCheck(deviceObjectID: deviceObjectID, retryAUHAL: false)
            }
        } catch {
            stopCaptureBackends()
            pipeWriter?.stop()
            pipeWriter = nil
            status = "Spectrum analyzer unavailable: \(error.localizedDescription)"
            throw error
        }
    }

    private func startDirectCapture(deviceObjectID: UInt32) throws {
        let deviceID = AudioDeviceID(deviceObjectID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format), "reading BlackHole device format")
        guard format.mSampleRate > 0,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AnalyzerError.invalidFormat
        }

        var ioProcID: AudioDeviceIOProcID?
        let callback: AudioDeviceIOProc = { _, _, inputData, _, _, _, reference in
            guard let reference else { return noErr }
            return Unmanaged<SpectrumAnalyzer>.fromOpaque(reference)
                .takeUnretainedValue()
                .captureDirect(inputData)
        }
        let reference = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioDeviceCreateIOProcID(deviceID, callback, reference, &ioProcID), "creating direct BlackHole callback")
        guard let ioProcID else { throw AnalyzerError.coreAudio("creating direct BlackHole callback", -1) }
        captureDeviceID = deviceID
        captureIOProcID = ioProcID
        directSampleRate = format.mSampleRate
        do {
            try check(AudioDeviceStart(deviceID, ioProcID), "starting direct BlackHole callback")
        } catch {
            _ = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            captureDeviceID = nil
            captureIOProcID = nil
            directSampleRate = 0
            throw error
        }
    }

    private func startAUHALCapture(deviceObjectID: UInt32) throws {
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw AnalyzerError.coreAudio("finding AUHAL", -1) }
            var optionalUnit: AudioUnit?
            try check(AudioComponentInstanceNew(component, &optionalUnit), "creating AUHAL")
            guard let unit = optionalUnit else { throw AnalyzerError.coreAudio("creating AUHAL", -1) }
            captureUnit = unit

            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)), "enabling input")
            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, UInt32(MemoryLayout<UInt32>.size)), "disabling output")
            var deviceID = AudioDeviceID(deviceObjectID)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "selecting BlackHole")

            // Bus 1 input scope is the hardware-facing format. Bus 1 output
            // scope is the client-facing format supplied by AudioUnitRender.
            var hardwareFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &formatSize), "reading BlackHole hardware format")
            guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0 else { throw AnalyzerError.invalidFormat }
            var clientFormat = AudioStreamBasicDescription(mSampleRate: hardwareFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: min(2, hardwareFormat.mChannelsPerFrame), mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, formatSize), "setting analyzer client format")
            guard let format = AVAudioFormat(streamDescription: &clientFormat) else { throw AnalyzerError.invalidFormat }
            captureFormat = format

            var callback = AURenderCallbackStruct(inputProc: { reference, flags, timestamp, _, frameCount, _ in
                Unmanaged<SpectrumAnalyzer>.fromOpaque(reference).takeUnretainedValue().capture(flags: flags, timestamp: timestamp, frameCount: frameCount)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "installing input callback")
            try check(AudioUnitInitialize(unit), "initializing analyzer")
            try check(AudioOutputUnitStart(unit), "starting analyzer")
        } catch {
            stopCaptureUnit()
            throw error
        }
    }

    @MainActor
    private func scheduleCaptureCheck(deviceObjectID: UInt32, retryAUHAL: Bool) {
        startupCheck?.cancel()
        startupCheck = Task { [weak self] in
            try? await Task.sleep(for: retryAUHAL ? .milliseconds(1200) : .seconds(3))
            guard !Task.isCancelled, let self, !self.hasReceivedBuffer() else { return }
            if retryAUHAL {
                self.status = "Direct BlackHole capture did not deliver; retrying with AUHAL…"
                self.stopDirectCapture()
                do {
                    try self.startAUHALCapture(deviceObjectID: deviceObjectID)
                    self.status = "AUHAL fallback started at \(Int(self.captureFormat?.sampleRate ?? 0)) Hz; waiting for audio buffers…"
                } catch {
                    self.status = "Both BlackHole capture methods failed: \(error.localizedDescription)"
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, !self.hasReceivedBuffer() else { return }
            }
            self.status = "BlackHole is not delivering audio buffers. Restart macOS after installing BlackHole, then run Validate Setup."
        }
    }

    @MainActor
    func stop() {
        startupCheck?.cancel()
        startupCheck = nil
        stopCaptureBackends()
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

    func setInputCompensation(decibels: Double) {
        sampleLock.lock()
        inputCompensation = Float(min(1_000, max(1, pow(10, decibels / 20))))
        sampleLock.unlock()
    }

    private func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard let unit = captureUnit, let format = captureFormat, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return noErr }
        buffer.frameLength = frameCount
        let result = AudioUnitRender(unit, flags, timestamp, 1, frameCount, buffer.mutableAudioBufferList)
        if result == noErr { append(buffer: buffer) }
        return result
    }

    private func captureDirect(_ inputData: UnsafePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else { return noErr }

        let first = buffers[0]
        let firstChannels = max(1, Int(first.mNumberChannels))
        let firstSampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = firstSampleCount / firstChannels
        guard frameCount > 0, let firstData = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        var mono = [Float](repeating: 0, count: frameCount)
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        if buffers.count == 1, firstChannels >= 2 {
            for frame in 0..<frameCount {
                let left = firstData[frame * firstChannels]
                let right = firstData[frame * firstChannels + 1]
                mono[frame] = (left + right) * 0.5
                interleaved[frame * 2] = left
                interleaved[frame * 2 + 1] = right
            }
        } else {
            let rightData = buffers.count > 1
                ? buffers[1].mData?.assumingMemoryBound(to: Float.self)
                : nil
            for frame in 0..<frameCount {
                let left = firstData[frame * firstChannels]
                let right = rightData?[frame] ?? left
                mono[frame] = (left + right) * 0.5
                interleaved[frame * 2] = left
                interleaved[frame * 2 + 1] = right
            }
        }
        accept(mono: mono, interleaved: interleaved, sampleRate: directSampleRate)
        return noErr
    }

    private func stopCaptureBackends() {
        stopDirectCapture()
        stopCaptureUnit()
    }

    private func stopDirectCapture() {
        if let deviceID = captureDeviceID, let ioProcID = captureIOProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        captureDeviceID = nil
        captureIOProcID = nil
        directSampleRate = 0
    }

    private func stopCaptureUnit() {
        guard let unit = captureUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        captureUnit = nil
        captureFormat = nil
    }

    private func check(_ result: OSStatus, _ operation: String) throws {
        guard result == noErr else { throw AnalyzerError.coreAudio(operation, result) }
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var mono = [Float](repeating: 0, count: frameCount)
        let channelCount = max(1, min(Int(buffer.format.channelCount), 2))
        for channelIndex in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[channelIndex], 1, &mono, 1, vDSP_Length(frameCount))
        }
        var divisor = Float(channelCount)
        vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))

        // CamillaDSP's Stdin backend expects interleaved raw PCM. Feed it the
        // exact same frames used for the FFT so visualization and EQ cannot
        // diverge or compete for BlackHole.
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        let left = channels[0]
        let right = channels[channelCount > 1 ? 1 : 0]
        for frame in 0..<frameCount {
            interleaved[frame * 2] = left[frame]
            interleaved[frame * 2 + 1] = right[frame]
        }
        accept(mono: mono, interleaved: interleaved, sampleRate: buffer.format.sampleRate)
    }

    private func accept(mono: [Float], interleaved: [Float], sampleRate: Double) {
        if markFirstBufferReceived() {
            Task { @MainActor [weak self] in self?.status = "Live FFT from BlackHole" }
        }
        sampleLock.lock()
        let compensation = inputCompensation
        sampleLock.unlock()
        var compensatedMono = mono
        var compensatedInterleaved = interleaved
        if compensation != 1 {
            var factor = compensation
            vDSP_vsmul(compensatedMono, 1, &factor, &compensatedMono, 1, vDSP_Length(compensatedMono.count))
            vDSP_vsmul(compensatedInterleaved, 1, &factor, &compensatedInterleaved, 1, vDSP_Length(compensatedInterleaved.count))
        }
        compensatedInterleaved.withUnsafeBytes { bytes in pipeWriter?.enqueue(Data(bytes)) }

        sampleLock.lock()
        pendingSamples.append(contentsOf: compensatedMono)
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

    private func hasReceivedBuffer() -> Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return receivedBuffer
    }

    private enum AnalyzerError: LocalizedError {
        case permissionDenied
        case invalidFormat
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Audio Input permission is required to receive BlackHole audio."
            case .invalidFormat: return "BlackHole returned an invalid hardware format."
            case .coreAudio(let operation, let status): return "CoreAudio failed while \(operation) (\(status))."
            }
        }
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
