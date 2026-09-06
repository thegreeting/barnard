// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// libsecp256k1 backend (issue #159). The vendored C target crashes the Linux
// SwiftPM build planner (swift-build Signal 11 during pre-planning, seen on the
// Linux-native/Android cross-compile lanes), so on Linux hosts BarnardCore is
// built without it and selects the pure-Swift backend; the dual-run test keeps
// both backends byte-identical.
#if os(Linux)
let libsecp256k1Targets: [Target] = []
let libsecp256k1Dependencies: [Target.Dependency] = []
let libsecp256k1SwiftSettings: [SwiftSetting] = []
#else
let libsecp256k1Targets: [Target] = [
        .target(
            name: "CSecp256k1",
            exclude: [
                "vendor/src/asm",
                "vendor/src/bench.c", "vendor/src/bench_ecmult.c",
                "vendor/src/bench_internal.c", "vendor/src/ctime_tests.c",
                "vendor/src/precompute_ecmult.c", "vendor/src/precompute_ecmult_gen.c",
                "vendor/src/secp256k1.c", "vendor/src/tests.c",
                "vendor/src/tests_exhaustive.c"
            ],
            cSettings: [.define("ENABLE_MODULE_RECOVERY")]
        )
]
let libsecp256k1Dependencies: [Target.Dependency] = ["CSecp256k1"]
let libsecp256k1SwiftSettings: [SwiftSetting] = [.define("BARNARD_LIBSECP256K1")]
#endif

let package = Package(
    name: "Barnard",
    platforms: [
        .iOS("14.0"),
        // 10.15 is the floor the code needs: CBManager.authorization, used by
        // the engine's Bluetooth permission check, is macOS 10.15+.
        .macOS("10.15")
    ],
    products: [
        .library(name: "Barnard", targets: ["Barnard"]),
        .library(name: "BarnardCore", targets: ["BarnardCore"]),
        // Dynamic on purpose: this is the .so/.dylib consumed over the C ABI
        // by non-Swift hosts (Kotlin/JNI on Android, C, ...). See issue #78.
        .library(name: "BarnardCoreC", type: .dynamic, targets: ["BarnardCoreC"])
    ],
    dependencies: [],
    targets: libsecp256k1Targets + [
        .target(
            name: "Barnard",
            dependencies: ["BarnardCore"],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "BarnardCore",
            dependencies: libsecp256k1Dependencies,
            // Explicit backend selection: mirrored builds without this define
            // (Flutter/CocoaPods) compile the pure-Swift path.
            swiftSettings: libsecp256k1SwiftSettings
        ),
        .target(
            name: "BarnardCoreC",
            dependencies: ["BarnardCore"]
        ),
        .testTarget(
            name: "BarnardTests",
            dependencies: ["Barnard"]
        ),
        .testTarget(
            name: "BarnardCoreTests",
            dependencies: ["BarnardCore"]
        ),
        .testTarget(
            name: "BarnardCoreCTests",
            dependencies: ["BarnardCore", "BarnardCoreC"]
        )
    ]
)
