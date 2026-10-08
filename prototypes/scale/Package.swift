// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ScaleProbe",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ScaleProbe", targets: ["ScaleProbe"])],
    targets: [
        .target(name: "ScaleProbe"),
        .executableTarget(name: "ScaleChild", dependencies: ["ScaleProbe"]),
        .testTarget(name: "ScaleProbeTests", dependencies: ["ScaleProbe"])
    ],
    swiftLanguageModes: [.v6]
)
