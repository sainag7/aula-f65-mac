// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "F65", platforms: [.macOS(.v13)], products: [.executable(name: "F65Lighting", targets: ["F65Lighting"]), .library(name: "F65Kit", targets: ["F65Kit"])], targets: [.executableTarget(name: "F65Lighting", dependencies: ["F65Kit"]), .target(name: "F65Kit"), .testTarget(name: "F65KitTests", dependencies: ["F65Kit"], exclude: ["Fixtures"])])
