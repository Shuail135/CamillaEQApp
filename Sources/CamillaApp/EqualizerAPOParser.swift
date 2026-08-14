import Foundation

struct EqualizerAPOParser {
    struct ParseError: LocalizedError {
        let line: Int
        let message: String
        var errorDescription: String? { "Line \(line): \(message)" }
    }

    func parse(_ text: String) throws -> ParsedEQ {
        var result = ParsedEQ()
        let lines = text.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmingCharacters = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\u{FEFF}"))
            let line = rawLine.trimmingCharacters(in: trimmingCharacters)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.lowercased().hasPrefix("preamp:") {
                guard let value = firstNumber(in: String(line.dropFirst("Preamp:".count))) else {
                    throw ParseError(line: lineNumber, message: "Invalid Preamp value")
                }
                result.preampDB += value
                continue
            }

            if line.lowercased().hasPrefix("filter") {
                result.bands.append(try parseFilter(line, lineNumber: lineNumber))
                continue
            }

            // Device selection belongs to CamillaApp profiles rather than the imported text.
            if line.lowercased().hasPrefix("device:") {
                result.warnings.append("Line \(lineNumber): Device: is ignored; choose the macOS output device in the CamillaApp profile.")
                continue
            }

            if line.lowercased().hasPrefix("channel:") {
                result.warnings.append("Line \(lineNumber): Channel: is not supported in v0.1; filters are applied to both stereo channels.")
                continue
            }

            throw ParseError(line: lineNumber, message: "Unsupported Equalizer APO command")
        }
        return result
    }

    private func parseFilter(_ line: String, lineNumber: Int) throws -> EQBand {
        guard let colon = line.firstIndex(of: ":") else {
            throw ParseError(line: lineNumber, message: "Filter line needs ':'")
        }
        let payload = String(line[line.index(after: colon)...])
        let tokens = payload.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { throw ParseError(line: lineNumber, message: "Incomplete filter") }

        let enabledToken = tokens[0].uppercased()
        guard enabledToken == "ON" || enabledToken == "OFF" else {
            throw ParseError(line: lineNumber, message: "Expected ON or OFF")
        }
        let enabled = enabledToken == "ON"

        let typeToken = tokens[1].uppercased()
        if (typeToken == "LS" || typeToken == "HS"), tokens.count > 2, tokens[2].lowercased().contains("db") {
            throw ParseError(line: lineNumber, message: "Fixed-slope shelf syntax (for example LS 6dB) is not supported yet")
        }

        let kind: EQBand.Kind
        switch typeToken {
        case "PK", "PEQ": kind = .peaking
        case "LS", "LSC": kind = .lowShelf
        case "HS", "HSC": kind = .highShelf
        case "LP", "LPQ": kind = .lowPass
        case "HP", "HPQ": kind = .highPass
        case "NO": kind = .notch
        case "AP": kind = .allPass
        default:
            throw ParseError(line: lineNumber, message: "Unsupported filter type \(typeToken)")
        }

        guard let fc = value(after: "Fc", in: tokens) else {
            throw ParseError(line: lineNumber, message: "Missing Fc")
        }
        guard fc > 0 else { throw ParseError(line: lineNumber, message: "Fc must be greater than zero") }
        let gain = value(after: "Gain", in: tokens)
        let explicitQ = value(after: "Q", in: tokens)
        let bw = bandwidth(in: tokens)
        if let explicitQ, explicitQ <= 0 {
            throw ParseError(line: lineNumber, message: "Q must be greater than zero")
        }
        if let bw, bw <= 0 {
            throw ParseError(line: lineNumber, message: "BW Oct must be greater than zero")
        }
        // The graphical editor is Q-based. Normalize APO's BW Oct form during
        // import so displaying or saving the band cannot silently change it.
        let q = explicitQ ?? bw.map(qFromBandwidth)

        switch kind {
        case .peaking:
            guard gain != nil else { throw ParseError(line: lineNumber, message: "Peaking filter needs Gain") }
            guard q != nil || bw != nil else { throw ParseError(line: lineNumber, message: "Peaking filter needs Q or BW Oct") }
        case .lowShelf, .highShelf:
            guard gain != nil else { throw ParseError(line: lineNumber, message: "Shelf filter needs Gain") }
        case .allPass:
            guard q != nil else { throw ParseError(line: lineNumber, message: "All-pass filter needs Q") }
        default:
            break
        }

        return EQBand(enabled: enabled, kind: kind, frequency: fc, gain: gain, q: q)
    }

    private func value(after key: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }), index + 1 < tokens.count else { return nil }
        return Double(tokens[index + 1])
    }

    private func bandwidth(in tokens: [String]) -> Double? {
        guard let bwIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("BW") == .orderedSame }) else { return nil }
        var index = bwIndex + 1
        if index < tokens.count, tokens[index].caseInsensitiveCompare("Oct") == .orderedSame { index += 1 }
        guard index < tokens.count else { return nil }
        return Double(tokens[index])
    }

    private func firstNumber(in string: String) -> Double? {
        string.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }.first
    }

    private func qFromBandwidth(_ bandwidth: Double) -> Double {
        1.0 / (2.0 * sinh(log(2.0) / 2.0 * bandwidth))
    }
}
