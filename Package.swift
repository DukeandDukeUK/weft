// swift-tools-version: 6.0
// Weft — sorts one long Messages conversation into topic threads.
import PackageDescription

let package = Package(
    name: "Weft",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Weft", targets: ["Weft"])
    ],
    targets: [
        .executableTarget(
            name: "Weft",
            path: "Sources/Weft"
        )
    ],
    swiftLanguageModes: [.v5]
)
