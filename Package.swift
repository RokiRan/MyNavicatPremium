// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyNavicat",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "MyNavicatCore", targets: ["MyNavicatCore"]),
        .executable(name: "MyNavicat", targets: ["MyNavicat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "MyNavicatCore",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            path: "Sources/MyNavicatCore"
        ),
        .executableTarget(
            name: "MyNavicat",
            dependencies: ["MyNavicatCore"],
            path: "Sources/MyNavicat"
        ),
        .testTarget(
            name: "MyNavicatCoreTests",
            dependencies: ["MyNavicatCore"],
            path: "Tests/MyNavicatCoreTests"
        ),
    ]
)
