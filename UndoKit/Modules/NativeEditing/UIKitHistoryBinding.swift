// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

/// UIKit presentation attachment. The app's session collection owns recovery resources.
@MainActor public final class NativeHistoryUIKitBinding<Lease: NativeHistoryLease>: NSObject, UITextViewDelegate {
    let session: NativeHistorySession<Lease>
    var controls: [UIKitHistoryControl] = []
    var localControls: [UIKitHistoryControl] = []
    var connection: NativeHistoryConnection?
    var capture: (() -> NativeDraftCapture<Lease.Draft>?)?
    var present: ((Lease.Draft) -> Void)?
    var presentStatus: ((NativeHistoryStatus) -> Void)?
    var operation: Task<HistoryResult, Never>?
    var pending = false
    var disconnected = false
    var rendering = false
    var liveTransaction = false
    var deferredBoundary = false
    var pendingSwiftUIEditingEnd: (() -> Void)?
    var participants: Set<ObjectIdentifier> = []
    var observers: [NSObjectProtocol] = []
    let actionName: String
    lazy var toolbarFacade = UIKitHistoryUndoManager(owner: self, registrationManager: session.undoManager)
    public var undoManager: UndoManager { toolbarFacade }
    public var status: NativeHistoryStatus { session.status }
    public var hasLiveTransaction: Bool { liveTransaction }
    public internal(set) var lastResult: HistoryResult?
    /// Platform availability, such as protected data. This does not release document ownership.
    public var isAvailable = true { didSet { if oldValue != isAvailable { publishAvailability() } } }

    init<Owner: AnyObject>(session: NativeHistorySession<Lease>, owner: Owner,
        editors: [NativeHistoryTextView], localEditors: [UITextView], actionName: String,
        captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)?
    ) throws {
        self.session = session; self.actionName = actionName
        super.init()
        guard !editors.isEmpty, Set(editors.map(ObjectIdentifier.init)).count == editors.count,
              !localEditors.contains(where: { local in editors.contains(where: { $0 === local }) }),
              editors.allSatisfy({ $0.historyFacade == nil }) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        capture = { [weak owner] in owner.flatMap(captureDraft) }
        present = { [weak owner] value in if let owner { draftDidChange(owner, value) } }
        presentStatus = { [weak owner] value in if let owner { statusDidChange?(owner, value) } }
        connection = try session.connect(owner: self,
            captureDraft: { $0.capture?() },
            draftDidChange: { $0.render($1) },
            statusDidChange: { $0.statusChanged($1) })
        for editor in editors {
            let control = UIKitHistoryControl(editor: editor)
            let facade = UIKitHistoryUndoManager(owner: self, editor: editor, registrationManager: session.undoManager)
            control.facade = facade; editor.historyFacade = facade; editor.delegate = self
            controls.append(control)
        }
        for editor in localEditors {
            localControls.append(UIKitHistoryControl(editor: editor)); editor.delegate = self
        }
        session.editing.settlementDidComplete = { [weak self] in self?.retireAcceptedLiveHistory() }
        observeNativeManagers()
        publishAvailability()
    }
    var hasMarkedText: Bool { controls.contains { $0.editor?.markedTextRange != nil } }
    var permitsEditing: Bool { isAvailable && !pending && !disconnected && session.editing.permitsKnownLiveEditing }
    func captureLive() {
        guard !rendering, !disconnected, let value = capture?(), session.editing.permitsKnownLiveEditing else { return }
        do { try session.editing.captureKnownLiveDraft(value) } catch { publishAvailability() }
    }
    func render(_ value: Lease.Draft) {
        guard !disconnected else { return }
        rendering = true
        present?(value)
        rendering = false
    }
    func statusChanged(_ value: NativeHistoryStatus) {
        guard !disconnected else { return }
        presentStatus?(value); publishAvailability()
    }
    /// Explicit transaction boundary. A rejection keeps its exact evidence and live stack.
    @discardableResult public func commit() async -> HistoryResult {
        await perform { await $0.editing.commitKnownLiveDraft() }
    }
    /// An explicit host semantic action settles prior editing before applying its proposed value.
    @discardableResult public func applyDraft(_ proposed: Lease.Draft) async -> HistoryResult {
        let present = present
        return await perform { session in
            let prior = await session.editing.commitKnownLiveDraft()
            guard session.status.phase == .ready, !session.status.requiresDraftDecision else { return prior }
            do { try session.updateDraft(proposed) } catch {
                return .failure(error as? HistoryFailure ?? HistoryFailure(.storage, stage: .preparation, disposition: .suspended))
            }
            present?(proposed)
            return await session.commit()
        }
    }
    @discardableResult public func retryDraft() async -> HistoryResult {
        await perform { await $0.retryDraft() }
    }
    @discardableResult public func discardDraft() async -> HistoryResult {
        let result = await perform { await $0.discardDraft() }
        if session.status.phase == .ready, !session.status.requiresDraftDecision { retireAcceptedLiveHistory() }
        return result
    }
    /// Explicit durable Undo settles the live transaction before reversing its accepted group.
    @discardableResult public func undoDocument() async -> HistoryResult {
        await perform { await $0.editing.undoKnownLiveDraft() }
    }
    @discardableResult public func redoDocument() async -> HistoryResult {
        await perform { await $0.editing.redoKnownLiveDraft() }
    }
    #if DEBUG
    @discardableResult public func demonstrateFinalizationFailure() async -> HistoryResult {
        await perform { await $0.demonstrateFinalizationFailure() }
    }
    #endif
    public func waitForOperations() async { _ = await operation?.value }
    /// Preserve values before releasing controls and recognized callback graphs, even if
    /// persistence or lease closure remains blocked. Disconnection does not cancel delivery.
    public func disconnect() {
        guard !disconnected else { return }
        captureLive()
        disconnected = true
        pendingSwiftUIEditingEnd = nil
        connection?.disconnect(); connection = nil
        session.editing.settlementDidComplete = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for control in controls {
            if let editor = control.editor as? NativeHistoryTextView, editor.historyFacade === control.facade {
                editor.originalUndoManager?.removeAllActions(); editor.historyFacade = nil
            }
            if control.editor?.delegate === self { control.editor?.delegate = control.previousDelegate }
            control.facade?.owner = nil
        }
        for control in localControls where control.editor?.delegate === self { control.editor?.delegate = control.previousDelegate }
        controls = []; localControls = []; capture = nil; present = nil; presentStatus = nil
    }
    public func close() async {
        captureLive(); isAvailable = false
        await waitForOperations(); await session.close()
    }
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if localControls.contains(where: { $0.editor === textView }) { return true }
        pendingSwiftUIEditingEnd?(); pendingSwiftUIEditingEnd = nil
        guard permitsEditing else { return false }
        liveTransaction = true; participants.insert(ObjectIdentifier(textView))
        return true
    }
    public func textViewDidChange(_ textView: UITextView) {
        if controls.contains(where: { $0.editor === textView }), !rendering {
            liveTransaction = true; participants.insert(ObjectIdentifier(textView)); captureLive()
        }
        resumeDeferredBoundary()
        publishAvailability()
    }
    public func textViewDidBeginEditing(_ textView: UITextView) {
        pendingSwiftUIEditingEnd?(); pendingSwiftUIEditingEnd = nil
        resumeDeferredBoundary(); publishAvailability()
    }
    public func textViewDidEndEditing(_ textView: UITextView) {
        guard let editor = textView as? NativeHistoryTextView, editor.isManagedBySwiftUI else {
            finishEditingBoundary(for: textView)
            return
        }
        // SwiftUI can resign an editor before delivering onDisappear/dismantle.
        // Let that synchronous presentation transition finish, retaining evidence of
        // a detach even if the same editor has already reappeared by the next turn.
        let generation = editor.swiftUIPresentationGeneration
        let finish = { [weak self, weak editor] in
            guard let self, let editor,
                  generation == editor.swiftUIPresentationGeneration,
                  !editor.isTemporarilyDetachedBySwiftUI, editor.window != nil else { return }
            self.finishEditingBoundary(for: editor)
        }
        pendingSwiftUIEditingEnd = finish
        DispatchQueue.main.async { [weak self] in
            self?.pendingSwiftUIEditingEnd?()
            self?.pendingSwiftUIEditingEnd = nil
        }
    }
    private func finishEditingBoundary(for textView: UITextView) {
        if controls.contains(where: { $0.editor === textView }), liveTransaction, permitsEditing {
            deferredBoundary = true; resumeDeferredBoundary()
        }
        publishAvailability()
    }
    public func textViewDidChangeSelection(_ textView: UITextView) { resumeDeferredBoundary(); publishAvailability() }
    isolated deinit { disconnect() }
}

@MainActor final class UIKitHistoryControl {
    weak var editor: UITextView?
    weak var previousDelegate: (any UITextViewDelegate)?
    var facade: UIKitHistoryUndoManager?
    var lastAvailability = ""
    init(editor: UITextView) { self.editor = editor; previousDelegate = editor.delegate }
}
#endif
