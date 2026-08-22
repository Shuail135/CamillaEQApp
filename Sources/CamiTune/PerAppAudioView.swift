import AppKit
import SwiftUI

struct PerAppAudioView: View {
    @ObservedObject var controller: PerAppAudioController

    private var activeApplications: [PerAppAudioApplication] {
        controller.applications.filter(\.isActive)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Application Audio").font(.largeTitle.bold())
                Text("Each application is processed and mixed independently before the active profile's global DSP.")
                    .foregroundStyle(.secondary)

                if activeApplications.isEmpty {
                    GroupBox {
                        VStack(spacing: 10) {
                            Image(systemName: "speaker.slash")
                                .font(.largeTitle)
                            Text("No eligible applications are running")
                                .font(.headline)
                            Text("Open a Dock app, or play audio once from a menu-bar app.")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else {
                    ForEach(activeApplications) { application in
                        applicationCard(application)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear {
            controller.setMeterPresentationActive(true, source: "main")
        }
        .onDisappear {
            controller.setMeterPresentationActive(false, source: "main")
        }
    }

    private func applicationCard(_ application: PerAppAudioApplication) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: icon(for: application))
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.displayName).font(.title3.bold())
                        Text(application.bundleID ?? "PID \(application.processID)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button {
                        controller.setMuted(!application.settings.isMuted, for: application.id)
                    } label: {
                        Image(systemName: application.settings.isMuted
                            ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(application.settings.isMuted ? "Unmute application" : "Mute application")

                    Text("Volume")
                        .frame(width: 58, alignment: .leading)
                    MeteredApplicationVolumeSlider(
                        volume: application.settings.volume,
                        level: application.level,
                        isMuted: application.settings.isMuted,
                        onVolumeChange: {
                            controller.setVolume($0, for: application.id)
                        }
                    )
                    .frame(height: 24)
                    Text("\(Int((application.settings.volume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Divider()

                HStack {
                    Text("Per-application EQ").font(.headline)
                    Spacer()
                    Toggle(
                        "Bypass EQ",
                        isOn: Binding(
                            get: { application.settings.eqBypassed },
                            set: { controller.setEQBypassed($0, for: application.id) }
                        )
                    )
                    Button("Reset EQ") {
                        controller.setEqualizerBands([], for: application.id)
                    }
                    .disabled(application.settings.equalizerBands.isEmpty)
                }

                HStack(spacing: 18) {
                    eqControl(.bass, title: "Bass", application: application)
                    eqControl(.mids, title: "Mids", application: application)
                    eqControl(.treble, title: "Treble", application: application)
                }
                .disabled(application.settings.eqBypassed)

                Text("Application EQ is available only in the main CamiTune window. Menu-bar controls intentionally expose volume and mute only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(7)
        }
    }

    private func eqControl(
        _ control: SimpleEQRange,
        title: String,
        application: PerAppAudioApplication
    ) -> some View {
        let bands = application.settings.equalizerBands
        let value = SimpleEQControl.value(for: control, in: bands) ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                Text("dB").foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: {
                        SimpleEQControl.value(
                            for: control,
                            in: application.settings.equalizerBands
                        ) ?? 0
                    },
                    set: { newValue in
                        let source = application.settings.equalizerBands.isEmpty
                            ? EQDefaults.bands
                            : application.settings.equalizerBands
                        controller.setEqualizerBands(
                            SimpleEQControl.setting(newValue, for: control, in: source),
                            for: application.id
                        )
                    }
                ),
                in: -12...12,
                step: 0.5
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(for application: PerAppAudioApplication) -> NSImage {
        PerAppIconCache.icon(for: application)
    }
}

struct MeteredApplicationVolumeSlider: View {
    var volume: Double
    var level: Double
    var isMuted: Bool
    var onVolumeChange: (Double) -> Void
    @State private var interactionVolume: Double?

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 9
            let trackHeight: CGFloat = 7
            let track = CGRect(
                x: inset,
                y: (geometry.size.height - trackHeight) / 2,
                width: max(1, geometry.size.width - 2 * inset),
                height: trackHeight
            )
            let meterAmount = isMuted ? 0 : min(1, max(0, level))
            let volumeAmount = min(1, max(0, interactionVolume ?? volume))
            let thumbX = track.minX + track.width * volumeAmount
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(.green)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: meterAmount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: thumbX, y: track.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                value: meterAmount
            )
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                let adjusted = (ratio * 100).rounded() / 100
                interactionVolume = adjusted
                onVolumeChange(adjusted)
            }.onEnded { value in
                let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                let adjusted = (ratio * 100).rounded() / 100
                interactionVolume = adjusted
                onVolumeChange(adjusted)
                DispatchQueue.main.async {
                    interactionVolume = nil
                }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Application volume")
    }

}

@MainActor
enum PerAppIconCache {
    private static var images: [String: NSImage] = [:]

    static func icon(for application: PerAppAudioApplication) -> NSImage {
        if let cached = images[application.id] { return cached }
        let resolved: NSImage
        if let bundleURL = application.bundleURL {
            resolved = NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else if let running = NSRunningApplication(
            processIdentifier: application.processID
        ), let icon = running.icon {
            resolved = icon
        } else if let bundleID = application.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID
                  ) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            resolved = NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: nil
            ) ?? NSImage()
        }
        images[application.id] = resolved
        return resolved
    }
}
