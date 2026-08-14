import XCTest
@testable import CamiTune

final class CamiTunePathsTests: XCTestCase {
    func testLegacySupportMigrationMergesMissingFilesWithoutOverwritingCurrentData() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CamiTunePathsTests-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("CamillaApp", isDirectory: true)
        let current = root.appendingPathComponent("CamiTune", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: legacy.appendingPathComponent("configs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: current.appendingPathComponent("configs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("legacy profile".utf8).write(to: legacy.appendingPathComponent("profiles.json"))
        try Data("legacy config".utf8).write(
            to: legacy.appendingPathComponent("configs/active.yml")
        )
        try Data("current config".utf8).write(
            to: current.appendingPathComponent("configs/active.yml")
        )

        CamiTunePaths.migrateLegacySupportDirectory(
            from: legacy,
            to: current,
            fileManager: fileManager
        )

        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("profiles.json")),
            "legacy profile"
        )
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("configs/active.yml")),
            "current config"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: legacy.path))
    }
}
