// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ragmac",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // SQLiteSwiftCSQLite bundles sqlite3 compiled with SQLITE_ENABLE_LOAD_EXTENSION.
        // System libsqlite3 on macOS omits sqlite3_enable_load_extension.
        .package(
            url: "https://github.com/stephencelis/SQLite.swift",
            from: "0.15.0",
            traits: ["SQLiteSwiftCSQLite"]
        ),
    ],
    targets: [
        .target(
            name: "ragmacCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources/ragmacCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ragmac",
            dependencies: ["ragmacCore"],
            path: "Sources/ragmac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ragmacTests",
            dependencies: [
                "ragmacCore",
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Tests/ragmacTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
