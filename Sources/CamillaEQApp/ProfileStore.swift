import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [DeviceProfile] = [] {
        didSet { save() }
    }
    @Published var selectedProfileID: UUID? {
        didSet { UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }

    private let url: URL
    private var isLoading = true

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamillaEQApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("profiles.json")
        load()
        if let raw = UserDefaults.standard.string(forKey: "selectedProfileID"), let id = UUID(uuidString: raw) {
            selectedProfileID = id
        }
        if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }
        isLoading = false
        // Persist any legacy routing-device/profile-key migrations performed
        // while decoding so future launches only use the current schema.
        save()
    }

    var selectedProfile: DeviceProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    func addProfile(for device: AudioDeviceInfo) {
        let baseName = device.name
        let profile = DeviceProfile(
            name: baseName,
            outputDeviceUID: device.id,
            outputDeviceName: device.name
        )
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func setAutoActivate(profileID: UUID, enabled: Bool) {
        setAutoActivation(profileID: profileID, enabled: enabled, whenRoutingDeviceSelected: false)
    }

    func setAutoActivateWhenProfileDeviceSelected(profileID: UUID, enabled: Bool) {
        setAutoActivation(profileID: profileID, enabled: enabled, whenRoutingDeviceSelected: true)
    }

    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = profiles
        updated[index].outputDeviceUID = device.id
        updated[index].outputDeviceName = device.name

        if updated[index].autoActivate {
            disableAutoActivation(in: &updated, outputUID: device.id, excluding: profileID)
        }
        profiles = updated
    }

    // Profiles and EQ data remain saved while hardware is absent. Some audio
    // drivers return a new CoreAudio UID after reconnecting, so recover the
    // binding by name only when exactly one connected device matches.
    func reconcileDevices(_ devices: [AudioDeviceInfo]) -> Set<UUID> {
        let physicalDevices = devices.filter { !$0.isRoutingDevice }
        let connectedUIDs = Set(physicalDevices.map(\.id))
        var updated = profiles
        var reboundProfileIDs = Set<UUID>()

        for index in updated.indices where !connectedUIDs.contains(updated[index].outputDeviceUID) {
            let savedName = updated[index].outputDeviceName
            let matches = physicalDevices.filter {
                $0.name.localizedCaseInsensitiveCompare(savedName) == .orderedSame
            }
            guard matches.count == 1, let match = matches.first else { continue }

            updated[index].outputDeviceUID = match.id
            updated[index].outputDeviceName = match.name
            if updated[index].autoActivate {
                disableAutoActivation(
                    in: &updated,
                    outputUID: match.id,
                    excluding: updated[index].id
                )
            }
            reboundProfileIDs.insert(updated[index].id)
        }

        if !reboundProfileIDs.isEmpty { profiles = updated }
        return reboundProfileIDs
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
    }

    func update(_ profile: DeviceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data) else { return }
        profiles = normalizedAutoActivation(in: decoded)
    }

    private func setAutoActivation(profileID: UUID, enabled: Bool, whenRoutingDeviceSelected: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = profiles
        if enabled {
            if !whenRoutingDeviceSelected {
                let outputUID = updated[index].outputDeviceUID
                disableAutoActivation(in: &updated, outputUID: outputUID, excluding: profileID)
            }
        }
        if whenRoutingDeviceSelected {
            updated[index].autoActivateWhenProfileDeviceSelected = enabled
        } else {
            updated[index].autoActivate = enabled
        }
        profiles = updated
    }

    private func disableAutoActivation(in profiles: inout [DeviceProfile], outputUID: String, excluding profileID: UUID) {
        for index in profiles.indices
        where profiles[index].id != profileID && profiles[index].outputDeviceUID == outputUID {
            profiles[index].autoActivate = false
        }
    }

    private func normalizedAutoActivation(in profiles: [DeviceProfile]) -> [DeviceProfile] {
        var result = profiles
        var claimedOutputUIDs = Set<String>()
        for index in result.indices {
            guard result[index].autoActivate else { continue }
            if !claimedOutputUIDs.insert(result[index].outputDeviceUID).inserted {
                result[index].autoActivate = false
            }
        }
        return result
    }

    private func save() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
