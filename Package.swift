// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SaewooFont",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SaewooFont", targets: ["SaewooFont"])
    ],
    targets: [
        .executableTarget(
            name: "SaewooFont",
            path: "Sources/SaewooFont"
        )
    ]
)
