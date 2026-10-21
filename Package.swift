// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Marmalade",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Marmalade", path: "Sources/Marmalade")
    ]
)
