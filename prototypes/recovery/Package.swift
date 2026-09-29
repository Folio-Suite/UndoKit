// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "RecoveryProbe",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RecoveryProbe", targets: ["RecoveryProbe"])],
    targets: [
        .target(name: "RecoveryProbe"),
        .executableTarget(name: "RecoveryChild", dependencies: ["RecoveryProbe"]),
        .testTarget(name: "RecoveryProbeTests", dependencies: ["RecoveryProbe"])
    ],
    swiftLanguageModes: [.v6]
)
