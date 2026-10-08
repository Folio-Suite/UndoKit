// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "PackageProbe",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PackageProbe", targets: ["PackageProbe"])],
    targets: [
        .target(name: "PackageProbe"),
        .testTarget(name: "PackageProbeTests", dependencies: ["PackageProbe"])
    ],
    swiftLanguageModes: [.v6]
)
