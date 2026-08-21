import Foundation

enum ProfileNamePolicy {
    static func uniqueName(base requestedBase: String, existingNames: [String]) -> String {
        let trimmed = requestedBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        let existingKeys = Set(existingNames.map(comparisonKey))
        guard existingKeys.contains(comparisonKey(base)) else { return base }

        var suffix = 2
        while existingKeys.contains(comparisonKey("\(base) \(suffix)")) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    static func isAvailable(_ name: String, in profiles: [DeviceProfile], excluding profileID: UUID? = nil) -> Bool {
        let key = comparisonKey(name)
        return !profiles.contains { profile in
            profile.id != profileID && comparisonKey(profile.name) == key
        }
    }

    static func normalized(_ profiles: [DeviceProfile]) -> [DeviceProfile] {
        var result: [DeviceProfile] = []
        result.reserveCapacity(profiles.count)
        for var profile in profiles {
            profile.name = uniqueName(base: profile.name, existingNames: result.map(\.name))
            result.append(profile)
        }
        return result
    }

    private static func comparisonKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [DeviceProfile] = [] {
        didSet { save() }
    }
    @Published private(set) var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile] = [] {
        didSet { save() }
    }
    @Published var selectedProfileID: UUID? {
        didSet { userDefaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }
    @Published private(set) var persistenceError: String?

    private let url: URL
    private let userDefaults: UserDefaults
    private var isLoading = true
    private var saveDeferralDepth = 0
    private var needsDeferredSave = false
    /// An existing store that this version cannot decode may belong to a newer
    /// CamiTune version. Never replace it with the empty in-memory fallback.
    private var protectsUnreadableStorage = false

    init(storageURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        let base = storageURL?.deletingLastPathComponent() ?? CamiTunePaths.supportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = storageURL ?? base.appendingPathComponent("profiles.json")
        self.userDefaults = userDefaults
        load()
        sanitizeProfiles()
        sanitizePhysicalDeviceDefaults()
        if let raw = userDefaults.string(forKey: "selectedProfileID"),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
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

    @discardableResult
    func addProfile(for device: AudioDeviceInfo) -> DeviceProfile? {
        guard !device.isRoutingDevice else { return nil }
        let isFirstProfileForDevice = !profiles.contains { $0.outputDeviceUID == device.id }
        let baseName = ProfileNamePolicy.uniqueName(
            base: device.name,
            existingNames: profiles.map(\.name)
        )
        let profile = DeviceProfile(
            name: baseName,
            outputDeviceUID: device.id,
            outputDeviceName: device.name,
            autoActivateWhenProfileDeviceSelected: !isFirstProfileForDevice
        )
        performBatchUpdate {
            profiles.append(profile)
            if isFirstProfileForDevice {
                setAutomaticProfile(physicalDevice: profile.outputDevice, profileID: profile.id)
            }
        }
        selectedProfileID = profile.id
        return profile
    }

    func setAutoActivateWhenProfileDeviceSelected(profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].autoActivateWhenProfileDeviceSelected = enabled
    }

    func setProfileEnabled(profileID: UUID, enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].isEnabled = enabled
    }

    func setOutputDevice(profileID: UUID, device: AudioDeviceInfo) {
        guard !device.isRoutingDevice else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let oldUID = profiles[index].outputDeviceUID
        guard oldUID != device.id || profiles[index].outputDeviceName != device.name else {
            return
        }
        let wasAutomaticDefault = automaticProfileID(forPhysicalDeviceUID: oldUID) == profileID

        performBatchUpdate {
            var updated = profiles
            updated[index].outputDeviceUID = device.id
            updated[index].outputDeviceName = device.name
            profiles = updated

            // A default belongs to a physical output, not merely a profile ID.
            // Moving that profile must not leave an impossible old mapping.
            physicalDeviceDefaults.removeAll { $0.profileID == profileID }
            if wasAutomaticDefault {
                setAutomaticProfile(
                    physicalDevice: PhysicalOutputIdentity(uid: device.id, name: device.name),
                    profileID: profileID
                )
            }
        }
    }

    func automaticProfileID(forPhysicalDeviceUID uid: String) -> UUID? {
        physicalDeviceDefaults.first(where: { $0.physicalDevice.uid == uid })?.profileID
    }

    func automaticProfile(forPhysicalDeviceUID uid: String) -> DeviceProfile? {
        guard let profileID = automaticProfileID(forPhysicalDeviceUID: uid) else { return nil }
        return profiles.first {
            $0.id == profileID && $0.isEnabled && $0.outputDeviceUID == uid
        }
    }

    func setAutomaticProfile(physicalDevice: PhysicalOutputIdentity, profileID: UUID?) {
        var updated = physicalDeviceDefaults.filter { $0.physicalDevice.uid != physicalDevice.uid }
        if let profileID,
           profiles.contains(where: { $0.id == profileID && $0.outputDeviceUID == physicalDevice.uid }) {
            updated.append(PhysicalDeviceDefaultProfile(
                physicalDevice: physicalDevice,
                profileID: profileID
            ))
        }
        physicalDeviceDefaults = updated
    }

    func deleteProfile(id: UUID) {
        performBatchUpdate {
            physicalDeviceDefaults.removeAll { $0.profileID == id }
            profiles.removeAll { $0.id == id }
        }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
    }

    func update(_ profile: DeviceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard ProfileNamePolicy.isAvailable(profile.name, in: profiles, excluding: profile.id) else { return }
        profiles[index] = profile
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            protectUnreadableStorage(details: error.localizedDescription)
            return
        }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode(StoredProfileConfiguration.self, from: data) {
            profiles = stored.profiles
            physicalDeviceDefaults = stored.physicalDeviceDefaults
            return
        }
        guard let legacy = try? decoder.decode([LegacyStoredProfile].self, from: data) else {
            protectUnreadableStorage(
                details: "The file is damaged or was written by an incompatible CamiTune version."
            )
            return
        }
        profiles = legacy.map(\.profile)

        var claimedUIDs = Set<String>()
        physicalDeviceDefaults = legacy.compactMap { item in
            guard item.autoActivate,
                  claimedUIDs.insert(item.profile.outputDeviceUID).inserted else { return nil }
            return PhysicalDeviceDefaultProfile(
                physicalDevice: item.profile.outputDevice,
                profileID: item.profile.id
            )
        }
    }

    private func sanitizePhysicalDeviceDefaults() {
        var claimedUIDs = Set<String>()
        physicalDeviceDefaults = physicalDeviceDefaults.filter { mapping in
            guard let profile = profiles.first(where: { $0.id == mapping.profileID }),
                  profile.outputDeviceUID == mapping.physicalDevice.uid,
                  claimedUIDs.insert(mapping.physicalDevice.uid).inserted else {
                return false
            }
            return true
        }
    }

    private func sanitizeProfiles() {
        var usedIDs = Set<UUID>()
        var sanitized: [DeviceProfile] = []
        sanitized.reserveCapacity(profiles.count)
        for var profile in profiles {
            if !usedIDs.insert(profile.id).inserted {
                repeat { profile.id = UUID() } while !usedIDs.insert(profile.id).inserted
            }
            profile.name = ProfileNamePolicy.uniqueName(
                base: profile.name,
                existingNames: sanitized.map(\.name)
            )
            sanitized.append(profile)
        }
        profiles = sanitized
    }

    private func performBatchUpdate(_ changes: () -> Void) {
        saveDeferralDepth += 1
        changes()
        saveDeferralDepth -= 1
        if saveDeferralDepth == 0, needsDeferredSave {
            needsDeferredSave = false
            save()
        }
    }

    private func save() {
        guard !isLoading else { return }
        guard !protectsUnreadableStorage else { return }
        guard saveDeferralDepth == 0 else {
            needsDeferredSave = true
            return
        }
        let stored = StoredProfileConfiguration(
            profiles: profiles,
            physicalDeviceDefaults: physicalDeviceDefaults
        )
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "CamiTune could not save your profiles: \(error.localizedDescription)"
        }
    }

    private func protectUnreadableStorage(details: String) {
        protectsUnreadableStorage = true
        persistenceError = "CamiTune could not read the saved profiles, so the original profiles.json has been left unchanged and this session's profile edits cannot be saved. \(details)"
    }
}

private struct StoredProfileConfiguration: Codable {
    var profiles: [DeviceProfile]
    var physicalDeviceDefaults: [PhysicalDeviceDefaultProfile]
}

private struct LegacyStoredProfile: Decodable {
    let profile: DeviceProfile
    let autoActivate: Bool

    private enum CodingKeys: String, CodingKey {
        case autoActivate
    }

    init(from decoder: Decoder) throws {
        profile = try DeviceProfile(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoActivate = try values.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? false
    }
}
