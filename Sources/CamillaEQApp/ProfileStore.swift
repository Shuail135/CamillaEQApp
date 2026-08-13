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
        setAutoActivation(profileID: profileID, enabled: enabled, whenBlackHoleSelected: false)
    }

    func setAutoActivateWhenBlackHoleSelected(profileID: UUID, enabled: Bool) {
        setAutoActivation(profileID: profileID, enabled: enabled, whenBlackHoleSelected: true)
    }

    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = profiles
        updated[index].outputDeviceUID = device.id
        updated[index].outputDeviceName = device.name

        if updated[index].autoActivate || (updated[index].autoActivateWhenBlackHoleSelected ?? false) {
            disableAutoActivation(in: &updated, outputUID: device.id, excluding: profileID)
        }
        profiles = updated
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

    private func setAutoActivation(profileID: UUID, enabled: Bool, whenBlackHoleSelected: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = profiles
        if enabled {
            let outputUID = updated[index].outputDeviceUID
            disableAutoActivation(in: &updated, outputUID: outputUID, excluding: profileID)
            updated[index].autoActivate = !whenBlackHoleSelected
            updated[index].autoActivateWhenBlackHoleSelected = whenBlackHoleSelected
        } else if whenBlackHoleSelected {
            updated[index].autoActivateWhenBlackHoleSelected = false
        } else {
            updated[index].autoActivate = false
        }
        profiles = updated
    }

    private func disableAutoActivation(in profiles: inout [DeviceProfile], outputUID: String, excluding profileID: UUID) {
        for index in profiles.indices
        where profiles[index].id != profileID && profiles[index].outputDeviceUID == outputUID {
            profiles[index].autoActivate = false
            profiles[index].autoActivateWhenBlackHoleSelected = false
        }
    }

    private func normalizedAutoActivation(in profiles: [DeviceProfile]) -> [DeviceProfile] {
        var result = profiles
        var claimedOutputUIDs = Set<String>()
        for index in result.indices {
            let enabled = result[index].autoActivate || (result[index].autoActivateWhenBlackHoleSelected ?? false)
            guard enabled else { continue }
            if claimedOutputUIDs.insert(result[index].outputDeviceUID).inserted {
                if result[index].autoActivate {
                    result[index].autoActivateWhenBlackHoleSelected = false
                }
            } else {
                result[index].autoActivate = false
                result[index].autoActivateWhenBlackHoleSelected = false
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
