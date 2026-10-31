// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pantrified",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "PantrifiedDomain", targets: ["PantrifiedDomain"]),
        .library(name: "PantrifiedApplication", targets: ["PantrifiedApplication"]),
        .library(name: "PantrifiedFoodDataCentral", targets: ["PantrifiedFoodDataCentral"]),
        .library(name: "PantrifiedFoundationModels", targets: ["PantrifiedFoundationModels"]),
        .library(name: "PantrifiedGuidanceData", targets: ["PantrifiedGuidanceData"]),
        .library(name: "PantrifiedPersistence", targets: ["PantrifiedPersistence"]),
    ],
    targets: [
        .target(name: "PantrifiedDomain"),
        // Shared by the test targets: seeded randomness, permutations and storage fault injection.
        .target(name: "PantrifiedTestSupport", dependencies: ["PantrifiedPersistence", "PantrifiedApplication", "PantrifiedDomain"]),
        .testTarget(
            name: "PantrifiedDomainTests",
            dependencies: ["PantrifiedDomain", "PantrifiedTestSupport"]
        ),
        .target(name: "PantrifiedApplication", dependencies: ["PantrifiedDomain"]),
        // Apple's on-device model behind the application layer's runtime capability. It is empty
        // where the FoundationModels framework does not exist, such as Linux.
        .target(name: "PantrifiedFoundationModels", dependencies: ["PantrifiedApplication", "PantrifiedDomain"]),
        // USDA FoodData Central behind the application layer's product lookup capability. Its
        // handling of each answer is tested without a network.
        .target(name: "PantrifiedFoodDataCentral", dependencies: ["PantrifiedApplication", "PantrifiedDomain"]),
        .testTarget(
            name: "PantrifiedFoodDataCentralTests",
            dependencies: ["PantrifiedFoodDataCentral", "PantrifiedApplication", "PantrifiedDomain"]
        ),
        // The bundled USDA FoodKeeper snapshot, regenerated from Data/FoodKeeper by
        // Scripts/normalize-foodkeeper.py.
        .target(
            name: "PantrifiedGuidanceData",
            dependencies: ["PantrifiedDomain"],
            resources: [.copy("Resources/foodkeeper.normalized.json")]
        ),
        .testTarget(
            name: "PantrifiedGuidanceDataTests",
            dependencies: ["PantrifiedGuidanceData", "PantrifiedApplication", "PantrifiedDomain"]
        ),
        // Durable local storage behind the application layer's repositories. The row mapping is
        // plain Swift and builds everywhere; the SwiftData backend is empty where SwiftData does not
        // exist, such as Linux.
        .target(name: "PantrifiedPersistence", dependencies: ["PantrifiedApplication", "PantrifiedDomain"]),
        .testTarget(
            name: "PantrifiedPersistenceTests",
            dependencies: ["PantrifiedPersistence", "PantrifiedApplication", "PantrifiedDomain", "PantrifiedTestSupport"]
        ),
        .testTarget(
            name: "PantrifiedApplicationTests",
            dependencies: ["PantrifiedApplication", "PantrifiedDomain", "PantrifiedPersistence", "PantrifiedTestSupport"]
        ),
    ]
)
