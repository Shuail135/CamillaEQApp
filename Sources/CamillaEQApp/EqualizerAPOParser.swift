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
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.lowercased().hasPrefix("preamp:") {
                guard let value = firstNumber(in: String(line.dropFirst("Preamp:".count))) else {
                    throw ParseError(line: lineNumber, message: "Invalid Preamp value")
                }
                result.preampDB += value
                continue
            }

            if line.lowercased().hasPrefix("filter") {
                if let band = try parseFilter(line, lineNumber: lineNumber) {
                    result.bands.append(band)
                }
                continue
            }

            // Device selection belongs to CamillaEQApp profiles rather than the imported text.
            if line.lowercased().hasPrefix("device:") {
                result.warnings.append("Line \(lineNumber): Device: is ignored; choose the macOS output device in the CamillaEQApp profile.")
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

    private func parseFilter(_ line: String, lineNumber: Int) throws -> EQBand? {
        guard let colon = line.firstIndex(of: ":") else {
            throw ParseError(line: lineNumber, message: "Filter line needs ':'")
        }
        let payload = String(line[line.index(after: colon)...])
        let tokens = payload.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { throw ParseError(line: lineNumber, message: "Incomplete filter") }

        let enabledToken = tokens[0].uppercased()
        if enabledToken == "OFF" { return nil }
        guard enabledToken == "ON" else { throw ParseError(line: lineNumber, message: "Expected ON or OFF") }

        let typeToken = tokens[1].uppercased()
        if (typeToken == "LS" || typeToken == "HS"), tokens.count > 2, tokens[2].lowercased().contains("db") {
            throw ParseError(line: lineNumber, message: "Fixed-slope shelf syntax (for example LS 6dB) is not supported yet")
        }

        let kind: EQBand.Kind
        switch typeToken {
        case "PK", "PEQ": kind = .peaking
        case "LS": kind = .lowShelf
        case "HS": kind = .highShelf
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
        let gain = value(after: "Gain", in: tokens)
        let q = value(after: "Q", in: tokens)
        let bw = bandwidth(in: tokens)

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

        return EQBand(kind: kind, frequency: fc, gain: gain, q: q, bandwidth: bw)
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
}
