// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import DurableNotesCore
import SwiftUI
import UndoKit
import XCTest

@MainActor final class NotesSwiftUIAppKitTests: XCTestCase {
    @MainActor final class EditorOwner {
        let editor = NativeHistoryAppKitTextView()
        var attachment: HistoryAttachment?
        init() { editor.isRichText = false; editor.allowsUndo = true }
    }

    private struct EditorHost: View {
        private let editorReference: WeakEditor
        let generation: Int
        init(editor: NativeHistoryAppKitTextView, generation: Int) {
            editorReference = WeakEditor(editor)
            self.generation = generation
        }
        private final class WeakEditor {
            weak var value: NativeHistoryAppKitTextView?
            init(_ value: NativeHistoryAppKitTextView) { self.value = value }
        }
        var body: some View {
            if let editor = editorReference.value {
                NativeHistorySwiftUIEditor(textView: editor)
                    .id(generation)
                    .frame(width: 420, height: 180)
            }
        }
    }

    func testSwiftUIRepresentableRemountPreservesLiveUndoAndReopensAcceptedReceiptOnce() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: sessions, mode: .create)
        let owner = EditorOwner()
        owner.attachment = try session.attach(owner: owner)
        let binding = try await owner.attachment!.bindAppKit(editors: [(owner.editor, try lease.field(.body, in: session))])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: EditorHost(editor: owner.editor, generation: 0))
        hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        window.makeFirstResponder(owner.editor)
        XCTAssertTrue(owner.editor.window === window,
            "The initial SwiftUI host must materialize the owner's native editor")

        let nativeManager = try XCTUnwrap(owner.editor.undoManager)
        nativeManager.groupsByEvent = false
        nativeManager.beginUndoGrouping()
        owner.editor.insertText("Alpha", replacementRange: NSRange(location: 0, length: 0))
        nativeManager.endUndoGrouping()
        let beforeRebuild = try await lease.read()
        XCTAssertEqual(beforeRebuild.applicationCount, 0)
        XCTAssertTrue(nativeManager.canUndo)

        // Changing the explicit identity forces SwiftUI to dismantle and recreate the represented NSView host.
        hosting.rootView = EditorHost(editor: owner.editor, generation: 1)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(owner.editor.window === window,
            "SwiftUI remount must present owner's editor; window=\(String(describing: owner.editor.window)), superview=\(String(describing: owner.editor.superview)), visible=\(window.isVisible), hostChildren=\(hosting.subviews)")
        XCTAssertTrue(owner.editor.undoManager === nativeManager, "SwiftUI remount must retain the native manager")
        XCTAssertEqual(owner.editor.string, "Alpha")
        let afterRemount = try await lease.read()
        XCTAssertEqual(afterRemount.applicationCount, 0,
            "SwiftUI host reconstruction must not deliver or settle the live draft")
        XCTAssertTrue(nativeManager.canUndo, "SwiftUI remount must preserve native Undo")
        nativeManager.undo()
        XCTAssertEqual(owner.editor.string, "")
        XCTAssertTrue(nativeManager.canRedo, "Native Redo must remain available at the baseline")
        nativeManager.redo()
        XCTAssertEqual(owner.editor.string, "Alpha")
        let afterNativeUndoRedo = try await lease.read()
        XCTAssertEqual(afterNativeUndoRedo.applicationCount, 0)

        _ = await binding.commit()
        let accepted = try await lease.read()
        XCTAssertEqual(accepted.note, Note(body: "Alpha"))
        XCTAssertEqual(accepted.applicationCount, 1)
        XCTAssertEqual(accepted.receiptCount, 1)
        let receiptBytes = try Data(contentsOf: directory.appendingPathComponent("Note.json"))

        await binding.close()
        binding.disconnect()
        let reopenedLease = NotesDocumentLease(directory: directory)
        let reopenedSession = await reopenedLease.openSession(in: sessions, mode: .existing)
        let reopened = try await reopenedLease.read()
        XCTAssertEqual(reopened.note, accepted.note)
        XCTAssertEqual(reopened.applicationCount, accepted.applicationCount)
        XCTAssertEqual(reopened.receiptCount, accepted.receiptCount)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), receiptBytes,
            "Reopen must restore the accepted host receipt without replaying its effect")
        await reopenedSession.close()
        XCTAssertEqual(reopenedSession.status.phase, .closed)
    }

    func testSwiftUIWindowDisposalReleasesPresentationDuringBlockedRecovery() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: sessions, mode: .create)
        var owner: EditorOwner? = autoreleasepool { EditorOwner() }
        weak let weakOwner = owner
        weak let weakEditor = owner?.editor
        owner!.attachment = try session.attach(owner: owner!)
        var binding: NativeHistoryAppKitBinding? = try await owner!.attachment!.bindAppKit(editors: [(owner!.editor, try lease.field(.body, in: session))])
        weak let weakBinding = binding
        var window: NSWindow?
        var hosting: NSHostingView<EditorHost>?
        autoreleasepool {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                styleMask: [.titled], backing: .buffered, defer: false)
            window!.isReleasedWhenClosed = false
            hosting = NSHostingView(rootView: EditorHost(editor: owner!.editor, generation: 0))
            window!.contentView = hosting
            window!.makeKeyAndOrderFront(nil)
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(owner!.editor.window === window)
        var evidence: NSObject? = NSObject()
        weak let weakEvidence = evidence
        binding!.undoManager.registerUndo(withTarget: evidence!) { [evidence] _ in
            _ = evidence; XCTFail("Unrecognized work must not execute")
        }
        evidence = nil
        autoreleasepool {
            binding!.disconnect()
            binding = nil
            window!.contentView = nil
            window!.close()
            hosting = nil
            window = nil
            owner = nil
        }
        try await Task.sleep(for: .milliseconds(120))
        // AppKit may retire a detached NSTextView on a later native event turn.
        // Poll a bounded weak probe rather than asserting at an arbitrary short delay.
        for _ in 0..<100 {
            if weakEditor == nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertNil(weakOwner)
        XCTAssertNil(weakBinding)
        XCTAssertNil(weakEditor, "A dismantled SwiftUI host must not retain the native editor")
        await session.close()
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertNotNil(session.configuration)
        XCTAssertNotNil(weakEvidence)
        XCTAssertTrue(sessions.session(for: directory) === session)
        try await session.reconcileNativeRegistrations()
        XCTAssertNil(weakEvidence)
        await session.close()
        XCTAssertEqual(session.status.phase, .closed)
    }

    func testTemporaryEditorDetachmentPreservesLiveNativeHistoryUntilExplicitSettlement() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        let owner = EditorOwner()
        owner.attachment = try session.attach(owner: owner)
        let binding = try await owner.attachment!.bindAppKit(editors: [(owner.editor, try lease.field(.body, in: session))])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let firstContainer = NSView(frame: window.contentView!.bounds)
        let secondContainer = NSView(frame: window.contentView!.bounds)
        window.contentView = firstContainer
        owner.editor.frame = firstContainer.bounds
        firstContainer.addSubview(owner.editor)
        window.makeFirstResponder(owner.editor)
        let manager = try XCTUnwrap(owner.editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        owner.editor.insertText("Alpha", replacementRange: NSRange(location: 0, length: 0))
        manager.endUndoGrouping()
        XCTAssertTrue(binding.hasLiveTransaction)
        let beforeDetach = try await lease.read()
        XCTAssertEqual(beforeDetach.applicationCount, 0)

        // SwiftUI may detach a represented view while rebuilding its host hierarchy.
        owner.editor.removeFromSuperview()
        secondContainer.addSubview(owner.editor)
        window.contentView = secondContainer
        window.makeFirstResponder(owner.editor)
        await binding.waitForOperations()

        let afterDetach = try await lease.read()
        XCTAssertEqual(afterDetach.applicationCount, 0,
            "A temporary SwiftUI host reconstruction must not settle the editing transaction")
        XCTAssertTrue(manager.canUndo, "Detachment must preserve native Undo callbacks")
        manager.undo()
        XCTAssertEqual(owner.editor.string, "")
        XCTAssertTrue(manager.canRedo, "Redo at the baseline must remain native after detachment")
        manager.redo()
        XCTAssertEqual(owner.editor.string, "Alpha")
        let afterNativeUndoRedo = try await lease.read()
        XCTAssertEqual(afterNativeUndoRedo.applicationCount, 0)

        _ = await binding.commit()
        let afterCommit = try await lease.read()
        XCTAssertEqual(afterCommit.applicationCount, 1,
            "Only explicit settlement should deliver the durable transaction")
        binding.disconnect(); await session.close()
    }

    func testOverlappingSwiftUIPresentationsPromoteFirstSurvivingHostWithoutStealingEditor() async throws {
        _ = NSApplication.shared
        let editor = NativeHistoryAppKitTextView()
        editor.isRichText = false
        let firstWindow = makeWindow(editor: editor, generation: 0)
        let removedWaiterWindow = makeWindow(editor: editor, generation: 1)
        let survivingWaiterWindow = makeWindow(editor: editor, generation: 2)
        defer {
            firstWindow.contentView = nil
            removedWaiterWindow.contentView = nil
            survivingWaiterWindow.contentView = nil
            firstWindow.close(); removedWaiterWindow.close(); survivingWaiterWindow.close()
        }

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(editor.window === firstWindow, "The first mounted host must own the editor")
        XCTAssertTrue(editor.superview != nil)

        removedWaiterWindow.contentView = nil
        firstWindow.contentView = nil
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(editor.window === survivingWaiterWindow,
            "Detaching the current host must promote the first surviving waiter")

        survivingWaiterWindow.contentView = nil
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(editor.window, "Removing the current host must release its native presentation")

        let externalWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        let externalParent = NSView(frame: externalWindow.contentView!.bounds)
        externalWindow.contentView = externalParent
        externalParent.addSubview(editor)
        let attemptedSteal = makeWindow(editor: editor, generation: 3)
        defer { attemptedSteal.contentView = nil; attemptedSteal.close(); externalWindow.close() }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(editor.superview === externalParent,
            "SwiftUI presentation must not reparent an editor already owned by native hierarchy")
        XCTAssertTrue(editor.window === externalWindow)
    }

    private func makeWindow(editor: NativeHistoryAppKitTextView, generation: Int) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: EditorHost(editor: editor, generation: generation))
        hosting.frame = window.contentView!.bounds
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        return window
    }
}
