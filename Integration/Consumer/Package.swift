// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ChildrenOfTasksConsumer",
    platforms: [.iOS("16.4"), .macOS(.v13)],
    dependencies: [.package(name: "ChildrenOfTasks", path: "../..")],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "ChildrenOfTasks", package: "ChildrenOfTasks")],
            swiftSettings: [.treatAllWarnings(as: .error)]
        )
    ],
    swiftLanguageModes: [.v6]
)
