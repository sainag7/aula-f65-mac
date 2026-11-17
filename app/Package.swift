// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "F65", platforms: [.macOS(.v13)], products: [.library(name: "F65Kit", targets: ["F65Kit"])], targets: [.target(name: "F65Kit"), .testTarget(name: "F65KitTests", dependencies: ["F65Kit"])])
