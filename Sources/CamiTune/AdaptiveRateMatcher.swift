import Foundation

struct AdaptiveRateController {
    static let maximumAdjustmentPPM = 500.0

    private(set) var adjustmentPPM = 0.0
    private var integralPPM = 0.0
    private var filteredBufferedFrames: Double?

    mutating func update(
        bufferedFrames: Int,
        sourceCapacityFrames: Int,
        sampleRate: Double,
        elapsedFrames: Int
    ) -> Double {
        guard sampleRate > 0, elapsedFrames > 0 else { return adjustmentPPM }
        let desiredTarget = sampleRate * 0.04
        let targetFrames = sourceCapacityFrames > 0
            ? min(desiredTarget, Double(sourceCapacityFrames) * 0.25)
            : desiredTarget
        guard targetFrames > 0 else { return adjustmentPPM }

        let deltaTime = Double(elapsedFrames) / sampleRate
        let observed = Double(max(0, bufferedFrames))
        if filteredBufferedFrames == nil { filteredBufferedFrames = targetFrames }
        let smoothing = 1 - exp(-deltaTime / 0.5)
        filteredBufferedFrames! += (observed - filteredBufferedFrames!) * smoothing

        var normalizedError = (filteredBufferedFrames! - targetFrames) / targetFrames
        if abs(normalizedError) < 0.02 { normalizedError = 0 }
        integralPPM += normalizedError * 40 * deltaTime
        integralPPM = min(400, max(-400, integralPPM))

        let requestedPPM = min(
            Self.maximumAdjustmentPPM,
            max(-Self.maximumAdjustmentPPM, normalizedError * 180 + integralPPM)
        )
        let maximumStep = max(0.25, 240 * deltaTime)
        adjustmentPPM += min(maximumStep, max(-maximumStep, requestedPPM - adjustmentPPM))
        return adjustmentPPM
    }

    mutating func reset() {
        adjustmentPPM = 0
        integralPPM = 0
        filteredBufferedFrames = nil
    }
}

struct AdaptivePCMResampler {
    private var bufferedSamples: [Float] = []
    private var sourcePosition = 0.0
    private var channelCount = 0
    private var sampleRate = 0.0

    mutating func process(_ frame: PCMFrame, adjustmentPPM: Double) -> PCMFrame {
        guard frame.channelCount > 0,
              frame.sampleRate > 0,
              frame.frameCount > 0 else { return frame }
        if channelCount != frame.channelCount || sampleRate != frame.sampleRate {
            reset()
            channelCount = frame.channelCount
            sampleRate = frame.sampleRate
        }

        if bufferedSamples.isEmpty {
            bufferedSamples.append(contentsOf: frame.interleaved.prefix(channelCount))
            sourcePosition = 1
        }
        bufferedSamples.append(contentsOf: frame.interleaved)

        let inputFramesPerOutputFrame = min(
            1.001,
            max(0.999, 1 + adjustmentPPM / 1_000_000)
        )
        let availableFrames = bufferedSamples.count / channelCount
        var output: [Float] = []
        output.reserveCapacity(Int(Double(frame.frameCount) / inputFramesPerOutputFrame + 4) * channelCount)

        while true {
            let center = Int(sourcePosition)
            guard center >= 1, center + 2 < availableFrames else { break }
            let fraction = Float(sourcePosition - Double(center))
            for channel in 0..<channelCount {
                let p0 = bufferedSamples[(center - 1) * channelCount + channel]
                let p1 = bufferedSamples[center * channelCount + channel]
                let p2 = bufferedSamples[(center + 1) * channelCount + channel]
                let p3 = bufferedSamples[(center + 2) * channelCount + channel]
                output.append(cubicInterpolate(p0, p1, p2, p3, fraction))
            }
            sourcePosition += inputFramesPerOutputFrame
        }

        let consumedFrames = max(0, Int(sourcePosition) - 1)
        if consumedFrames > 0 {
            bufferedSamples.removeFirst(consumedFrames * channelCount)
            sourcePosition -= Double(consumedFrames)
        }
        return PCMFrame(
            interleaved: output,
            channelCount: frame.channelCount,
            sampleRate: frame.sampleRate,
            sourceBufferedFrames: frame.sourceBufferedFrames,
            sourceCapacityFrames: frame.sourceCapacityFrames
        )
    }

    mutating func reset() {
        bufferedSamples.removeAll(keepingCapacity: true)
        sourcePosition = 0
        channelCount = 0
        sampleRate = 0
    }

    private func cubicInterpolate(
        _ p0: Float,
        _ p1: Float,
        _ p2: Float,
        _ p3: Float,
        _ amount: Float
    ) -> Float {
        p1 + 0.5 * amount * (
            p2 - p0 + amount * (
                2 * p0 - 5 * p1 + 4 * p2 - p3
                    + amount * (3 * (p1 - p2) + p3 - p0)
            )
        )
    }
}
