// swift-tools-version: 6.0
import PackageDescription

// Platforms are deliberately limited to the two that CI actually compiles:
// - iOS: built by the companion demo repo's `macos-15` job for `generic/platform=iOS Simulator`.
// - macOS: built by this repo's `macos-15` job (`swift build` / `swift test`), which is the
//   only job that compiles `CardinalityGovernorUI` against a real SwiftUI.
// Declaring watchOS/tvOS here would be a claim nothing verifies — and watchOS in particular
// has a 32-bit `Int`, which changes the arithmetic-saturation ceilings this module derives
// from `Int.max`. If a platform is added, a CI job must be added in the same commit.
let package = Package(
    name: "CardinalityGovernor",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CardinalityGovernor", targets: ["CardinalityGovernor"]),
        .library(name: "CardinalityGovernorUI", targets: ["CardinalityGovernorUI"]),
    ],
    targets: [
        // Pure Swift + Foundation. No MetricKit, no SwiftUI, no ML weights — which is what
        // makes the whole governor runnable (and CI-verifiable) on Linux.
        .target(name: "CardinalityGovernor"),
        // SwiftUI surface. Every declaration is inside `#if canImport(SwiftUI)`, so on Linux
        // this compiles to an empty module rather than failing the build.
        .target(name: "CardinalityGovernorUI", dependencies: ["CardinalityGovernor"]),
        .testTarget(name: "CardinalityGovernorTests", dependencies: ["CardinalityGovernor"]),
    ]
)
