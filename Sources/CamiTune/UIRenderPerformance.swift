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
        since lastPublication: Date,
        now: Date = Date()
    ) -> Bool {
        !isInteractionInProgress || now.timeIntervalSince(lastPublication) >= 0.10
    }

    static var meterPollMilliseconds: Int {
        isInteractionInProgress ? 140 : 100
    }

    static var animatedLevelTransitionDuration: Double {
        isInteractionInProgress ? 0.10 : 0.08
    }
}
