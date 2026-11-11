#if DEBUG
import AppKit
import HarborCore

/// Exercises actual controls in the disposable smoke-test window. No writes
/// are submitted to MySQL and no connection settings or passwords are saved.
@MainActor enum InputSmokeCheck {
    static func run(_ model: AppModel, view: NSView, tableID: UUID) async throws {
        let queryID = model.activeID!
        model.editActive { $0.sql = "SELECT '中文🙂', name\nFROM users;" }
        try await pause()
        try await checkEditor("query-sql", model: model, view: view, keyPath: \.sql)
        let binding = model.textBinding(for: queryID, keyPath: \.sql)
        model.activeID = tableID
        binding.wrappedValue = "SELECT 'draft in original tab';"
        try require(model.tabs.first { $0.id == queryID }?.sql == "SELECT 'draft in original tab';" && model.active?.sql != binding.wrappedValue, "Binding targets originating tab")
        try await pause()
        try await checkEditor("footer-sql", model: model, view: view, keyPath: \.footerDraft)
        model.selectCell(row: 0, column: 1, openEditor: true)
        try await pause()
        try await checkEditor("cell-value", model: model, view: view, keyPath: \.editValue)
        model.editActive { $0.editNull = true }
        try await pause()
        try require(!editor("cell-value", in: view)!.isEditable, "NULL cell is read-only")
        model.editActive { $0.editNull = false; $0.editorVisible = false; $0.filterVisible = true }
        try await pause()
        let mainFields = descendants(view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        try require(mainFields.count == 2, "Search and filter fields present")
        for field in mainFields { try await checkField(field, model: model) }
        model.sidebarSearch = ""

        model.openConnectionSheet()
        try await pause()
        guard let sheet = view.window?.sheets.first, let sheetView = sheet.contentView else { throw HarborError.message("Missing connection form") }
        let connectionFields = descendants(sheetView).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        try require(connectionFields.count == 6, "All six connection inputs present")
        try require(connectionFields.contains { $0 is NSSecureTextField }, "Password input stays secure")
        for field in connectionFields { try await checkField(field, model: model) }
        model.connectionSheet = false
        try await pause()
    }

    private static func checkEditor(_ id: String, model: AppModel, view: NSView, keyPath: WritableKeyPath<WorkspaceTab, String>) async throws {
        let original = model.active![keyPath: keyPath]
        model.editActive { $0[keyPath: keyPath] = "SELECT '中文🙂', name\nFROM users;" }
        try await pause()
        guard let text = editor(id, in: view) else { throw HarborError.message("Missing editor: \(id)") }
        text.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 7, length: 0))
        for (offset, character) in ["a", "b", "中"].enumerated() {
            text.insertText(character, replacementRange: text.selectedRange())
            try await pause()
            try require(text.selectedRange() == NSRange(location: 8 + offset, length: 0), "\(id): caret after keystroke")
            try require(model.active?[keyPath: keyPath] == text.string, "\(id): model tracks input")
        }
        text.deleteBackward(nil)
        try await pause()
        try require(text.selectedRange().location == 9 && text.string.hasPrefix("SELECT ab'"), "\(id): middle deletion")
        text.setSelectedRange(NSRange(location: 7, length: 2))
        model.showInspector.toggle()
        try await pause()
        try require(text.selectedRange() == NSRange(location: 7, length: 2), "\(id): selection survives unrelated redraw")
        text.breakUndoCoalescing()
        text.undoManager?.removeAllActions()
        let beforePaste = text.string
        text.insertText("你好\n🙂", replacementRange: text.selectedRange())
        try await pause()
        try require(text.selectedRange().location == 12 && text.string.contains("你好\n🙂"), "\(id): multiline Unicode replacement")
        text.breakUndoCoalescing()
        let afterPaste = text.string
        try require(text.undoManager?.canUndo == true, "\(id): undo available")
        text.undoManager?.undo()
        try await pause()
        try require(text.string == beforePaste && model.active?[keyPath: keyPath] == beforePaste, "\(id): undo (actual=\(text.string.debugDescription), expected=\(beforePaste.debugDescription))")
        text.undoManager?.redo()
        try await pause()
        try require(text.string == afterPaste && model.active?[keyPath: keyPath] == afterPaste, "\(id): redo")
        text.setSelectedRange(NSRange(location: 7, length: 0))
        text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        model.showInspector.toggle()
        try await pause()
        try require(text.hasMarkedText(), "\(id): composition survives redraw")
        text.insertText("中", replacementRange: text.markedRange())
        try await pause()
        try require(!text.hasMarkedText() && text.selectedRange().location == 8 && model.active?[keyPath: keyPath] == text.string, "\(id): composition commit")
        model.editActive { $0[keyPath: keyPath] = original }
        try await pause()
    }

    private static func checkField(_ field: NSTextField, model: AppModel) async throws {
        field.selectText(nil)
        guard let text = field.currentEditor() as? NSTextView else { throw HarborError.message("Missing single-line field editor") }
        text.insertText("abcdef", replacementRange: text.selectedRange())
        try await pause()
        text.setSelectedRange(NSRange(location: 2, length: 0))
        for (offset, character) in ["x", "y"].enumerated() {
            text.insertText(character, replacementRange: text.selectedRange())
            model.showInspector.toggle()
            try await pause()
            try require(text.selectedRange().location == 3 + offset && field.currentEditor() === text, "Single-line input retains focus and caret")
        }
        try require(field.stringValue == "abxycdef", "Single-line input keeps middle edits")
        text.setSelectedRange(NSRange(location: 2, length: 2))
        text.insertText("中", replacementRange: text.selectedRange())
        try await pause()
        try require(field.stringValue == "ab中cdef" && text.selectedRange().location == 3, "Single-line selection replacement")
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        text.insertText("", replacementRange: text.selectedRange())
        field.window?.makeFirstResponder(nil)
        try await pause()
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private static func editor(_ id: String, in view: NSView) -> NSTextView? {
        descendants(view).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == id }
    }
    private static func pause() async throws { try await Task.sleep(for: .milliseconds(180)) }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw HarborError.message(message) } }
}
#endif
