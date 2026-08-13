import Foundation

struct CamillaConfigBuilder {
    func build(profile: DeviceProfile, parsed: ParsedEQ) -> String {
        var filters: [(String, String)] = []
        var pipelineNames: [String] = []

        if parsed.preampDB != 0 {
            let name = "preamp"
            filters.append((name, """
  \(name):
    type: Gain
    parameters:
      gain: \(fmt(parsed.preampDB))
      scale: dB
"""))
            pipelineNames.append(name)
        }

        for (index, band) in parsed.bands.enumerated() where band.enabled {
            let name = "eq_\(index + 1)"
            filters.append((name, yamlFilter(name: name, band: band)))
            pipelineNames.append(name)
        }

        let filterSection = filters.isEmpty ? "filters: {}" : "filters:\n" + filters.map(\.1).joined(separator: "\n")
        let pipelineSection: String
        if pipelineNames.isEmpty {
            pipelineSection = "pipeline: []"
        } else {
            pipelineSection = """
pipeline:
  - type: Filter
    channels: [0, 1]
    names:
\(pipelineNames.map { "      - \($0)" }.joined(separator: "\n"))
"""
        }

        return """
---
title: "\(yamlEscape(profile.name))"
devices:
  samplerate: \(profile.sampleRate)
  chunksize: \(profile.chunkSize)
  capture:
    type: Stdin
    channels: 2
    format: F32_LE
  playback:
    type: CoreAudio
    channels: 2
    device: "\(yamlEscape(profile.outputDeviceName))"
    exclusive: false
\(filterSection)
mixers: {}
\(pipelineSection)
"""
    }

    private func yamlFilter(name: String, band: EQBand) -> String {
        var lines = [
            "  \(name):",
            "    type: Biquad",
            "    parameters:",
            "      type: \(camillaType(band.kind))",
            "      freq: \(fmt(band.frequency))"
        ]
        if let gain = band.gain { lines.append("      gain: \(fmt(gain))") }
        if let q = band.q { lines.append("      q: \(fmt(q))") }
        else if let bw = band.bandwidth { lines.append("      bandwidth: \(fmt(bw))") }
        else if needsDefaultQ(band.kind) { lines.append("      q: 0.70710678") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func camillaType(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peaking"
        case .lowShelf: return "Lowshelf"
        case .highShelf: return "Highshelf"
        case .lowPass: return "Lowpass"
        case .highPass: return "Highpass"
        case .notch: return "Notch"
        case .allPass: return "Allpass"
        }
    }

    private func needsDefaultQ(_ kind: EQBand.Kind) -> Bool {
        [.lowShelf, .highShelf, .lowPass, .highPass, .notch].contains(kind)
    }

    private func fmt(_ value: Double) -> String { String(format: "%.8g", value) }
    private func yamlEscape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}
