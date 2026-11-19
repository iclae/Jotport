// swift-tools-version: 5.7
import PackageDescription
let package = Package(name: "Jotport", platforms: [.macOS(.v12)], products: [.executable(name: "Jotport", targets: ["Jotport"])], targets: [.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]), .target(name: "JotportCore", dependencies: ["CSQLite"]), .executableTarget(name: "Jotport", dependencies: ["JotportCore"]), .testTarget(name: "JotportCoreTests", dependencies: ["JotportCore", "CSQLite"])])
