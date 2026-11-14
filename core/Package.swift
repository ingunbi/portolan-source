// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "portolan-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The rules engine the Apple apps link against.
        .library(name: "PortolanCore", targets: ["PortolanCore"]),
        // The same rules as a child process speaking JSON lines (the Android app runs this).
        .executable(name: "PortolanEngine", targets: ["PortolanEngine"]),
        .executable(name: "PortolanValidate", targets: ["PortolanValidate"]),
        .executable(name: "PortolanReplay", targets: ["PortolanReplay"]),
        .executable(name: "PortolanSaveProbe", targets: ["PortolanSaveProbe"]),
    ],
    targets: [
        .target(name: "PortolanCore"),
        .executableTarget(name: "PortolanEngine", dependencies: ["PortolanCore"]),
        .executableTarget(name: "PortolanValidate", dependencies: ["PortolanCore"]),
        .executableTarget(name: "PortolanReplay", dependencies: ["PortolanCore"]),
        .executableTarget(name: "PortolanSaveProbe", dependencies: ["PortolanCore"]),
        .testTarget(name: "PortolanCoreTests", dependencies: ["PortolanCore"]),
    ]
)
