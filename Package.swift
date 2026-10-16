// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Strata", targets: ["Strata", "StrataObjC"]), .executable(name: "strata-tool", targets: ["StrataTool"])],
    targets: [

        .target(name: "StrataObjC", publicHeadersPath: "include"),
        .target(name: "Strata", dependencies: ["StrataObjC"]),
        .executableTarget(name: "StrataTool", dependencies: ["Strata"]),
        .testTarget(name: "StrataTests", dependencies: ["Strata"])
    ]
)
