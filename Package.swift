// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-textanchor",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TextAnchor", targets: ["TextAnchor"]),
        .library(name: "QuoteFind", targets: ["QuoteFind"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "TextAnchor"),
        .target(
            name: "QuoteFind",
            dependencies: [
                "TextAnchor",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "TextAnchorTests", dependencies: ["TextAnchor"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QuoteFindTests", dependencies: ["QuoteFind", "TextAnchor"], resources: [.copy("Fixtures")]),
    ]
)
