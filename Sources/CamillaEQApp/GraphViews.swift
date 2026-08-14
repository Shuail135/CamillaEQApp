import SwiftUI

struct GraphicEqualizerBands: View {
    @Binding var bands: [EQBand]
    @ObservedObject var spectrum: SpectrumAnalyzer
    let sampleRate: Double
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 7) {
                Text("dB")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                GainScaleLabels()
                    .frame(width: 32, height: 220)
            }
            .frame(width: 32)

            ForEach(bands.indices, id: \.self) { index in
                EQBandColumn(
                    band: $bands[index],
                    audioDB: audioLevel(at: bands[index].frequency),
                    responseDB: responseGain(at: bands[index].frequency),
                    setKind: setKind
                )
                .frame(width: columnWidth)
            }
        }
        .padding(.vertical, 8)
        .background(alignment: .topLeading) {
            EQGainGuideGrid()
        }
    }

    private func audioLevel(at frequency: Double) -> Double {
        guard !spectrum.points.isEmpty else { return -100 }
        let nearest = spectrum.points.min {
            abs(log(max($0.frequency, 1) / max(frequency, 1))) < abs(log(max($1.frequency, 1) / max(frequency, 1)))
        }
        return nearest?.db ?? -100
    }

    private func responseGain(at frequency: Double) -> Double {
        EQResponseCalculator().gainDB(
            at: frequency,
            parsed: ParsedEQ(preampDB: 0, bands: bands, warnings: []),
            sampleRate: sampleRate
        )
    }
}

private struct EQBandColumn: View {
    @Binding var band: EQBand
    let audioDB: Double
    let responseDB: Double
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    private let fieldWidth: CGFloat = 68

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                TextField("Hz", value: $band.frequency, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: fieldWidth)
                HStack {
                    Spacer()
                    Text("Hz").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

            VerticalEQSlider(
                gain: Binding(
                    get: { band.gain ?? 0 },
                    set: { band.gain = usesGain(band.kind) ? $0 : nil }
                ),
                audioDB: audioDB,
                responseDB: responseDB,
                gainEnabled: usesGain(band.kind)
            )
            .frame(width: 80, height: 220)

            VStack(spacing: 2) {
                Text("Gain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Gain", value: Binding(
                    get: { band.gain ?? 0 },
                    set: { band.gain = min(12, max(-12, $0)) }
                ), format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .disabled(!usesGain(band.kind))
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text("Q")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Q", value: Binding(
                    get: { band.q ?? 0.707 },
                    set: { band.q = max(0.05, $0) }
                ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                Button {
                    band.enabled.toggle()
                } label: {
                    Image(systemName: band.enabled ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(band.enabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 18)
                .help(band.enabled ? "Disable this filter" : "Enable this filter")

                Menu {
                    ForEach(EQBand.Kind.allCases, id: \.self) { kind in
                        Button {
                            setKind(kind, &band)
                        } label: {
                            Text(filterLabel(kind))
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        FilterShapeIcon(kind: band.kind)
                            .frame(width: 20, height: 15)
                        Text(filterLabel(band.kind))
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 39, alignment: .trailing)
                    }
                    .frame(width: 62, height: 24, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(width: 70, alignment: .center)
                .help("Filter type")
            }
            .frame(width: 90)
        }
    }

    private func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }

    private func filterLabel(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        case .allPass: return "All pass"
        }
    }
}

private struct VerticalEQSlider: View {
    @Binding var gain: Double
    let audioDB: Double
    let responseDB: Double
    let gainEnabled: Bool
    private let gainRange = -12.0...12.0
    private let visualizerRange = -72.0...0.0

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(x: (geometry.size.width - 7) / 2, y: 8, width: 7, height: geometry.size.height - 16)
            let preEQAmount = audioAmount(audioDB)
            let postEQAmount = audioAmount(audioDB + responseDB)
            let changeBottom = min(preEQAmount, postEQAmount)
            let changeHeight = track.height * abs(postEQAmount - preEQAmount)
            let thumbY = gainY(gain, track: track)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: track.width, height: track.height * preEQAmount)
                    .position(x: track.midX, y: track.maxY - track.height * preEQAmount / 2)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.48), .green],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: track.width, height: track.height * postEQAmount)
                    .position(x: track.midX, y: track.maxY - track.height * postEQAmount / 2)
                if changeHeight > 0.5 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(responseDB >= 0 ? Color.blue.opacity(0.88) : Color.orange.opacity(0.88))
                        .frame(width: track.width, height: max(2, changeHeight))
                        .position(
                            x: track.midX,
                            y: track.maxY - track.height * changeBottom - max(2, changeHeight) / 2
                        )
                }
                if abs(responseDB) >= 0.25, preEQAmount > 0 {
                    Capsule()
                        .fill(Color.primary.opacity(0.72))
                        .frame(width: 13, height: 1.5)
                        .position(x: track.midX, y: track.maxY - track.height * preEQAmount)
                }
                Circle()
                    .fill(gainEnabled ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.7))
                    .overlay(Circle().stroke(gainEnabled ? Color.primary.opacity(0.75) : Color.secondary, lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: track.midX, y: thumbY)
            }
            .animation(.linear(duration: 0.08), value: audioDB)
            .animation(.easeOut(duration: 0.12), value: responseDB)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .help("Green is the estimated post-EQ level. Blue shows boost; orange shows cut; the small marker is the pre-EQ level.")
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard gainEnabled else { return }
                    let ratio = min(1, max(0, (value.location.y - track.minY) / track.height))
                    let raw = gainRange.upperBound - ratio * (gainRange.upperBound - gainRange.lowerBound)
                    gain = (raw * 10).rounded() / 10
                }
            )
        }
    }

    private func audioAmount(_ db: Double) -> Double {
        min(1, max(0, (db - visualizerRange.lowerBound) /
            (visualizerRange.upperBound - visualizerRange.lowerBound)))
    }

    private func gainY(_ value: Double, track: CGRect) -> Double {
        let clamped = min(gainRange.upperBound, max(gainRange.lowerBound, value))
        let ratio = (gainRange.upperBound - clamped) / (gainRange.upperBound - gainRange.lowerBound)
        return track.minY + track.height * ratio
    }
}

private struct EQGainGuideGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Content begins after the 8 pt outer padding and 24 pt
                // frequency row. The slider itself has an 8 pt inset.
                let sliderTop = 47.0
                let sliderBottom = 251.0
                let gridStartX = 44.0
                for db in stride(from: -12, through: 12, by: 3) {
                    let ratio = Double(12 - db) / 24.0
                    let yy = sliderTop + (sliderBottom - sliderTop) * ratio
                    var path = Path()
                    path.move(to: CGPoint(x: gridStartX, y: yy))
                    path.addLine(to: CGPoint(x: size.width, y: yy))
                    context.stroke(
                        path,
                        with: .color(Color.secondary.opacity(db == 0 ? 0.24 : 0.11)),
                        lineWidth: db == 0 ? 1 : 0.6
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GainScaleLabels: View {
    var body: some View {
        GeometryReader { geometry in
            let top = 8.0
            let bottom = geometry.size.height - 8
            Text("+12")
                .position(x: geometry.size.width / 2, y: top)
            Text("0")
                .position(x: geometry.size.width / 2, y: (top + bottom) / 2)
            Text("−12")
                .position(x: geometry.size.width / 2, y: bottom)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct PreampControl: View {
    @Binding var preampDB: Double
    let autoAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .font(.body)
                .fixedSize()
            Slider(value: Binding(
                get: { preampDB },
                set: { preampDB = min(12, max(-12, $0)) }
            ), in: -12...12, step: 0.1)
            .frame(minWidth: 140, idealWidth: 440, maxWidth: 440)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    Text("−12")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("+12 dB")
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.72))
                .padding(.horizontal, 6)
                .offset(y: 8)
                .allowsHitTesting(false)
            }
            TextField("Preamp", value: Binding(
                get: { preampDB },
                set: { preampDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            Text("dB")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Auto", action: autoAction)
                .fixedSize()
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct FilterShapeIcon: View {
    let kind: EQBand.Kind

    var body: some View {
        Canvas { context, size in
            let points = shapePoints(size: size)
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.8)
        }
    }

    private func shapePoints(size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height
        switch kind {
        case .peaking:
            return [CGPoint(x: 0, y: h * 0.75), CGPoint(x: w * 0.3, y: h * 0.72), CGPoint(x: w * 0.5, y: h * 0.18), CGPoint(x: w * 0.7, y: h * 0.72), CGPoint(x: w, y: h * 0.75)]
        case .lowShelf:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.42, y: h * 0.2), CGPoint(x: w * 0.62, y: h * 0.75), CGPoint(x: w, y: h * 0.75)]
        case .highShelf:
            return [CGPoint(x: 0, y: h * 0.75), CGPoint(x: w * 0.38, y: h * 0.75), CGPoint(x: w * 0.58, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .lowPass:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.45, y: h * 0.2), CGPoint(x: w, y: h * 0.9)]
        case .highPass:
            return [CGPoint(x: 0, y: h * 0.9), CGPoint(x: w * 0.55, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .notch:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.38, y: h * 0.2), CGPoint(x: w * 0.5, y: h * 0.9), CGPoint(x: w * 0.62, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .allPass:
            return [CGPoint(x: 0, y: h * 0.5), CGPoint(x: w, y: h * 0.5)]
        }
    }
}

struct LineGraph: View {
    let points: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var zeroLine: Bool = false
    var lineColor: Color = .primary
    var fillsArea: Bool = false

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGrid(context: &context, rect: rect)
            guard points.count > 1 else { return }
            let path = smoothPath(points: points, size: size)
            if fillsArea {
                var fill = path
                fill.addLine(to: CGPoint(x: x(points.last!.0, width: size.width), y: size.height))
                fill.addLine(to: CGPoint(x: x(points.first!.0, width: size.width), y: size.height))
                fill.closeSubpath()
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.34), lineColor.opacity(0.04)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            context.stroke(path, with: .color(lineColor), lineWidth: 1.8)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text("20"); Spacer(); Text("100"); Spacer(); Text("1k"); Spacer(); Text("10k"); Spacer(); Text("20k Hz")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .offset(y: 16)
        }
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(dbLabel(yRange.upperBound))
                Spacer()
                Text(dbLabel((yRange.lowerBound + yRange.upperBound) / 2))
                Spacer()
                Text(dbLabel(yRange.lowerBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)
            .padding(.leading, 4)
        }
        .padding(.bottom, 16)
    }

    private func x(_ value: Double, width: Double) -> Double {
        let clamped = min(max(value, xRange.lowerBound), xRange.upperBound)
        let a = log10(xRange.lowerBound)
        let b = log10(xRange.upperBound)
        return (log10(clamped) - a) / (b - a) * width
    }

    private func y(_ value: Double, height: Double) -> Double {
        let clamped = min(max(value, yRange.lowerBound), yRange.upperBound)
        return height - (clamped - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound) * height
    }

    private func smoothPath(points: [(Double, Double)], size: CGSize) -> Path {
        let mapped = points.map { CGPoint(x: x($0.0, width: size.width), y: y($0.1, height: size.height)) }
        var path = Path()
        guard let first = mapped.first else { return path }
        path.move(to: first)
        for index in 1..<mapped.count {
            let previous = mapped[index - 1]
            let current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) * 0.5, y: (previous.y + current.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        return path
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        let freqs = [20.0, 100, 1000, 10000, 20000]
        for f in freqs {
            var p = Path()
            let xx = x(f, width: rect.width)
            p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: rect.height))
            context.stroke(p, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        if zeroLine, yRange.contains(0) {
            var p = Path()
            let yy = y(0, height: rect.height)
            p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: rect.width, y: yy))
            context.stroke(p, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
        }
    }

    private func dbLabel(_ value: Double) -> String {
        "\(Int(value.rounded())) dB"
    }
}

struct OverlayLineGraph: View {
    let input: [(Double, Double)]
    let output: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>

    var body: some View {
        ZStack {
            LineGraph(points: input, xRange: xRange, yRange: yRange, lineColor: .secondary)
            LineGraph(points: output, xRange: xRange, yRange: yRange, lineColor: .blue)
        }
    }
}

struct SpectrumWithResponseGraph: View {
    let spectrum: [(Double, Double)]
    let response: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let spectrumRange: ClosedRange<Double>
    let responseRange: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size)
            drawLine(
                points: spectrum,
                yRange: spectrumRange,
                color: .green,
                width: 1.7,
                fillsArea: true,
                context: &context,
                size: size
            )
            drawLine(
                points: response,
                yRange: responseRange,
                color: .blue,
                width: 1.4,
                fillsArea: false,
                context: &context,
                size: size
            )
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text("20"); Spacer(); Text("100"); Spacer(); Text("1k"); Spacer(); Text("10k"); Spacer(); Text("20k Hz")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .offset(y: 16)
        }
        .overlay(alignment: .leading) {
            axisLabels(range: spectrumRange)
                .padding(.leading, 4)
        }
        .overlay(alignment: .trailing) {
            axisLabels(range: responseRange, signed: true)
                .foregroundStyle(.blue)
                .padding(.trailing, 4)
        }
        .padding(.bottom, 16)
    }

    private func axisLabels(range: ClosedRange<Double>, signed: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(dbLabel(range.upperBound, signed: signed))
            Spacer()
            Text(dbLabel((range.lowerBound + range.upperBound) / 2, signed: signed))
            Spacer()
            Text(dbLabel(range.lowerBound, signed: signed))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.bottom, 16)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for frequency in [20.0, 100, 1000, 10000, 20000] {
            var path = Path()
            let xx = x(frequency, width: size.width)
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: size.height))
            context.stroke(path, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        if responseRange.contains(0) {
            var zero = Path()
            let yy = y(0, range: responseRange, height: size.height)
            zero.move(to: CGPoint(x: 0, y: yy))
            zero.addLine(to: CGPoint(x: size.width, y: yy))
            context.stroke(zero, with: .color(Color.blue.opacity(0.3)), lineWidth: 1)
        }
    }

    private func drawLine(
        points: [(Double, Double)],
        yRange: ClosedRange<Double>,
        color: Color,
        width: Double,
        fillsArea: Bool,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard points.count > 1 else { return }
        let mapped = points.map {
            CGPoint(x: x($0.0, width: size.width), y: y($0.1, range: yRange, height: size.height))
        }
        var path = Path()
        if let first = mapped.first { path.move(to: first) }
        for index in 1..<mapped.count {
            let previous = mapped[index - 1]
            let current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) * 0.5, y: (previous.y + current.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        if fillsArea {
            var fill = path
            fill.addLine(to: CGPoint(x: x(points.last!.0, width: size.width), y: size.height))
            fill.addLine(to: CGPoint(x: x(points.first!.0, width: size.width), y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.36), color.opacity(0.04)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func x(_ value: Double, width: Double) -> Double {
        let clamped = min(max(value, xRange.lowerBound), xRange.upperBound)
        let minimum = log10(xRange.lowerBound)
        let span = log10(xRange.upperBound) - minimum
        return (log10(clamped) - minimum) / span * width
    }

    private func y(_ value: Double, range: ClosedRange<Double>, height: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return height - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound) * height
    }

    private func dbLabel(_ value: Double, signed: Bool) -> String {
        let rounded = Int(value.rounded())
        return signed && rounded > 0 ? "+\(rounded) dB" : "\(rounded) dB"
    }
}

struct MeterBar: View {
    let label: String
    let rms: Double
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.1f dB", peak)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: geo.size.width * normalized(rms))
                        .animation(.linear(duration: 0.08), value: rms)
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: geo.size.width * normalized(peak) - 1)
                        .animation(.linear(duration: 0.08), value: peak)
                }
            }.frame(height: 9)
        }
    }

    private func normalized(_ db: Double) -> Double {
        min(1, max(0, (db + 72) / 72))
    }
}

struct SignalMetersView: View {
    @ObservedObject var meters: MeterModel

    var body: some View {
        HStack(spacing: 24) {
            meterGroup("Audio In", rms: meters.captureRMS, peak: meters.capturePeak)
            meterGroup("Audio Out", rms: meters.playbackRMS, peak: meters.playbackPeak)
        }
    }

    private func meterGroup(_ title: String, rms: [Double], peak: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            MeterBar(label: "L", rms: rms[safe: 0] ?? -150, peak: peak[safe: 0] ?? -150)
            MeterBar(label: "R", rms: rms[safe: 1] ?? -150, peak: peak[safe: 1] ?? -150)
        }.frame(maxWidth: .infinity)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
