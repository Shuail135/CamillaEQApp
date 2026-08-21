import SwiftUI

struct SimpleEQControlsView: View {
    @Binding var bands: [EQBand]

    var body: some View {
        HStack(spacing: 24) {
            ForEach(SimpleEQRange.allCases) { range in
                SimpleEQKnob(
                    value: binding(for: range),
                    range: range,
                    isEnabled: SimpleEQControl.value(for: range, in: bands) != nil
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }

    private func binding(for range: SimpleEQRange) -> Binding<Double> {
        Binding(
            get: { SimpleEQControl.value(for: range, in: bands) ?? 0 },
            set: { bands = SimpleEQControl.setting($0, for: range, in: bands) }
        )
    }
}

private struct SimpleEQKnob: View {
    @Binding var value: Double
    let range: SimpleEQRange
    let isEnabled: Bool
    @State private var dragOrigin: Double?

    private var normalizedValue: Double {
        let limits = SimpleEQControl.gainRange
        return (value - limits.lowerBound) / (limits.upperBound - limits.lowerBound)
    }

    private var angle: Angle {
        .degrees(-135 + min(1, max(0, normalizedValue)) * 270)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(range.title)
                .font(.headline)
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 2.5, height: 14)
                    .offset(y: -14)
                    .rotationEffect(angle)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if dragOrigin == nil { dragOrigin = value }
                        let origin = dragOrigin ?? value
                        setValue(origin - Double(gesture.translation.height) * 0.08)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .onTapGesture(count: 2) {
                guard isEnabled else { return }
                setValue(0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(range.title)
            .accessibilityValue(isEnabled ? formattedValue : "No matching bands")
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                switch direction {
                case .increment: setValue(value + SimpleEQControl.step)
                case .decrement: setValue(value - SimpleEQControl.step)
                @unknown default: break
                }
            }

            Text(isEnabled ? formattedValue : "—")
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text(range.frequencyDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 108)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var formattedValue: String {
        String(format: "%+.1f dB", value)
    }

    private func setValue(_ newValue: Double) {
        let limits = SimpleEQControl.gainRange
        let clamped = min(limits.upperBound, max(limits.lowerBound, newValue))
        value = (clamped / SimpleEQControl.step).rounded() * SimpleEQControl.step
    }
}

struct GraphicEqualizerBands: View {
    @Binding var bands: [EQBand]
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let responsePoints: [EQResponsePoint]
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat
    var showsSpectrumLevels = true

    static func requiredContentWidth(
        bandCount: Int,
        columnWidth: CGFloat
    ) -> CGFloat {
        // The HStack contains a 32 pt gain scale followed by one 5 pt
        // inter-item gap and one fixed-width column per band.
        32 + CGFloat(max(0, bandCount)) * (columnWidth + 5)
    }

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

            ForEach(bands) { band in
                EQBandColumn(
                    band: binding(for: band),
                    spectrum: spectrum,
                    profileID: profileID,
                    responseDB: responseGain(at: band.frequency),
                    setKind: setKind,
                    showsSpectrumLevels: showsSpectrumLevels
                )
                .frame(width: columnWidth)
            }
        }
        .padding(.vertical, 8)
        .background(alignment: .topLeading) {
            EQGainGuideGrid()
        }
    }

    private func responseGain(at frequency: Double) -> Double {
        guard !responsePoints.isEmpty else { return 0 }
        var lower = 0
        var upper = responsePoints.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if responsePoints[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return responsePoints[0].gainDB }
        if lower == responsePoints.count { return responsePoints[lower - 1].gainDB }
        let before = responsePoints[lower - 1]
        let after = responsePoints[lower]
        return logDistance(before.frequency, frequency) <= logDistance(after.frequency, frequency)
            ? before.gainDB
            : after.gainDB
    }

    /// SwiftUI's collection bindings are index-backed on macOS 13. A row can be
    /// evaluated once more after the collection becomes empty, so resolve every
    /// read and write by stable band identity and safely ignore a removed row.
    private func binding(for snapshot: EQBand) -> Binding<EQBand> {
        Binding(
            get: {
                bands.first(where: { $0.id == snapshot.id }) ?? snapshot
            },
            set: { updated in
                guard bands.contains(where: { $0.id == snapshot.id }) else { return }
                bands = EQEditorSupport.organizedBands(
                    bands.map { $0.id == snapshot.id ? updated : $0 }
                )
            }
        )
    }

    private func logDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(log(max(lhs, 1) / max(rhs, 1)))
    }
}

private struct EQBandColumn: View {
    @Binding var band: EQBand
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let responseDB: Double
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let showsSpectrumLevels: Bool
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

            SpectrumAwareVerticalEQSlider(
                gain: Binding(
                    get: { band.gain ?? 0 },
                    set: { band.gain = usesGain(band.kind) ? $0 : nil }
                ),
                spectrum: spectrum,
                profileID: profileID,
                frequency: band.frequency,
                responseDB: responseDB,
                gainEnabled: usesGain(band.kind),
                showsSpectrumLevels: showsSpectrumLevels
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

private struct SpectrumAwareVerticalEQSlider: View {
    @Binding var gain: Double
    @ObservedObject var spectrum: SpectrumAnalyzer
    let profileID: UUID
    let frequency: Double
    let responseDB: Double
    let gainEnabled: Bool
    let showsSpectrumLevels: Bool

    var body: some View {
        VerticalEQSlider(
            gain: $gain,
            audioDB: audioLevel,
            responseDB: responseDB,
            gainEnabled: gainEnabled
        )
    }

    private var audioLevel: Double {
        guard showsSpectrumLevels,
              spectrum.activeProfileID == profileID,
              !spectrum.points.isEmpty else { return -100 }
        var lower = 0
        var upper = spectrum.points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if spectrum.points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return spectrum.points[0].db }
        if lower == spectrum.points.count { return spectrum.points[lower - 1].db }
        let before = spectrum.points[lower - 1]
        let after = spectrum.points[lower]
        return logDistance(before.frequency, frequency) <= logDistance(after.frequency, frequency)
            ? before.db
            : after.db
    }

    private func logDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(log(max(lhs, 1) / max(rhs, 1)))
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
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: 1, y: preEQAmount, anchor: .bottom)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.48), .green],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: 1, y: postEQAmount, anchor: .bottom)
                    .position(x: track.midX, y: track.midY)
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
            .animation(
                .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                value: audioDB
            )
            .animation(.easeOut(duration: 0.12), value: responseDB)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
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

struct PreampGainControl: View {
    @Binding var gainDB: Double
    @Binding var limiterEnabled: Bool
    @ObservedObject var meters: AudioRuntimeMonitor
    let profileID: UUID
    var title = "User preamp"
    var channelIndex: Int?
    var visualEffectsEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .fixedSize()
            MeteredGainSlider(
                gainDB: $gainDB,
                totalPeakDB: totalPeakDB,
                isClipping: isClipping,
                animationsEnabled: visualEffectsEnabled,
                accessibilityTitle: title
            )
            .frame(minWidth: 140, idealWidth: 390, maxWidth: 440)
            TextField(title, value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            Text("dB")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            Toggle("Limiter", isOn: $limiterEnabled)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Hard-limit the final processed signal to −0.5 dBFS")
            if limiterEnabled {
                if isClipping {
                    Text("CLIP")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if limiterAtCeiling {
                    Text("LIMIT")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: limiterEnabled && isClipping)
    }

    private var profileIsActive: Bool {
        meters.activeSession?.profileID == profileID
    }

    private var totalPeakDB: Double {
        guard visualEffectsEnabled, profileIsActive else { return -150 }
        if let channelIndex {
            return meters.playbackPeak.indices.contains(channelIndex)
                ? meters.playbackPeak[channelIndex]
                : -150
        }
        return meters.playbackPeak.max() ?? -150
    }

    private var isClipping: Bool {
        guard limiterEnabled, visualEffectsEnabled, profileIsActive else { return false }
        if let channelIndex {
            return meters.channelClippingIsRecent(channelIndex)
        }
        return meters.status.clippingIsRecent
    }

    private var limiterAtCeiling: Bool {
        profileIsActive
            && limiterEnabled
            && totalPeakDB >= LimiterProcessor.standard.clipLimitDB - 0.05
    }

}

private enum PreampSliderLayout {
    static let horizontalInset: CGFloat = 9
    static let controlHeight: CGFloat = 20
    static let totalHeight: CGFloat = 32
    static let labelY: CGFloat = 27
}

private struct MeteredGainSlider: View {
    @Binding var gainDB: Double
    let totalPeakDB: Double
    let isClipping: Bool
    let animationsEnabled: Bool
    let accessibilityTitle: String

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(
                x: PreampSliderLayout.horizontalInset,
                y: (PreampSliderLayout.controlHeight - 7) / 2,
                width: max(1, geometry.size.width - 2 * PreampSliderLayout.horizontalInset),
                height: 7
            )
            let levelAmount = min(1, max(0, (totalPeakDB + 72) / 72))
            let thumbX = track.minX + track.width * ((gainDB + 12) / 24)
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(isClipping ? Color.red : levelColor)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: levelAmount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)
                Rectangle()
                    .fill(isClipping ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 2, height: 11)
                    .position(x: track.midX, y: track.midY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: thumbX, y: track.midY)
                Group {
                    Text("−12")
                        .position(
                            x: track.minX,
                            y: PreampSliderLayout.labelY
                        )
                    Text("0")
                        .position(
                            x: track.midX,
                            y: PreampSliderLayout.labelY
                        )
                    Text("+12 dB")
                        .position(
                            x: track.maxX,
                            y: PreampSliderLayout.labelY
                        )
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.72))
                .allowsHitTesting(false)
            }
            .animation(
                animationsEnabled
                    ? .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration)
                    : nil,
                value: totalPeakDB
            )
            .animation(
                animationsEnabled ? .easeOut(duration: 0.1) : nil,
                value: isClipping
            )
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                gainDB = ((-12 + ratio * 24) * 10).rounded() / 10
            })
        }
        .frame(height: PreampSliderLayout.totalHeight)
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("\(gainDB, format: .number.precision(.fractionLength(1))) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gainDB = min(12, gainDB + 0.1)
            case .decrement: gainDB = max(-12, gainDB - 0.1)
            @unknown default: break
            }
        }
    }

    private var levelColor: Color {
        if totalPeakDB >= -3 { return .orange }
        return .green
    }
}

struct GainControl: View {
    @Binding var gainDB: Double
    let title: String
    var autoButtonTitle: String?
    var autoAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .fixedSize()
            Slider(value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
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
            TextField(title, value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            Text("dB")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let autoButtonTitle, let autoAction {
                Button(autoButtonTitle, action: autoAction)
                    .fixedSize()
            }
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
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGrid(context: &context, rect: rect)
            guard points.count > 1,
                  let firstPoint = points.first,
                  let lastPoint = points.last else { return }
            let path = smoothPath(points: points, size: size)
            if fillsArea {
                var fill = path
                fill.addLine(to: CGPoint(x: x(lastPoint.0, width: size.width), y: size.height))
                fill.addLine(to: CGPoint(x: x(firstPoint.0, width: size.width), y: size.height))
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
        Canvas(rendersAsynchronously: true) { context, size in
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
        guard points.count > 1,
              let firstPoint = points.first,
              let lastPoint = points.last else { return }
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
            fill.addLine(to: CGPoint(x: x(lastPoint.0, width: size.width), y: size.height))
            fill.addLine(to: CGPoint(x: x(firstPoint.0, width: size.width), y: size.height))
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
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(x: normalized(rms), y: 1, anchor: .leading)
                        .animation(
                            .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                            value: rms
                        )
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: geo.size.width * normalized(peak) - 1)
                        .animation(
                            .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                            value: peak
                        )
                }
            }.frame(height: 9)
        }
    }

    private func normalized(_ db: Double) -> Double {
        min(1, max(0, (db + 72) / 72))
    }
}

struct SignalMetersView: View {
    let meters: AudioRuntimeMonitor
    let profileID: UUID

    var body: some View {
        HStack(spacing: 24) {
            meterGroup("Audio In", source: .capture)
            meterGroup("Audio Out", source: .playback)
        }
    }

    private func meterGroup(_ title: String, source: LiveStereoMeterBars.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LiveStereoMeterBars(meters: meters, profileID: profileID, source: source)
        }.frame(maxWidth: .infinity)
    }
}

struct AudioRuntimeStatusView: View {
    @ObservedObject var monitor: AudioRuntimeMonitor
    let profileID: UUID

    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 24)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
                Text(activeStatus.engineState)
                    .font(.body.weight(.medium))
                if activeStatus.stopReason != "None" {
                    Text(activeStatus.stopReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                RuntimeMetricValue(
                    title: "DSP load",
                    value: percent(activeStatus.processingLoadPercent),
                    detail: "Resampler \(percent(activeStatus.resamplerLoadPercent))"
                )
                RuntimeMetricValue(
                    title: "DSP buffer",
                    value: "\(activeStatus.dspBufferLevelFrames) frames",
                    detail: bridgeBufferDetail
                )
                RuntimeMetricValue(
                    title: "Rate adjust",
                    value: String(format: "%+.1f ppm", activeStatus.effectiveRateAdjustmentPPM),
                    detail: "Matched buffer \(activeStatus.route.rateMatchBufferedFrames) frames"
                )
                RuntimeMetricValue(
                    title: "Clipping",
                    value: clippingValue,
                    detail: clippingDetail,
                    accent: activeStatus.clippingIsRecent ? .red : nil
                )
                RuntimeMetricValue(
                    title: "Stream",
                    value: routeValue,
                    detail: activeStatus.route.sampleRate > 0 ? "System Audio Bridge" : "No active route"
                )
                RuntimeMetricValue(
                    title: "Delivery",
                    value: deliveryValue,
                    detail: deliveryDetail
                )
            }
        }
    }

    private var profileIsActive: Bool { monitor.activeSession?.profileID == profileID }
    private var activeStatus: AudioRuntimeStatus {
        profileIsActive ? monitor.status : .inactive
    }

    private var healthColor: Color {
        switch activeStatus.health {
        case .inactive: return .secondary
        case .healthy: return .green
        case .warning: return .orange
        case .fault: return .red
        }
    }

    private var bridgeBufferDetail: String {
        guard let ratio = activeStatus.route.bridgeFillRatio else {
            return "Bridge buffer unavailable"
        }
        return "Bridge \(Int((ratio * 100).rounded()))% full"
    }

    private var clippingValue: String {
        let hasClipping = activeStatus.dspClippedSamples > 0
            || activeStatus.sourceClippedSamples > 0
        return hasClipping ? "Detected" : "None"
    }

    private var clippingDetail: String {
        if activeStatus.clippingIsRecent { return "Detected recently" }
        return "DSP \(activeStatus.dspClippedSamples) · source \(activeStatus.sourceClippedSamples) samples"
    }

    private var routeValue: String {
        let route = activeStatus.route
        guard route.sampleRate > 0 else { return "Idle" }
        return String(format: "%.1f kHz · %u ch", route.sampleRate / 1_000, route.activeChannels)
    }

    private var deliveryValue: String {
        let route = activeStatus.route
        let dropped = route.bridgeDroppedFrames + route.camillaDroppedFrames
        return "\(dropped) dropped"
    }

    private var deliveryDetail: String {
        let route = activeStatus.route
        return "\(route.bridgeUnderrunCount) underruns · \(route.camillaQueueRecoveries) recoveries"
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
}

private struct RuntimeMetricValue: View {
    let title: String
    let value: String
    let detail: String
    var accent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(accent ?? .primary)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveStereoMeterBars: View {
    enum Source {
        case capture
        case playback
    }

    @ObservedObject var meters: AudioRuntimeMonitor
    let profileID: UUID
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeterBar(label: "L", rms: rms[safe: 0] ?? -150, peak: peak[safe: 0] ?? -150)
            MeterBar(label: "R", rms: rms[safe: 1] ?? -150, peak: peak[safe: 1] ?? -150)
        }
    }

    private var profileIsActive: Bool { meters.activeSession?.profileID == profileID }
    private var rms: [Double] {
        guard profileIsActive else { return [-150, -150] }
        return source == .capture ? meters.captureRMS : meters.playbackRMS
    }
    private var peak: [Double] {
        guard profileIsActive else { return [-150, -150] }
        return source == .capture ? meters.capturePeak : meters.playbackPeak
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
