// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "NativeProof",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NativeProof", targets: ["NativeProof"])],
    targets: [
        .target(name: "NativeProofCore"),
        .executableTarget(name: "NativeProof", dependencies: ["NativeProofCore"]),
        .testTarget(name: "NativeProofCoreTests", dependencies: ["NativeProofCore"])
    ],
    swiftLanguageModes: [.v6]
)
