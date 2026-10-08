// swift-tools-version:5.10
import PackageDescription
import Foundation

// The sherpa-onnx speech library and llama.cpp (the local language model that tidies
// dictation) are downloaded into Vendor/ by scripts/setup.sh.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLib = "\(root)/Vendor/sherpa-onnx/lib"

let package = Package(
    name: "ReadAloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "ReadAloud",
            dependencies: ["CSherpaOnnx", "llama", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ReadAloud",
            linkerSettings: [
                .unsafeFlags([
                    "-L", sherpaLib,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLib,
                ])
            ]
        ),
    ]
)
