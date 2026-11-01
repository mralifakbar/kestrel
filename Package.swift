// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kestrel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KestrelApp", targets: ["KestrelApp"]),
        .executable(name: "kestrel", targets: ["kestrel"]),
        .executable(name: "KestrelHelper", targets: ["KestrelHelper"]),
    ],
    targets: [
        .target(
            name: "CKestrel",
            linkerSettings: [.linkedLibrary("IOReport"), .linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "KestrelCore",
            dependencies: ["CKestrel"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security"), .linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "KestrelApp", dependencies: ["KestrelCore"]),
        .executableTarget(name: "kestrel", dependencies: ["KestrelCore"]),
        .executableTarget(name: "KestrelHelper", dependencies: ["CKestrel"]),
        .testTarget(name: "KestrelCoreTests", dependencies: ["KestrelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
