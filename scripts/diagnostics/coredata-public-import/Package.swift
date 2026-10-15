// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "CoreDataPublicImportReproducer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CoreDataPublicImportReproducer",
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageModes: [.v6]
)
