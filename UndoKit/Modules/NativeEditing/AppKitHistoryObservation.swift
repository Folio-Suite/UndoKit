// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(AppKit)
import AppKit

extension NativeHistoryAppKitBinding {
    func observeEditors() {
        for name in [
            NSText.didChangeNotification, NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let object = note.object.map { ObjectIdentifier($0 as AnyObject) }
                    let name = note.name
                    MainActor.assumeIsolated {
                        guard let self, !self.disconnected else { return }
                        if object == ObjectIdentifier(self.liveManager) {
                            self.session.nativeCoordinator.compositionChanged(attachment: self.attachmentID)
                            self.publishAvailability()
                            return
                        }
                        guard
                            let control = self.controls.first(where: { $0.editor.map(ObjectIdentifier.init) == object }
                            ),
                            let editor = control.editor, let field = control.field
                        else { return }
                        if name == NSText.didChangeNotification && !self.rendering {
                            _ = self.session.nativeCoordinator.beginChange(
                                attachment: self.attachmentID, control: control.id, field: field,
                                composing: editor.hasMarkedText())
                            self.session.nativeCoordinator.changed(
                                attachment: self.attachmentID, control: control.id, field: field,
                                value: editor.string, composing: editor.hasMarkedText())
                        } else if name == NSText.didBeginEditingNotification {
                            self.session.nativeCoordinator.focusBoundary(
                                attachment: self.attachmentID, beginningControl: control.id)
                        } else if name == NSText.didEndEditingNotification, !editor.isTemporarilyDetachedBySwiftUI {
                            self.session.nativeCoordinator.focusBoundary(attachment: self.attachmentID)
                        }
                        self.publishAvailability()
                    }
                })
        }
    }
}
#endif
