// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pantrified",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "PantrifiedDomain", targets: ["PantrifiedDomain"]),
    ],
    targets: [
        .target(name: "PantrifiedDomain"),
        .testTarget(name: "PantrifiedDomainTests", dependencies: ["PantrifiedDomain"]),
    ]
)
