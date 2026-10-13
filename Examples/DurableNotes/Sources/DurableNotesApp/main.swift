// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import AppKit
import DurableNotesCore

@MainActor final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NotesWindowController] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        Task { @MainActor in
            do {
                let root = try dataRoot()
                let a = try await NotesWindowController.open(at: root.appendingPathComponent("Document-A"), name: "Note A")
                let b = try await NotesWindowController.open(at: root.appendingPathComponent("Document-B"), name: "Note B")
                windows = [a, b]
                a.window?.setFrameOrigin(NSPoint(x: 100, y: 180))
                b.window?.setFrameOrigin(NSPoint(x: 760, y: 180))
                a.showWindow(nil); b.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                if CommandLine.arguments.contains("--native-check") {
                    try await NativeChecks.run(a: a, b: b, root: root)
                    try await a.session.close(); try await b.session.close()
                    exit(EXIT_SUCCESS)
                }
            } catch {
                NSLog("Durable Notes failed: %@", String(describing: error))
                if CommandLine.arguments.contains("--native-check") {
                    if let root = try? dataRoot() {
                        try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("NativeFailure.txt"))
                    }
                    exit(EXIT_FAILURE)
                }
                let alert = NSAlert(); alert.messageText = "Cannot open durable note"
                alert.informativeText = String(describing: error); alert.runModal()
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            do {
                // Settle every editor before closing any session.
                guard windows.allSatisfy({ $0.settleEditing() }) else {
                    terminating = false; sender.reply(toApplicationShouldTerminate: false); return
                }
                for controller in windows {
                    await controller.waitForOperations()
                    try await controller.session.close()
                }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false; sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert(); alert.messageText = "Note closure requires attention"
                alert.informativeText = String(describing: error); alert.runModal()
            }
        }
        return .terminateLater
    }
    private func dataRoot() throws -> URL {
        if let supplied = ProcessInfo.processInfo.environment["UNDOKIT_NOTES_ROOT"] {
            return URL(fileURLWithPath: supplied, isDirectory: true)
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("UndoKit-DurableNotes", isDirectory: true)
    }
    private func installMenus() {
        let main = NSMenu()
        let application = NSMenuItem(); main.addItem(application)
        let appMenu = NSMenu(); application.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Durable Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); main.addItem(edit)
        let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = NotesAppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
