// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Absolute, so it does not depend on the directory swift test runs from. The
// dylib is what `cargo build` writes in core/ (or under CARGO_TARGET_DIR when
// set, as cargo does); its install name is absolute, so the test bundle needs
// no rpath to find it again at run time.
let coreTarget = ProcessInfo.processInfo.environment["CARGO_TARGET_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("core/target")
let coreLibrary = coreTarget.appendingPathComponent("debug").path

let package = Package(
    name: "LexisPlayer",
    platforms: [.macOS("27.0"), .tvOS("27.1")],
    products: [
        .library(name: "LexisPlayer", targets: ["LexisPlayer"]),
        .library(name: "LexisTestSupport", targets: ["LexisTestSupport"]),
        .library(name: "LexisCoreStream", targets: ["LexisCoreStream"]),
    ],
    targets: [
        .binaryTarget(name: "FFmpeg", path: "Vendor/FFmpeg.xcframework"),
        .binaryTarget(name: "LibASS", path: "Vendor/LibASS.xcframework"),
        .target(name: "CFFmpeg", dependencies: ["FFmpeg"], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CLibass", dependencies: ["LibASS"]),
        // The core's stream ABI. Only the tests link it: the player library
        // must keep working without the core, which is what the spec asks for.
        .systemLibrary(name: "CLexisStream", path: "Sources/CLexisStream"),
        // Prisme.lxsr: the scaler's filters, learned against true 4K;
        // PrismeNet.mlmodelc: the network that can double the luma in their place;
        // zones.txt: each tz zone's city, from the tz database's zone.tab
        .target(
            name: "LexisPlayer", dependencies: ["CFFmpeg", "CLibass"],
            resources: [
                .copy("Resources/Prisme.lxsr"),
                .copy("Resources/PrismeNet.mlmodelc"), .copy("Resources/zones.txt"),
            ]),
        // The core's ABI as a MediaStreamIO. Whoever links this links the core
        // too; LexisPlayer deliberately does not.
        .target(name: "LexisCoreStream", dependencies: ["LexisPlayer", "CLexisStream"]),
        // Optimised even in a debug build: this target only synthesises
        // fixtures, and the per-pixel noise fill it does for them costs
        // minutes of the suite's wall clock when built unoptimised. The
        // bytes it produces are the same either way.
        .target(
            name: "LexisTestSupport",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "LexisPlayerTests",
            dependencies: ["LexisPlayer", "LexisCoreStream", "LexisTestSupport", "CLexisStream"],
            linkerSettings: [.unsafeFlags(["-L\(coreLibrary)", "-llexis_core"])]
        ),
    ]
)
