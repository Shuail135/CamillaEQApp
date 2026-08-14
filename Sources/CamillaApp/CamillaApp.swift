import SwiftUI
import AppKit
import CoreImage
import Darwin

@main
struct CamillaAppMain: App {
    @NSApplicationDelegateAdaptor(CamillaAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("CamillaApp", id: "main") {
            ContentView(state: state)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("License & Warranty") { AppLicense.show() }
                Divider()
                Button("Recheck Audio Devices") { state.coreAudio.refresh() }
            }
        }

        MenuBarExtra {
            CamillaMenuBarView(state: state)
        } label: {
            Image(nsImage: state.isActive ? AppIcon.activeMenuBarImage : AppIcon.inactiveMenuBarImage)
                .renderingMode(.original)
                .accessibilityLabel(state.isActive ? "CamillaApp, EQ active" : "CamillaApp, EQ inactive")
        }
    }
}

private enum AppLicense {
    static func show() {
        let alert = NSAlert()
        alert.messageText = "CamillaApp — GPL-3.0-only"
        alert.informativeText = "Copyright © 2026 CamillaApp contributors. This program is free software and comes with ABSOLUTELY NO WARRANTY. The complete license and third-party notices are included in the application bundle and source repository."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

private enum AppIcon {
    static let image: NSImage = {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
#endif
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "CamillaApp")
            ?? NSImage()
    }()

    static let activeMenuBarImage: NSImage = {
        let image = AppIcon.image.copy() as? NSImage ?? AppIcon.image
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    static let inactiveMenuBarImage: NSImage = {
        guard let data = AppIcon.image.tiffRepresentation,
              let source = CIImage(data: data) else {
            return activeMenuBarImage
        }
        let grayscale = source.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0.0]
        )
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(NSCIImageRep(ciImage: grayscale))
        return image
    }()
}

private struct CamillaMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: AppState

    var body: some View {
        Button("Show CamillaApp") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.title == "CamillaApp" })?.makeKeyAndOrderFront(nil)
            }
            Task { await state.updateChecker.checkAfterReminderIfNeeded() }
        }
        Divider()
        Button("Quit CamillaApp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class CamillaAppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var windowDelegateProxies: [ObjectIdentifier: WindowCloseDelegateProxy] = [:]
    private let closeHintKey = "hideCloseKeepsRunningHint"
    private var instanceLockFileDescriptor: Int32 = -1
    private var rejectedDuplicateInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamillaApp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let lockURL = supportDirectory.appendingPathComponent("application.lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }

            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                Darwin.close(descriptor)
                rejectedDuplicateInstance = true
                activateExistingInstance()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }

            _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            instanceLockFileDescriptor = descriptor
        } catch {
            // Failure to create a lock must not make the audio application unusable.
            // Normal macOS bundle launching still coalesces duplicate launches.
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !rejectedDuplicateInstance else { return }
        NSApp.applicationIconImage = AppIcon.image
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "CamillaApp" else { return }
            self?.mainWindowDidClose(window)
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "CamillaApp" else { return }
            NSApp.setActivationPolicy(.regular)
            self?.installCloseDelegate(on: window)
        }
        for window in NSApp.windows where window.title == "CamillaApp" {
            installCloseDelegate(on: window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if instanceLockFileDescriptor >= 0 {
            _ = Darwin.lockf(instanceLockFileDescriptor, F_ULOCK, 0)
            Darwin.close(instanceLockFileDescriptor)
            instanceLockFileDescriptor = -1
        }
    }

    private func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func installCloseDelegate(on window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let proxy = windowDelegateProxies[key], window.delegate === proxy { return }
        let proxy = WindowCloseDelegateProxy(original: window.delegate) { [weak self] in
            self?.confirmWindowClose() ?? true
        }
        windowDelegateProxies[key] = proxy
        window.delegate = proxy
    }

    private func confirmWindowClose() -> Bool {
        guard !UserDefaults.standard.bool(forKey: closeHintKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "CamillaApp will keep running"
        alert.informativeText = "Closing this window keeps System-wide EQ and audio processing active. Use the menu-bar icon to reopen the app or quit it completely."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: closeHintKey)
        }
        return true
    }

    private func mainWindowDidClose(_ window: NSWindow) {
        windowDelegateProxies.removeValue(forKey: ObjectIdentifier(window))
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
