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
            statusMessage = "Enabled — CamillaEQApp will start after you sign in."
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            statusMessage = "Approval is required in System Settings → General → Login Items."
        case .notRegistered:
            isEnabled = false
            statusMessage = "CamillaEQApp will not start automatically."
        case .notFound:
            isEnabled = false
            statusMessage = "The login item is unavailable. Keep the app in a permanent location, such as Applications, and try again."
        @unknown default:
            isEnabled = false
            statusMessage = "The login-item status could not be determined."
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = "Could not update the login item: \(error.localizedDescription)"
        }

        isUpdating = false
    }
}
