import Foundation

struct ProfileRoutingDescriptor: Hashable {
    static let uidPrefix = "local.camillaeq.profile."

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
        guard uid.hasPrefix(uidPrefix) else { return nil }
        return UUID(uuidString: String(uid.dropFirst(uidPrefix.count)))
    }

    static func visibleProfileIDs(
        profiles: [DeviceProfile],
        activeProfileID: UUID?,
        defaultOutputUID: String?,
        additionallyVisible: Set<UUID> = []
    ) -> Set<UUID> {
        var result = additionallyVisible
        for profile in profiles {
            if profile.autoActivateWhenProfileDeviceSelected ||
                (profile.autoActivate && defaultOutputUID == profile.outputDeviceUID) {
                result.insert(profile.id)
            }
        }
        if let defaultOutputUID,
           let selectedProfileID = profileID(from: defaultOutputUID),
           profiles.contains(where: { $0.id == selectedProfileID }) {
            result.insert(selectedProfileID)
        }
        // The active profile uses the real bridge device so macOS exposes its
        // master volume control. Aggregates are selection-only entries.
        if let activeProfileID { result.remove(activeProfileID) }
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
