// swift-tools-version:5.10
import PackageDescription
import Foundation

// Native libraries built by scripts/setup.sh into Vendor/sherpa-onnx-asr: sherpa-onnx
// compiled without text-to-speech (so without eSpeak NG), used for dictation, and the
// ONNX Runtime it ships with, which also runs the Kokoro voice and the G2P model.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeLib = "\(root)/Vendor/sherpa-onnx-asr/lib"

let package = Package(
    name: "ReadAloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        .target(
            name: "COrt",
            path: "Sources/COrt",
            linkerSettings: [.linkedLibrary("onnxruntime")]
        ),
        // Text → Kokoro phonemes (a port of misaki, by way of MisakiSwift).
        .target(
            name: "Phonemizer",
            dependencies: ["COrt"],
            path: "Sources/Phonemizer",
            exclude: ["LICENSE-MisakiSwift.txt"]
        ),
        .executableTarget(
            name: "ReadAloud",
            dependencies: ["CSherpaOnnx", "COrt", "Phonemizer", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ReadAloud",
            linkerSettings: [
                .unsafeFlags([
                    "-L", nativeLib,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", nativeLib,
                ])
            ]
        ),
    ]
)
