// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import SwiftUI

@main
@MainActor struct DurableNotesSwiftUIApp: App {
    @StateObject private var registry = SwiftUINotesRegistry()

    var body: some Scene {
        WindowGroup {
            SwiftUINotesScene(registry: registry)
        }
    }
}
