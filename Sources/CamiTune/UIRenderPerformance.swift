import AppKit

@MainActor
enum UIRenderPerformance {
    private static var monitoringStarted = false
    private static var liveScrollDepth = 0
    private static var observers: [NSObjectProtocol] = []

    static func startMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in liveScrollDepth += 1 }
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in liveScrollDepth = max(0, liveScrollDepth - 1) }
            }
        ]
    }

    static var isLiveResizing: Bool {
        guard let application = NSApp else { return false }
        return application.windows.contains(where: \.inLiveResize)
    }

    static var isInteractionInProgress: Bool {
        isLiveResizing || liveScrollDepth > 0
    }

    static func allowsSpectrumPublication(
        since _: Date,
        now _: Date = Date()
    ) -> Bool {
        // Spectrum redraws fan out to both canvases and every visible EQ band.
        // Preserve the last frame while AppKit is tracking a scroll or resize;
        // the next FFT frame is published as soon as interaction ends.
        !isInteractionInProgress
    }

    static var meterPollMilliseconds: Int {
        isInteractionInProgress ? 250 : 100
    }

    static var animatedLevelTransitionDuration: Double {
        isInteractionInProgress ? 0.10 : 0.08
    }
}
