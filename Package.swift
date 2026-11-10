// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchBarEnhancer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TouchBarEnhancer", targets: ["TouchBarEnhancer"])],
    targets: [
        .target(name: "TouchBarBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "TouchBarEnhancer", dependencies: ["TouchBarBridge"])
    ]
)
