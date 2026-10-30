// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pantrified",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "PantrifiedDomain", targets: ["PantrifiedDomain"]),
        .library(name: "PantrifiedApplication", targets: ["PantrifiedApplication"]),
    ],
    targets: [
        .target(name: "PantrifiedDomain"),
        .target(name: "PantrifiedTestSupport"),
        .testTarget(
            name: "PantrifiedDomainTests",
            dependencies: ["PantrifiedDomain", "PantrifiedTestSupport"]
        ),
        .target(name: "PantrifiedApplication", dependencies: ["PantrifiedDomain"]),
        .testTarget(
            name: "PantrifiedApplicationTests",
            dependencies: ["PantrifiedApplication", "PantrifiedDomain", "PantrifiedTestSupport"]
        ),
    ]
)
