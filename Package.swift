// swift-tools-version: 6.0
import PackageDescription

// The shipped app is built from project.yml (XcodeGen + xcodebuild). This package holds the
// tested AuthCore library: OTP maths, import/export formats, vault and backup crypto.
// AuthCore has no third-party dependencies and never touches the network.
let package = Package(
    name: "MacAuth",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AuthCore", targets: ["AuthCore"]),
    ],
    targets: [
        .target(name: "AuthCore"),
        .testTarget(name: "AuthCoreTests", dependencies: ["AuthCore"]),
    ],
    swiftLanguageModes: [.v5]
)
