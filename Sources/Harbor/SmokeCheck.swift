#if DEBUG
import AppKit
import HarborCore

/// Opt-in development check. Uses only the explicitly supplied disposable local server,
/// keeps the connection in memory, and never writes saved profiles or Keychain credentials.
@MainActor enum SmokeCheck {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--smoke-test"), let raw = env["HARBOR_TEST_PORT"], let port = Int(raw), let output = env["HARBOR_SMOKE_OUTPUT"] else { return }
        Task {
            do {
                let profile = ConnectionProfile(name: "本地测试", host: "127.0.0.1", port: port, username: env["HARBOR_TEST_USER"] ?? "root", database: "harbor_preview", rememberPassword: false)
                model.profiles = [profile]; model.connect(profile, password: env["HARBOR_TEST_PASSWORD"] ?? "")
                try await idle(model)
                model.toggleCatalog("harbor_preview", kind: .tables)
                model.toggleCatalog("harbor_preview", table: "users")
                for kind in CatalogKind.tableKinds {
                    model.toggleCatalog("harbor_preview", table: "users", kind: kind); try await idle(model)
                    let key = model.catalogKey("harbor_preview", table: "users", kind: kind)
                    try require(model.catalog[key] != nil && model.catalogErrors[key] == nil, "Catalog \(kind.rawValue)")
                    if kind != .columns { model.toggleCatalog("harbor_preview", table: "users", kind: kind) }
                }
                model.openTable(TableReference(database: "harbor_preview", name: "users")); try await idle(model)
                try require(model.active?.result.rows.count == 8, "Table open")
                try require(model.active?.executedSQL.hasPrefix("SELECT * FROM") == true, "Default SELECT star")
                model.sort(column: "id", direction: .ascending); try await idle(model)
                try require(model.active?.result.rows.first?.first?.text == "101", "Ascending sort")
                model.applyFilter(FilterRule(column: "status", operation: .equals, value: "active"), sort: SortRule(column: "id", direction: .descending)); try await idle(model)
                try require(model.active?.result.rows.count == 6, "Filter")
                model.setColumn("email", visible: false); try await idle(model)
                try require(model.active?.result.columns.contains { $0.name == "email" } == false, "Column visibility")
                try require(model.active?.executedSQL.hasPrefix("SELECT *") == false, "Explicit hidden-column projection")
                model.setColumn("email", visible: true); try await idle(model)
                model.applyFilter(nil, sort: nil); try await idle(model)
                model.selectCell(row: 0, column: 1, openEditor: true)
                try require(model.canEditCell, "Cell editor")
                model.editActive { $0.editorVisible = false }
                let tableID = model.activeID
                model.editActive { $0.footerDraft = "SELECT id, UPPER(name) AS name FROM users WHERE id = 108" }
                model.saveFooter(); try await idle(model)
                try require(model.active?.result.rows.count == 1 && model.active?.result.rows.first?.first?.text == "108", "Footer result refresh")
                model.selectCell(row: 0, column: 1, openEditor: false)
                try require(!model.canEditCell && !model.canUseTableTools, "Custom result is read-only")
                let successfulSQL = model.active?.executedSQL
                model.editActive { $0.footerDraft = "SELECT missing_column FROM users" }
                model.saveFooter()
                while model.busy { try await Task.sleep(for: .milliseconds(50)) }
                try require(model.error != nil && model.active?.executedSQL == successfulSQL && model.active?.footerDirty == true && model.active?.result.rows.count == 1, "Failed footer keeps draft and result")
                model.error = nil
                model.newQuery(); model.activeID = tableID
                try require(model.active?.footerDraft == "SELECT missing_column FROM users", "Draft survives tab switch")
                model.editActive { $0.footerDraft = "SELECT * FROM users WHERE 1 = 0" }
                model.saveFooter(); try await idle(model)
                try require(model.active?.result.columns.count == 5 && model.active?.result.rows.isEmpty == true, "Footer empty-result headers")
                model.refresh(); try await idle(model)
                try require(model.active?.executedSQL == "SELECT * FROM users WHERE 1 = 0", "Refresh preserves custom SQL")
                model.restoreTableSQL(); try await idle(model)
                try require(model.canUseTableTools && model.active?.result.rows.count == 8 && model.active?.executedSQL.hasPrefix("SELECT * FROM") == true, "Restore table tools")
                try await Task.sleep(for: .milliseconds(500))
                guard let window = NSApp.windows.first(where: { $0.contentView != nil && !$0.isSheet }), let content = window.contentView else { throw HarborError.message("No application window") }
                let view = content.superview ?? content
                view.layoutSubtreeIfNeeded()
                @MainActor func grid(in node: NSView) -> NSTableView? {
                    if let table = node as? NSTableView { return table }
                    for child in node.subviews { if let found = grid(in: child) { return found } }; return nil
                }
                if let table = grid(in: view), let scroll = table.enclosingScrollView {
                    try require(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top <= table.rect(ofRow: 0).minY, "First row is visible below the header")
                }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HarborError.message("Could not capture window") }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
                model.newQuery(); model.editActive { $0.sql = "SELECT id,name FROM users WHERE 1=0" }; model.runQuery(); try await idle(model)
                try require(model.active?.result.columns.count == 2 && model.active?.result.rows.isEmpty == true, "Empty result headers")
                try "PASS: catalog hierarchy, SELECT star, footer apply/error/drafts/refresh/reset, read-only custom result, connection, table, sort, filter, columns, editor and query\n".write(toFile: output + ".txt", atomically: true, encoding: .utf8)
            } catch {
                try? "FAIL: \(error.localizedDescription)\n".write(toFile: output + ".txt", atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }
    private static func idle(_ model: AppModel) async throws {
        let start = Date()
        while model.busy {
            try await Task.sleep(for: .milliseconds(50))
            if Date().timeIntervalSince(start) > 40 { throw HarborError.message("UI operation timed out") }
        }
        if let error = model.error { throw HarborError.message(error) }
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw HarborError.message(message) } }
}
#endif
