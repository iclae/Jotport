import Foundation

/// Only Jotport-accepted paths; never reads Finder/global recent documents.
public final class RecentLaunchDirectories {
    public static let key = "recentLaunchDirectories"
    public static let limit = 8
    private let preferences: UserDefaults

    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    public static func isAvailable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue && FileManager.default.isReadableFile(atPath: path) && FileManager.default.isExecutableFile(atPath: path)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Filtering does not mutate preferences: dismissing a picker is a no-op.
    public var paths: [String] {
        var seen = Set<String>()
        return Array((preferences.stringArray(forKey: Self.key) ?? []).filter(Self.isAvailable).map(canonical).filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    public func record(_ path: String) {
        guard Self.isAvailable(path) else { return }
        let path = canonical(path)
        preferences.set(Array(([path] + paths.filter { $0 != path }).prefix(Self.limit)), forKey: Self.key)
    }
}
