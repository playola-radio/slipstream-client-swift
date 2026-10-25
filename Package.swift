// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SlipstreamCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SlipstreamCore", targets: ["SlipstreamCore"]),
    .executable(name: "ask-evals", targets: ["AskEvals"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.7.3"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", exact: "1.1.1"),
  ],
  targets: [
    .target(
      name: "SlipstreamCore",
      dependencies: [.product(name: "IdentifiedCollections", package: "swift-identified-collections")]
    ),
    .executableTarget(name: "AskEvals", dependencies: ["SlipstreamCore"]),
    .testTarget(
      name: "SlipstreamCoreTests",
      dependencies: [
        "SlipstreamCore",
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
