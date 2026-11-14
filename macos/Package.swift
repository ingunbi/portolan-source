// swift-tools-version:5.9
import PackageDescription

// The SwiftUI/Metal app for macOS. The rules are in core/ (a Swift package of its own).
let package = Package(
    name: "portolan-mac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(name: "Portolan", dependencies: [.product(name: "PortolanCore", package: "core")]),
    ]
)
