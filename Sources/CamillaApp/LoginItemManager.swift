import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var requiresApproval = false

    init() {
        refresh()
    }

    func refresh() {
        requiresApproval = false

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = "Enabled — CamillaApp will start after you sign in."
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            statusMessage = "Approval is required in System Settings → General → Login Items."
        case .notRegistered:
            isEnabled = false
            statusMessage = "CamillaApp will not start automatically."
        case .notFound:
            // Ad-hoc release builds can receive this after an older build's
            // registration was removed because each rebuild has a new code
            // hash. The app bundle may still be correctly installed.
            isEnabled = false
            statusMessage = "CamillaApp will not start automatically."
        @unknown default:
            isEnabled = false
            statusMessage = "The login-item status could not be determined."
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        if enabled && !isInApplicationsFolder {
            isEnabled = false
            requiresApproval = false
            statusMessage = "Move CamillaApp to Applications, reopen it there, then enable login startup."
            return
        }
        isUpdating = true

        do {
            if enabled {
                try SMAppService.mainApp.register()
                switch SMAppService.mainApp.status {
                case .requiresApproval:
                    isEnabled = true
                    requiresApproval = true
                    statusMessage = "Approval is required in System Settings → General → Login Items."
                default:
                    isEnabled = true
                    requiresApproval = false
                    statusMessage = "Enabled — CamillaApp will start after you sign in."
                }
            } else {
                try SMAppService.mainApp.unregister()
                isEnabled = false
                requiresApproval = false
                statusMessage = "CamillaApp will not start automatically."
            }
        } catch {
            refresh()
            statusMessage = "Could not update the login item: \(error.localizedDescription)"
        }

        isUpdating = false
    }

    private var isInApplicationsFolder: Bool {
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return ["/Applications", userApplications].contains { root in
            appPath == root || appPath.hasPrefix(root + "/")
        }
    }
}
