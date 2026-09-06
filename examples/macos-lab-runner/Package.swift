// swift-tools-version: 5.9

import PackageDescription

// SwiftPM only, on purpose. The device-lab host has Xcode and a Swift
// toolchain but no XcodeGen and no Homebrew, and installing tooling there is
// not on the table, so the runner is built with `swift build` and bundled into
// a .app by scripts/bundle.sh. The bundle is what gives the process a stable
// identity for the one-time Bluetooth grant.
let package = Package(
    name: "BarnardLabRunner",
    // 12.0 is the floor the Barnard package declares (barnard#192): the
    // toolchain cannot build lower.
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "../../packages/swift/barnard")
    ],
    targets: [
        .executableTarget(
            name: "BarnardLabRunner",
            dependencies: [
                .product(name: "Barnard", package: "barnard"),
                // The spec 134 relay verifier protocol lives in BarnardCore, so
                // a host that supplies one links both products.
                .product(name: "BarnardCore", package: "barnard")
            ],
            path: "Sources/BarnardLabRunner"
        )
    ]
)
