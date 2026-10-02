// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhDownload",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EhDownload", targets: ["EhDownload"]),
    ],
    dependencies: [
        .package(path: "../EhCore"),
        .package(path: "../EhSpider"),
        .package(path: "../EhNetwork"),
    ],
    targets: [
        .target(
            name: "EhDownload",
            dependencies: [
                .product(name: "EhModels", package: "EhCore"),
                .product(name: "EhDatabase", package: "EhCore"),
                .product(name: "EhSettings", package: "EhCore"),
                .product(name: "EhSpider", package: "EhSpider"),
                .product(name: "EhBackgroundTransport", package: "EhNetwork"),
            ],
            path: "Sources"
        ),
    ]
)
