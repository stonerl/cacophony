// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cacophony",
    platforms: [.macOS("27.0")],
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
        .executableTarget(
            name: "cacophony",
            dependencies: ["CacophonyRouting", "CacophonyProtocol"],
            path: "Sources/Cacophony"
        ),
    ]
)
