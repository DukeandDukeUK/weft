// swift-tools-version: 6.0
// Weft — sorts one long Messages conversation into topic threads.
import PackageDescription

let package = Package(
    name: "Weft",
    // English is the development language; Sources/Weft/Resources holds the
    // string catalog every piece of text on screen comes from.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Weft", targets: ["Weft"])
    ],
    dependencies: [
        // Automatic updates for apps distributed outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Weft",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Weft",
            resources: [.process("Resources")],
            linkerSettings: [
                // Sparkle.framework ships inside Weft.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
        ,
        .testTarget(
            name: "WeftTests",
            dependencies: ["Weft"],
            path: "Tests/WeftTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
