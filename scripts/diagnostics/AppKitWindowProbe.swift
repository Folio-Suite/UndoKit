// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit

// Standalone comparison for #68. No UndoKit, SwiftUI, persistence, or custom rendering.
@MainActor final class WindowProbe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    struct Event: Codable {
        let sequence: Int
        let time: Date
        let event: String
        let window: String?
        let text: String?
        let selectedLocation: Int?
        let selectedLength: Int?
        let editorFocused: Bool?
        let applicationActive: Bool
    }
    let output: URL
    var windows: [NSWindow] = []
    var editors: [NSTextView] = []
    var events: [Event] = []

    init(output: URL) { self.output = output }

    func record(_ name: String, window: NSWindow? = nil) {
        let index = window.flatMap { windows.firstIndex(of: $0) }
        let editor = index.map { editors[$0] }
        events.append(Event(sequence: events.count + 1, time: Date(), event: name,
            window: window?.title, text: editor?.string,
            selectedLocation: editor?.selectedRange().location,
            selectedLength: editor?.selectedRange().length,
            editorFocused: editor.map { window?.firstResponder === $0 }, applicationActive: NSApp.isActive))
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(events).write(to: output.appendingPathComponent("Events.json"), options: .atomic)
        } catch { fputs("Cannot retain probe evidence: \(error)\n", stderr); exit(EXIT_FAILURE) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let application = NSMenu(); item.submenu = application
        application.addItem(withTitle: "Quit Native Window Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        for index in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 120 + index * 440, y: 200, width: 420, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Native Window Probe \(index + 1)"; window.isReleasedWhenClosed = false
            let editor = NSTextView(frame: window.contentView!.bounds)
            editor.isRichText = false; editor.allowsUndo = true
            editor.autoresizingMask = [.width, .height]; editor.string = "Standalone AppKit editor \(index + 1)"
            window.contentView?.addSubview(editor)
            windows.append(window); editors.append(editor); window.delegate = self
            let entry = windowMenu.addItem(withTitle: window.title, action: #selector(selectWindow(_:)), keyEquivalent: String(index + 1))
            entry.target = self; entry.tag = index
        }
        NSApp.mainMenu = menu
        for window in windows { window.orderFront(nil) }
        select(0)
        NSApp.activate(ignoringOtherApps: true)
        record("launched")
    }
    func select(_ index: Int) {
        let window = windows[index]
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editors[index])
        record("selected-editor", window: window)
    }
    @objc func selectWindow(_ sender: NSMenuItem) { select(sender.tag) }
    func windowDidBecomeKey(_ notification: Notification) { record("window-key", window: notification.object as? NSWindow) }
    func windowDidResignKey(_ notification: Notification) { record("window-resigned", window: notification.object as? NSWindow) }
    func applicationDidBecomeActive(_ notification: Notification) { record("application-active", window: NSApp.keyWindow) }
    func applicationDidResignActive(_ notification: Notification) { record("application-inactive", window: NSApp.keyWindow) }
    func applicationWillTerminate(_ notification: Notification) { record("graceful-termination", window: NSApp.keyWindow) }
}

let arguments = CommandLine.arguments
if arguments.count == 2 && arguments[1] == "--help" {
    print("Usage: NativeWindowProbe --output NEW_DIRECTORY\nUse Window > Native Window Probe 1/2, switch to System Settings, return, then quit normally.")
    exit(EXIT_SUCCESS)
}
guard arguments.count == 3, arguments[1] == "--output" else {
    fputs("Expected --output NEW_DIRECTORY\n", stderr); exit(EXIT_FAILURE)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false) }
catch { fputs("Output must be a new directory with an existing parent: \(error)\n", stderr); exit(EXIT_FAILURE) }
let application = NSApplication.shared
let delegate = WindowProbe(output: output)
application.setActivationPolicy(.regular); application.delegate = delegate
application.run()
