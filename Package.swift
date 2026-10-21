// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cacophony",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "CacophonyRouting",
            path: "Sources/CacophonyRouting",
            publicHeadersPath: ".",
            cSettings: [
                // Hand-rolled objc_msgSend calls to init-family selectors are
                // incompatible with ARC's retain/release bookkeeping.
                .unsafeFlags(["-fno-objc-arc"])
            ]
        ),
        .target(
            name: "CacophonyProtocol",
            path: "Sources/CacophonyProtocol",
            publicHeadersPath: "."
        ),
        .target(
            name: "CacophonyHelperProtocol",
            path: "Sources/CacophonyHelperProtocol"
        ),
        .executableTarget(
            name: "CacophonyHelper",
            dependencies: ["CacophonyHelperProtocol"],
            path: "Sources/CacophonyHelper"
        ),
        .executableTarget(
            name: "cacophony",
            dependencies: ["CacophonyRouting", "CacophonyProtocol", "CacophonyHelperProtocol"],
            path: "Sources/Cacophony"
        ),
    ]
)
