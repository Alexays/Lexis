// swift-tools-version: 5.10
import PackageDescription

// The Rust core, as the Swift bindings UniFFI generates over its static
// library. `scripts/build-core.sh` writes every file under Sources and the
// xcframework beside them; nothing here is edited by hand.
let package = Package(
    name: "LexisCore",
    platforms: [.tvOS("27.0")],
    products: [
        .library(name: "LexisCore", targets: ["LexisCore"]),
    ],
    targets: [
        .binaryTarget(name: "LexisCoreBinary", path: "LexisCoreFramework.xcframework"),
        .target(name: "lexis_coreFFI", path: "Sources/lexis_coreFFI"),
        .target(
            name: "LexisCore",
            dependencies: ["lexis_coreFFI", "LexisCoreBinary"],
            path: "Sources/LexisCore",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
