// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pantrified",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "PantrifiedDomain", targets: ["PantrifiedDomain"]),
        .library(name: "PantrifiedApplication", targets: ["PantrifiedApplication"]),
        .library(name: "PantrifiedFoundationModels", targets: ["PantrifiedFoundationModels"]),
    ],
    targets: [
        .target(name: "PantrifiedDomain"),
        .target(name: "PantrifiedTestSupport"),
        .testTarget(
            name: "PantrifiedDomainTests",
            dependencies: ["PantrifiedDomain", "PantrifiedTestSupport"]
        ),
        .target(name: "PantrifiedApplication", dependencies: ["PantrifiedDomain"]),
        // Apple's on-device model behind the application layer's runtime capability. It is empty
        // where the FoundationModels framework does not exist, such as Linux.
        .target(name: "PantrifiedFoundationModels", dependencies: ["PantrifiedApplication", "PantrifiedDomain"]),
        .testTarget(
            name: "PantrifiedApplicationTests",
            dependencies: ["PantrifiedApplication", "PantrifiedDomain", "PantrifiedTestSupport"]
        ),
    ]
)
