// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "net-sentry",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "net-sentry", targets: ["net-sentry-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "NetSentry",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(
            name: "net-sentry-cli",
            dependencies: ["NetSentry"]
        ),
        .testTarget(
            name: "NetSentryTests",
            dependencies: ["NetSentry"]
        ),
    ]
)
