import Foundation

struct ProfileRoutingDescriptor: Hashable {
    static let uidPrefix = "local.camilla.profile."
    private static let legacyUIDPrefixes = ["local.camillaeq.profile."]

    let profileID: UUID
    let uid: String
    let name: String

    static func descriptors(for profiles: [DeviceProfile]) -> [UUID: ProfileRoutingDescriptor] {
        let bases = profiles.map { profile in
            (profile: profile, base: baseName(for: profile))
        }
        let groups = Dictionary(grouping: bases) {
            $0.base.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        return Dictionary(uniqueKeysWithValues: bases.map { item in
            let collides = (groups[item.base.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )]?.count ?? 0) > 1
            let suffix = item.profile.id.uuidString.prefix(6).uppercased()
            let displayName = collides ? "\(item.base) [\(suffix)]" : item.base
            let descriptor = ProfileRoutingDescriptor(
                profileID: item.profile.id,
                uid: uid(for: item.profile.id),
                name: displayName
            )
            return (item.profile.id, descriptor)
        })
    }

    static func uid(for profileID: UUID) -> String {
        uidPrefix + profileID.uuidString.lowercased()
    }

    static func profileID(from uid: String) -> UUID? {
        for prefix in [uidPrefix] + legacyUIDPrefixes where uid.hasPrefix(prefix) {
            return UUID(uuidString: String(uid.dropFirst(prefix.count)))
        }
        return nil
    }

    static func isProfileRoutingUID(_ uid: String) -> Bool {
        ([uidPrefix] + legacyUIDPrefixes).contains { uid.hasPrefix($0) }
    }

    static func visibleProfileIDs(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        defaultOutputUID: String?,
        additionallyVisible: Set<UUID> = []
    ) -> Set<UUID> {
        var result = additionallyVisible
        for profile in profiles where profile.isEnabled {
            if profile.autoActivateWhenProfileDeviceSelected {
                result.insert(profile.id)
            }
        }
        if let defaultOutputUID,
           let selectedProfileID = profileID(from: defaultOutputUID),
           profiles.contains(where: { $0.id == selectedProfileID && $0.isEnabled }) {
            result.insert(selectedProfileID)
        }
        // Keep the active native profile endpoint published. The driver routes
        // every profile endpoint into the same hidden PCM transport.
        if let activeProfileID { result.insert(activeProfileID) }
        return result
    }

    private static func baseName(for profile: DeviceProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = trimmed.isEmpty ? "EQ Profile" : trimmed
        if profileName.localizedCaseInsensitiveCompare(profile.outputDeviceName) == .orderedSame {
            return "\(profileName)-EQ"
        }
        return profileName
    }
}
