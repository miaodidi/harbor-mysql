import SwiftUI
import HarborCore

struct WorkspaceTab: Identifiable {
    let id = UUID()
    var table: TableReference?
    var title: String
    var database: String
    var sql = "SELECT VERSION();"
    var result = QueryResult()
    var schema: [HarborCore.TableColumn] = []
    var info = TableInfo()
    var visibleColumns: Set<String> = []
    var filter: FilterRule?
    var sort: SortRule?
    var page = 0
    var pageSize = 100
    var executedSQL = ""
    var footerDraft = ""
    var customSQL: String?
    var footerDirty: Bool { footerDraft != executedSQL }
    var canNext = false
    var editorVisible = false
    var filterVisible = false
    var selectedRow: Int?
    var selectedColumn: Int?
    var editValue = ""
    var editNull = false
    var status = ""
}

@MainActor final class AppModel: ObservableObject {
    @Published var profiles: [ConnectionProfile] = []
    @Published var connectedID: UUID?
    @Published var serverVersion = ""
    @Published var databases: [String] = []
    /// Default database for new query tabs. This is separate from link state.
    @Published var currentDatabase: String?
    /// Several databases can be linked at once over one server connection.
    @Published var linkedDatabases: Set<String> = []
    @Published var tables: [String: [TableReference]] = [:]
    @Published var expandedDatabases: Set<String> = []
    @Published var expandedCatalog: Set<String> = []
    @Published var catalog: [String: [CatalogObject]] = [:]
    @Published var catalogErrors: [String: String] = [:]
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeID: UUID?
    @Published var busy = false
    @Published var activity = ""
    @Published var error: String?
    @Published var connectionSheet = false
    @Published var editingProfile: ConnectionProfile?
    @Published var writeConfirmation = false
    @Published var pendingSQL = ""
    @Published var showInspector = true
    @Published var sidebarSearch = ""
    let session = MySQLSession()
    let store = ProfileStore()
    private var memoryPasswords: [UUID: String] = [:]
    private var queryCounter = 0
    private var pendingAction: (() -> Void)?

    var connectedProfile: ConnectionProfile? { profiles.first { $0.id == connectedID } }
    var active: WorkspaceTab? { tabs.first { $0.id == activeID } }
    var canOperate: Bool { connectedID != nil && !busy }

    init() {
        do { profiles = try store.load() } catch { self.error = "读取连接配置失败：\(error.localizedDescription)" }
    }
    func editActive(_ edit: (inout WorkspaceTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }; edit(&tabs[index])
    }
    func editTab(_ id: UUID, _ edit: (inout WorkspaceTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }; edit(&tabs[index])
    }
    func password(for profile: ConnectionProfile) throws -> String {
        if let value = memoryPasswords[profile.id] { return value }
        return profile.rememberPassword ? try PasswordStore.read(for: profile.id) ?? "" : ""
    }
    func saveProfile(_ profile: ConnectionProfile, password: String) throws {
        try profile.validate()
        if profile.rememberPassword { try PasswordStore.save(password, for: profile.id) }
        else { try PasswordStore.delete(for: profile.id) }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try store.save(updated); profiles = updated; memoryPasswords[profile.id] = password
    }
    func deleteProfile(_ profile: ConnectionProfile) {
        guard !busy else { return }
        perform("删除连接") {
            if self.connectedID == profile.id { await self.session.disconnect(); self.connectedID = nil; self.currentDatabase = nil; self.linkedDatabases = []; self.databases = []; self.tables = [:] }
            let updated = self.profiles.filter { $0.id != profile.id }
            try self.store.save(updated); try PasswordStore.delete(for: profile.id)
            self.profiles = updated; self.memoryPasswords[profile.id] = nil
        }
    }
    func openConnectionSheet(_ profile: ConnectionProfile? = nil) { editingProfile = profile; connectionSheet = true }
    func connect(_ profile: ConnectionProfile) {
        guard !busy else { return }
        do { let password = try password(for: profile); connect(profile, password: password) }
        catch { self.error = error.localizedDescription }
    }
    func connect(_ profile: ConnectionProfile, password: String) {
        perform("正在连接 \(profile.name)…") {
            self.connectedID = nil; self.currentDatabase = nil; self.linkedDatabases = []; self.databases = []; self.tables = [:]; self.expandedDatabases = []
            self.expandedCatalog = []; self.catalog = [:]; self.catalogErrors = [:]
            self.serverVersion = try await self.session.connect(profile, password: password)
            self.connectedID = profile.id
            self.databases = try await self.session.databases()
            // Preserve query drafts across connections; table tabs belong to the previous session.
            self.tabs.removeAll { $0.table != nil }
            for i in self.tabs.indices { self.tabs[i].result = QueryResult(); self.tabs[i].status = ""; self.tabs[i].database = profile.database }
            self.activeID = self.tabs.first?.id
            if !profile.database.isEmpty {
                _ = try await self.session.execute("USE \(SQLBuilder.identifier(profile.database))")
                self.currentDatabase = profile.database
                self.linkedDatabases.insert(profile.database)
                self.expandedDatabases.insert(profile.database)
                self.tables[profile.database] = try await self.session.tables(in: profile.database)
            }
        }
    }
    func disconnect() {
        perform("断开连接") { await self.session.disconnect(); self.connectedID = nil; self.currentDatabase = nil; self.linkedDatabases = []; self.databases = []; self.tables = [:]; self.expandedDatabases = [] }
    }
    func cancel() { Task { await session.disconnect(); connectedID = nil; currentDatabase = nil; linkedDatabases = []; activity = "连接已断开" } }

    func perform(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; activity = label
        Task {
            defer { busy = false; activity = "" }
            do { try await operation() }
            catch { self.error = error.localizedDescription; if !(await session.isConnected()) { connectedID = nil } }
        }
    }
    func toggleDatabase(_ database: String) {
        guard canOperate else { return }
        guard linkedDatabases.contains(database) else { return }
        if expandedDatabases.contains(database) { expandedDatabases.remove(database) } else { expandedDatabases.insert(database) }
    }
    func selectDatabase(_ database: String) {
        linkDatabase(database)
    }
    func linkDatabase(_ database: String) {
        guard canOperate else { return }
        if linkedDatabases.contains(database) { currentDatabase = database; expandedDatabases.insert(database); return }
        perform("切换数据库 \(database)…") {
            _ = try await self.session.execute("USE \(SQLBuilder.identifier(database))")
            self.currentDatabase = database
            self.linkedDatabases.insert(database)
            self.expandedDatabases.insert(database)
            self.tables[database] = try await self.session.tables(in: database)
        }
    }
    func unlinkDatabase(_ database: String) {
        guard canOperate, linkedDatabases.contains(database) else { return }
        linkedDatabases.remove(database)
        expandedDatabases.remove(database)
        tables[database] = nil
        let prefix = database + "\0"
        catalog = catalog.filter { !$0.key.hasPrefix(prefix) }
        catalogErrors = catalogErrors.filter { !$0.key.hasPrefix(prefix) }
        expandedCatalog = expandedCatalog.filter { !$0.hasPrefix(prefix) }
        let removedIDs = Set(tabs.filter { $0.table?.database == database }.map(\.id))
        tabs.removeAll { removedIDs.contains($0.id) }
        if let activeID, removedIDs.contains(activeID) { self.activeID = tabs.last?.id }
        if currentDatabase == database { currentDatabase = linkedDatabases.first }
    }
    func refreshDatabase(_ database: String) {
        guard canOperate, linkedDatabases.contains(database) else { return }
        perform("刷新数据库…") {
            self.tables[database] = try await self.session.tables(in: database)
            self.catalog = self.catalog.filter { $0.key.hasPrefix(database + "\0") == false }
            self.catalogErrors = self.catalogErrors.filter { $0.key.hasPrefix(database + "\0") == false }
            self.expandedCatalog = self.expandedCatalog.filter { $0.hasPrefix(database + "\0") == false }
        }
    }
    func openTable(_ table: TableReference) {
        guard linkedDatabases.contains(table.database) else { linkDatabase(table.database); return }
        currentDatabase = table.database
        if let existing = tabs.first(where: { $0.table == table }) { activeID = existing.id; return }
        guard canOperate else { return }
        let tab = WorkspaceTab(table: table, title: table.name, database: table.database)
        tabs.append(tab); activeID = tab.id
        perform("打开 \(table.name)…") {
            let schema = try await self.session.schema(for: table)
            let info = try await self.session.info(for: table)
            self.editTab(tab.id) { $0.schema = schema; $0.visibleColumns = Set(schema.map(\.name)); $0.info = info }
            try await self.loadTable(tab.id)
        }
    }
    func newQuery() {
        queryCounter += 1
        let tab = WorkspaceTab(title: "查询 \(queryCounter)", database: active?.database ?? connectedProfile?.database ?? "")
        tabs.append(tab); activeID = tab.id
    }
    func closeTab(_ id: UUID) {
        guard !busy else { return }
        if let tab = tabs.first(where: { $0.id == id }), (tab.table == nil && tab.sql != "SELECT VERSION();") || tab.footerDirty {
            let alert = NSAlert(); alert.messageText = "关闭查询标签？"; alert.informativeText = "未导出的 SQL 草稿将被关闭。"; alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        tabs.removeAll { $0.id == id }; if activeID == id { activeID = tabs.last?.id }
    }
    func refresh() {
        guard canOperate else { return }
        if let tab = active, tab.table != nil {
            let action: () -> Void = { [weak self] in self?.perform("刷新表…") {
                guard let self else { return }
                if let table = tab.table { let info = try await self.session.info(for: table); self.editTab(tab.id) { $0.info = info } }
                try await self.loadTable(tab.id)
            } }
            if let sql = tab.customSQL, SQLBuilder.requiresWriteConfirmation(sql) { pendingSQL = sql; pendingAction = action; writeConfirmation = true }
            else { action() }
        } else {
            perform("刷新数据库…") {
                self.databases = try await self.session.databases()
                if let db = self.currentDatabase { self.tables[db] = try await self.session.tables(in: db) }
                self.catalog = [:]; self.catalogErrors = [:]; self.expandedCatalog = []
            }
        }
    }
    private func loadTable(_ id: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == id }), let reference = tab.table else { return }
        if let sql = tab.customSQL {
            try await executeFooter(tab.id, sql: sql, preserveDraft: tab.footerDirty)
            return
        }
        let columns = tab.schema.map(\.name).filter { tab.visibleColumns.contains($0) }
        let sql = try SQLBuilder.select(table: reference, columns: columns, filter: tab.filter, sort: tab.sort, page: tab.page, pageSize: tab.pageSize, allColumns: columns.count == tab.schema.count)
        var result = try await session.execute(sql, maxRows: tab.pageSize)
        result.columns = result.columns.map { c in ResultColumn(name: c.name, type: tab.schema.first { $0.name == c.name }?.type ?? c.type) }
        editTab(id) {
            $0.result = result; $0.executedSQL = sql; $0.canNext = result.rows.count == tab.pageSize
            if !tab.footerDirty { $0.footerDraft = sql }
            $0.selectedRow = nil; $0.selectedColumn = nil
            $0.status = "\(result.rows.count) 行 · \(String(format: "%.3f", result.elapsed)) 秒"
        }
    }
    func sort(column: String, direction: SortDirection?) {
        guard canUseTableTools, let id = activeID, active?.table != nil else { return }
        editActive { $0.sort = direction.map { SortRule(column: column, direction: $0) }; $0.page = 0 }
        perform("正在排序…") { try await self.loadTable(id) }
    }
    func applyFilter(_ filter: FilterRule?, sort: SortRule?) {
        guard canUseTableTools, let id = activeID else { return }
        editActive { $0.filter = filter; $0.sort = sort; $0.page = 0 }
        perform("正在筛选…") { try await self.loadTable(id) }
    }
    func setColumn(_ name: String, visible: Bool) {
        guard canUseTableTools, let id = activeID, let tab = active else { return }
        guard visible || tab.visibleColumns.count > 1 else { return }
        editActive { if visible { $0.visibleColumns.insert(name) } else { $0.visibleColumns.remove(name) } }
        perform("更新显示列…") { try await self.loadTable(id) }
    }
    func invertColumns() {
        guard canUseTableTools, let tab = active else { return }
        let all = Set(tab.schema.map(\.name))
        let inverted = all.subtracting(tab.visibleColumns)
        editActive { $0.visibleColumns = inverted }
        // Allow the user to invert an all-selected table and then choose a
        // small subset; loading is deferred until at least one column returns.
        guard !inverted.isEmpty, let id = activeID else { return }
        perform("更新显示列…") { try await self.loadTable(id) }
    }
    func page(_ delta: Int) {
        guard canUseTableTools, let id = activeID else { return }
        editActive { $0.page = max(0, $0.page + delta) }
        perform("加载数据…") { try await self.loadTable(id) }
    }
    func runQuery() {
        guard canOperate, let tab = active, tab.table == nil else { return }
        let action: () -> Void = { [weak self] in
            self?.perform("正在执行 SQL…") {
                guard let self else { return }
                if !tab.database.isEmpty { _ = try await self.session.execute("USE \(SQLBuilder.identifier(tab.database))") }
                let result = try await self.session.execute(tab.sql)
                self.editTab(tab.id) { $0.result = result; $0.executedSQL = tab.sql; $0.selectedRow = nil; $0.selectedColumn = nil; $0.status = result.columns.isEmpty ? "执行成功 · 影响 \(result.affectedRows) 行" : "\(result.rows.count) 行 · \(String(format: "%.3f", result.elapsed)) 秒\(result.truncated ? " · 已截断显示" : "")" }
            }
        }
        if SQLBuilder.requiresWriteConfirmation(tab.sql) { pendingSQL = tab.sql; pendingAction = action; writeConfirmation = true }
        else { action() }
    }
    func confirmWrite() { let action = pendingAction; pendingAction = nil; action?() }
    func selectCell(row: Int, column: Int, openEditor: Bool) {
        guard let tab = active, tab.result.rows.indices.contains(row), tab.result.columns.indices.contains(column) else { return }
        let value = tab.result.rows[row][column]
        editActive { $0.selectedRow = row; $0.selectedColumn = column; $0.editValue = value == .null ? "" : value.display; $0.editNull = value == .null; if openEditor { $0.editorVisible = true } }
    }
    var editableColumn: HarborCore.TableColumn? {
        guard let tab = active, let c = tab.selectedColumn, tab.result.columns.indices.contains(c) else { return nil }
        return tab.schema.first { $0.name == tab.result.columns[c].name }
    }
    var canEditCell: Bool {
        guard canUseTableTools, let tab = active, tab.table?.isView == false, let column = editableColumn,
              !column.primaryKey, !column.generated, !column.binary,
              tab.selectedRow != nil else { return false }
        let keys = tab.schema.filter(\.primaryKey)
        return !keys.isEmpty && keys.allSatisfy { tab.visibleColumns.contains($0.name) }
    }
    func saveCell() {
        guard canEditCell, let tab = active, let table = tab.table, let row = tab.selectedRow, let column = editableColumn else { return }
        do {
            let record = tab.result.records()[row], value: CellValue = tab.editNull ? .null : .text(tab.editValue)
            if record[column.name] == value { return }
            let sql = try SQLBuilder.update(table: table, column: column, value: value, original: record, schema: tab.schema)
            pendingSQL = sql
            pendingAction = { [weak self] in self?.perform("保存字段…") {
                guard let self else { return }
                let result = try await self.session.execute(sql)
                guard result.affectedRows == 1 else { throw HarborError.message("没有修改任何记录：原数据可能已变化，请刷新后重试。") }
                try await self.loadTable(tab.id)
            } }
            writeConfirmation = true
        } catch { self.error = error.localizedDescription }
    }
    func exportSQL() {
        guard let active else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(active.title).sql"
        if panel.runModal() == .OK, let url = panel.url {
            do { try (active.table == nil ? active.sql : active.executedSQL).write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }

    func filterSuggestions(for tab: WorkspaceTab, column: String, query: String) async -> [String] {
        guard let table = tab.table, linkedDatabases.contains(table.database),
              tab.schema.contains(where: { $0.name == column }) else { return [] }
        let pattern = query.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_") + "%"
        let sql = "SELECT DISTINCT \(SQLBuilder.identifier(column)) AS value FROM \(SQLBuilder.table(table)) WHERE CAST(\(SQLBuilder.identifier(column)) AS CHAR) LIKE \(SQLBuilder.literal(.text(pattern))) ESCAPE '!' ORDER BY \(SQLBuilder.identifier(column)) LIMIT 30"
        guard let result = try? await session.execute(sql) else { return [] }
        return result.rows.compactMap { row in
            guard let value = row.first, value != .null else { return nil }
            return value.display
        }
    }

    var canUseTableTools: Bool { canOperate && active?.customSQL == nil && active?.footerDirty == false }

    func saveFooter() {
        guard canOperate, let tab = active, tab.table != nil else { return }
        let sql = tab.footerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { error = "请输入 SQL。"; return }
        let action: () -> Void = { [weak self] in
            self?.perform("保存 SQL 并刷新…") { guard let self else { return }; try await self.executeFooter(tab.id, sql: sql) }
        }
        if SQLBuilder.requiresWriteConfirmation(sql) { pendingSQL = sql; pendingAction = action; writeConfirmation = true }
        else { action() }
    }

    private func executeFooter(_ id: UUID, sql: String, preserveDraft: Bool = false) async throws {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        _ = try await session.execute("USE \(SQLBuilder.identifier(tab.database))")
        let result = try await session.execute(sql)
        // Commit the SQL and its result together. Errors leave the draft and last successful result intact.
        editTab(id) {
            $0.result = result; $0.executedSQL = sql; $0.customSQL = sql
            if !preserveDraft { $0.footerDraft = sql }
            $0.canNext = false; $0.selectedRow = nil; $0.selectedColumn = nil
            $0.editorVisible = false; $0.filterVisible = false; $0.filter = nil; $0.sort = nil
            $0.status = result.columns.isEmpty ? "执行成功 · 影响 \(result.affectedRows) 行" : "\(result.rows.count) 行 · \(String(format: "%.3f", result.elapsed)) 秒\(result.truncated ? " · 已截断显示" : "")"
        }
    }

    func restoreTableSQL() {
        guard canOperate, let tab = active, tab.table != nil else { return }
        if tab.footerDirty {
            let alert = NSAlert(); alert.messageText = "放弃底部 SQL 的未保存修改？"; alert.addButton(withTitle: "恢复表浏览"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        editActive { $0.customSQL = nil; $0.footerDraft = $0.executedSQL; $0.filter = nil; $0.sort = nil; $0.page = 0; $0.visibleColumns = Set($0.schema.map(\.name)) }
        perform("恢复表浏览…") {
            do { try await self.loadTable(tab.id) }
            catch { self.editTab(tab.id) { $0 = tab }; throw error }
        }
    }
}
