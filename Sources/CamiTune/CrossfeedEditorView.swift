import SwiftUI

/// Simple crossfeed controls. The split/merge mixers and the cross-path
/// low-pass, delay, and gain filters remain graph/compiler implementation
/// details as required by the roadmap.
struct CrossfeedEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile

    @State private var settings = CrossfeedProcessor.standard
    @State private var isEnabled = false
    @State private var suppressChanges = false
    @State private var liveApplyTask: Task<Void, Never>?

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Headphone Crossfeed").font(.title3.bold())
                    Spacer()
                    Toggle("Enable", isOn: Binding(
                        get: { isEnabled },
                        set: { value in
                            isEnabled = value
                            commit()
                        }
                    ))
                    .toggleStyle(.switch)
                }

                Text("Blend delayed, low-frequency sound from each stereo channel into the opposite ear to reduce hard left/right separation on headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    controlRow(
                        title: "Crossfeed Amount",
                        value: Binding(
                            get: { settings.amountPercent },
                            set: { value in
                                settings.amountPercent = value
                                commit()
                            }
                        ),
                        range: 0...100,
                        step: 1,
                        valueText: settings.amountPercent.formatted(
                            .number.precision(.fractionLength(0))
                        ) + "%"
                    )
                    controlRow(
                        title: "Delay",
                        value: Binding(
                            get: { settings.delayMilliseconds },
                            set: { value in
                                settings.delayMilliseconds = value
                                commit()
                            }
                        ),
                        range: 0...2,
                        step: 0.01,
                        valueText: settings.delayMilliseconds.formatted(
                            .number.precision(.fractionLength(2))
                        ) + " ms"
                    )
                    controlRow(
                        title: "Frequency",
                        value: Binding(
                            get: { settings.cutoffFrequency },
                            set: { value in
                                settings.cutoffFrequency = value
                                commit()
                            }
                        ),
                        range: 200...2_000,
                        step: 10,
                        valueText: settings.cutoffFrequency.formatted(
                            .number.precision(.fractionLength(0))
                        ) + " Hz"
                    )
                }
                .disabled(!isEnabled)

                Text("Automatic headroom includes the maximum correlated-signal boost introduced by crossfeed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .onAppear { load() }
        .onChange(of: profile.id) { _ in load() }
    }

    private func controlRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(valueText)
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
        }
    }

    private func load() {
        suppressChanges = true
        let saved = profile.processing.crossfeed
        settings = saved?.processor ?? .standard
        isEnabled = saved?.isEnabled ?? false
        DispatchQueue.main.async { suppressChanges = false }
    }

    private func commit() {
        guard !suppressChanges else { return }
        profile.processing.setCrossfeed(settings, enabled: isEnabled)
        guard profileIsActive else { return }
        let updated = profile
        liveApplyTask?.cancel()
        liveApplyTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await state.apply(profile: updated)
        }
    }
}
