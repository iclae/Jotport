import Foundation
import XCTest
@testable import JotportCore

final class RecentLaunchDirectoriesTests: XCTestCase {
    func testPersistentOrderingDedupBoundAndStaleFiltering() throws {
        let suite = "JotportMRUTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let paths = try (0..<10).map { i -> String in
            let url = root.appendingPathComponent("project-\(i)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath().path
        }
        let mru = RecentLaunchDirectories(preferences: defaults)
        for path in paths { mru.record(path) }
        XCTAssertEqual(mru.paths, Array(paths.reversed().prefix(8)))
        mru.record(paths[5] + "/./")
        XCTAssertEqual(mru.paths.first, paths[5])
        XCTAssertEqual(mru.paths.count, 8)
        XCTAssertEqual(Set(mru.paths).count, 8)
        XCTAssertEqual(RecentLaunchDirectories(preferences: try XCTUnwrap(UserDefaults(suiteName: suite))).paths, mru.paths)
        let before = defaults.stringArray(forKey: RecentLaunchDirectories.key)
        try FileManager.default.removeItem(atPath: paths[5])
        XCTAssertFalse(mru.paths.contains(paths[5]))
        XCTAssertEqual(defaults.stringArray(forKey: RecentLaunchDirectories.key), before, "Reading/dismissing recents must not write")
        mru.record(paths[5])
        XCTAssertEqual(defaults.stringArray(forKey: RecentLaunchDirectories.key), before)
        let file = root.appendingPathComponent("plain-file")
        try Data().write(to: file)
        mru.record(file.path)
        XCTAssertEqual(defaults.stringArray(forKey: RecentLaunchDirectories.key), before)
    }
}
