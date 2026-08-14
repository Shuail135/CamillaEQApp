import XCTest
@testable import CamillaEQApp

final class ProfileRoutingDescriptorTests: XCTestCase {
    func testHardwareNameGetsEQSuffix() {
        let profile = DeviceProfile(
            name: "External Headphones",
            outputDeviceUID: "physical-1",
            outputDeviceName: "External Headphones"
        )

        let descriptor = ProfileRoutingDescriptor.descriptors(for: [profile])[profile.id]

        XCTAssertEqual(descriptor?.name, "External Headphones-EQ")
        XCTAssertEqual(descriptor?.uid, ProfileRoutingDescriptor.uid(for: profile.id))
    }

    func testDuplicateProfileNamesGetStableUniqueNamesAndUIDs() {
        let first = DeviceProfile(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            name: "Music",
            outputDeviceUID: "physical-1",
            outputDeviceName: "Headphones"
        )
        let second = DeviceProfile(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
            name: "Music",
            outputDeviceUID: "physical-2",
            outputDeviceName: "Speakers"
        )

        let descriptors = ProfileRoutingDescriptor.descriptors(for: [second, first])

        XCTAssertEqual(descriptors[first.id]?.name, "Music [AAAAAA]")
        XCTAssertEqual(descriptors[second.id]?.name, "Music [BBBBBB]")
        XCTAssertNotEqual(descriptors[first.id]?.uid, descriptors[second.id]?.uid)
        XCTAssertEqual(
            ProfileRoutingDescriptor.profileID(from: descriptors[first.id]!.uid),
            first.id
        )
    }

    func testNewProfilesDoNotPublishADeviceUntilRequested() {
        let profile = DeviceProfile(
            name: "Gaming",
            outputDeviceUID: "physical-1",
            outputDeviceName: "Headphones"
        )
        XCTAssertFalse(profile.autoActivate)
        XCTAssertFalse(profile.autoActivateWhenProfileDeviceSelected)
    }

    func testSeveralSelectedDeviceProfilesCanBeVisibleTogether() {
        var first = DeviceProfile(
            name: "Music",
            outputDeviceUID: "physical-1",
            outputDeviceName: "Headphones"
        )
        var second = DeviceProfile(
            name: "Movies",
            outputDeviceUID: "physical-1",
            outputDeviceName: "Headphones"
        )
        first.autoActivateWhenProfileDeviceSelected = true
        second.autoActivateWhenProfileDeviceSelected = true

        let visible = ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: [first, second],
            activeProfileID: nil,
            defaultOutputUID: "physical-2"
        )

        XCTAssertEqual(visible, [first.id, second.id])
    }

    func testPhysicalDefaultProfileOnlyAppearsForItsHardware() {
        var profile = DeviceProfile(
            name: "Speakers",
            outputDeviceUID: "physical-speakers",
            outputDeviceName: "Speakers"
        )
        profile.autoActivate = true

        XCTAssertFalse(ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: [profile],
            activeProfileID: nil,
            defaultOutputUID: "physical-headphones"
        ).contains(profile.id))
        XCTAssertTrue(ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: [profile],
            activeProfileID: nil,
            defaultOutputUID: "physical-speakers"
        ).contains(profile.id))
    }

    func testActiveProfileDoesNotKeepASelectorAggregate() {
        let profile = DeviceProfile(
            name: "Manual",
            outputDeviceUID: "physical-1",
            outputDeviceName: "Headphones"
        )
        XCTAssertFalse(ProfileRoutingDescriptor.visibleProfileIDs(
            profiles: [profile],
            activeProfileID: profile.id,
            defaultOutputUID: "physical-1"
        ).contains(profile.id))
    }
}
