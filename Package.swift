// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CMDCIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CMDCIsland",
            path: "Sources/CMDCIsland"
        )
    ]
)
