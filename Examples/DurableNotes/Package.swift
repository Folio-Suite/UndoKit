// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "DurableNotes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "DurableNotesCore", targets: ["DurableNotesCore"]),
               .executable(name: "DurableNotesApp", targets: ["DurableNotesApp"])],
    dependencies: [.package(name: "UndoKit", path: "../..")],
    targets: [
        .target(name: "DurableNotesCore", dependencies: [.product(name: "UndoKit", package: "UndoKit")]),
        .executableTarget(name: "DurableNotesApp", dependencies: ["DurableNotesCore"]),
        .testTarget(name: "DurableNotesCoreTests", dependencies: ["DurableNotesCore"])
    ],
    swiftLanguageModes: [.v6]
)
