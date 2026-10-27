// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ChildrenOfTasks",
    platforms: [
        .iOS("16.4"),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ChildrenOfTasks", targets: ["ChildrenOfTasks"])
    ],
    targets: [
        .target(
            name: "ChildrenOfTasks",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "ChildrenOfTasksTests",
            dependencies: ["ChildrenOfTasks"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
