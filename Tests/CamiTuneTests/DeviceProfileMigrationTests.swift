import XCTest
import CoreAudio
@testable import CamiTune

final class DeviceProfileMigrationTests: XCTestCase {
    func testLegacyRoutingProfileMigratesToSystemAudioBridge() throws {
        let json = """
        {
          "id": "F7F21A44-69C4-4EA8-B133-BBEE5B1080CB",
          "name": "Legacy route",
          "outputDeviceUID": "BlackHole2ch_UID",
          "outputDeviceName": "BlackHole 2ch",
          "autoActivate": false,
          "autoActivateWhenBlackHoleSelected": true
        }
        """

        let profile = try JSONDecoder().decode(DeviceProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.outputDeviceUID, AudioDeviceInfo.systemAudioBridgeUID)
        XCTAssertEqual(profile.outputDeviceName, AudioDeviceInfo.systemAudioBridgeName)
        XCTAssertTrue(profile.autoActivateWhenProfileDeviceSelected)

        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertTrue(encoded.contains("autoActivateWhenProfileDeviceSelected"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("blackhole"))
    }

    func testBlackHoleIsNotRecognizedAsRoutingDevice() {
        let oldDevice = AudioDeviceInfo(
            id: "BlackHole2ch_UID",
            objectID: 42,
            name: "BlackHole 2ch"
        )
        XCTAssertFalse(oldDevice.isRoutingDevice)
    }

    func testPreviousSystemAudioBridgeActivationKeyMigrates() throws {
        let json = """
        {
          "name": "Headphones",
          "outputDeviceUID": "physical-output",
          "outputDeviceName": "Headphones",
          "autoActivateWhenSystemAudioBridgeSelected": true
        }
        """

        let profile = try JSONDecoder().decode(DeviceProfile.self, from: Data(json.utf8))
        XCTAssertTrue(profile.autoActivateWhenProfileDeviceSelected)

        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertTrue(encoded.contains("autoActivateWhenProfileDeviceSelected"))
        XCTAssertFalse(encoded.contains("autoActivateWhenSystemAudioBridgeSelected"))
    }

    func testAggregateAndVirtualDevicesAreRejectedAsPlaybackTargets() {
        let aggregate = AudioDeviceInfo(
            id: "third-party-aggregate",
            objectID: 43,
            name: "Aggregate Device",
            transportType: kAudioDeviceTransportTypeAggregate
        )
        let virtual = AudioDeviceInfo(
            id: "third-party-virtual",
            objectID: 44,
            name: "Virtual Device",
            transportType: kAudioDeviceTransportTypeVirtual
        )

        XCTAssertTrue(aggregate.isRoutingDevice)
        XCTAssertTrue(virtual.isRoutingDevice)
    }

    func testMissingProfileEnabledValueMigratesToEnabled() throws {
        let json = """
        {
          "name": "Headphones",
          "outputDeviceUID": "physical-output",
          "outputDeviceName": "Headphones"
        }
        """

        let profile = try JSONDecoder().decode(DeviceProfile.self, from: Data(json.utf8))
        XCTAssertTrue(profile.isEnabled)
    }
}
