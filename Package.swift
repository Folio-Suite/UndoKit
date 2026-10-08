// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "UndoKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UndoKit", targets: ["UndoKit"])],
    targets: [
        .target(name: "UndoKit", path: "UndoKit", resources: [.process("Resources")]),
        .testTarget(name: "UndoKitTests", dependencies: ["UndoKit"], path: "UndoKitTests")
    ],
    swiftLanguageModes: [.v6]
)
