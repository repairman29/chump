// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChumpMenu",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ChumpMenu", targets: ["ChumpMenu"])],
    targets: [
        .executableTarget(
            name: "ChumpMenu",
            path: "Sources/ChumpMenu"
        )
    ]
)
