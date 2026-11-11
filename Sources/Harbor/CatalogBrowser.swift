import SwiftUI
import HarborCore

extension AppModel {
    func catalogKey(_ database: String, table: String? = nil, kind: CatalogKind? = nil) -> String {
        database + "\0" + (table ?? "") + "\0" + (kind?.rawValue ?? "")
    }
    func toggleCatalog(_ database: String, table: String? = nil, kind: CatalogKind? = nil) {
        guard linkedDatabases.contains(database) else { linkDatabase(database); return }
        currentDatabase = database
        let key = catalogKey(database, table: table, kind: kind)
        if expandedCatalog.contains(key) { expandedCatalog.remove(key); return }
        guard canOperate else { return }
        expandedCatalog.insert(key)
        guard let kind, ![.tables, .views, .queries, .backups].contains(kind) else { return }
        loadCatalog(database, table: table, kind: kind)
    }
    func loadCatalog(_ database: String, table: String? = nil, kind: CatalogKind) {
        guard linkedDatabases.contains(database) else { return }
        let key = catalogKey(database, table: table, kind: kind)
        perform("读取\(kind.rawValue)…") {
            do { self.catalog[key] = try await self.session.objects(in: database, table: table, kind: kind); self.catalogErrors[key] = nil }
            catch { self.catalogErrors[key] = error.localizedDescription }
        }
    }
    func inspectObject(_ object: CatalogObject, database: String) {
        guard linkedDatabases.contains(database) else { linkDatabase(database); return }
        currentDatabase = database
        guard canOperate else { return }
        var tab = WorkspaceTab(title: object.name, database: database); tab.sql = object.sql
        tabs.append(tab); activeID = tab.id; runQuery()
    }
}

struct CatalogDatabaseView: View {
    @EnvironmentObject var model: AppModel
    let database: String
    var body: some View {
        ForEach(CatalogKind.databaseKinds, id: \.self) { kind in
            let key = model.catalogKey(database, kind: kind)
            CatalogBranch(title: kind.rawValue, symbol: kind.symbol, expanded: model.expandedCatalog.contains(key), depth: 1) { model.toggleCatalog(database, kind: kind) }
                .contextMenu {
                    Button("刷新\(kind.rawValue)") {
                        if kind == .tables || kind == .views { model.refreshDatabase(database) }
                        else if kind != .queries && kind != .backups { model.loadCatalog(database, kind: kind) }
                    }.disabled(model.busy || kind == .queries || kind == .backups)
                    Button("复制名称") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(kind.rawValue, forType: .string) }
                }
            if model.expandedCatalog.contains(key) {
                switch kind {
                case .tables, .views:
                    let tables = (model.tables[database] ?? []).filter { $0.isView == (kind == .views) && (model.sidebarSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.sidebarSearch)) }
                    ForEach(tables) { table in CatalogTableView(table: table) }
                    if tables.isEmpty { CatalogEmpty(text: "无\(kind.rawValue)", depth: 2) }
                case .queries:
                    let queries = model.tabs.filter { $0.table == nil && $0.database == database }
                    ForEach(queries) { tab in
                        Button { model.activeID = tab.id } label: { Label(tab.title, systemImage: "terminal").lineLimit(1).padding(.leading, 36).padding(.vertical, 4) }.buttonStyle(.plain)
                    }
                    Button { model.newQuery(); model.editActive { $0.database = database } } label: { Label("新建查询", systemImage: "plus").padding(.leading, 36).padding(.vertical, 4) }.buttonStyle(.plain)
                    if queries.isEmpty { CatalogEmpty(text: "暂无查询标签", depth: 2) }
                case .backups:
                    CatalogEmpty(text: "备份功能暂未启用", depth: 2)
                default:
                    CatalogObjectsView(database: database, kind: kind, depth: 2)
                }
            }
        }
    }
}

private struct CatalogTableView: View {
    @EnvironmentObject var model: AppModel
    let table: TableReference
    var body: some View {
        let key = model.catalogKey(table.database, table: table.name)
        HStack(spacing: 5) {
            Image(systemName: model.expandedCatalog.contains(key) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 18, height: 25)
            Label(table.name, systemImage: table.isView ? "eyeglasses" : "tablecells").lineLimit(1)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 25).contentShape(Rectangle())
            .onTapGesture { model.toggleCatalog(table.database, table: table.name) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTable(table) })
            .background(model.active?.table == table ? Color.accentColor.opacity(0.16) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 5)).help(table.name)
            .contextMenu {
                Button("打开表") { model.openTable(table) }.disabled(model.busy)
                Button("刷新表目录") { model.refreshDatabase(table.database) }.disabled(model.busy)
                Divider()
                Button("复制表名") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(table.name, forType: .string) }
            }
        if model.expandedCatalog.contains(key) {
            ForEach(CatalogKind.tableKinds, id: \.self) { kind in
                let child = model.catalogKey(table.database, table: table.name, kind: kind)
                CatalogBranch(title: kind.rawValue, symbol: kind.symbol, expanded: model.expandedCatalog.contains(child), depth: 3) { model.toggleCatalog(table.database, table: table.name, kind: kind) }
                if model.expandedCatalog.contains(child) { CatalogObjectsView(database: table.database, table: table.name, kind: kind, depth: 4) }
            }
        }
    }
}

private struct CatalogBranch: View {
    let title: String
    let symbol: String
    let expanded: Bool
    let depth: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 12)
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(title); Spacer()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).padding(.leading, CGFloat(depth * 13 + 12))
        }.buttonStyle(.plain)
    }
}

private struct CatalogObjectsView: View {
    @EnvironmentObject var model: AppModel
    let database: String
    var table: String? = nil
    let kind: CatalogKind
    let depth: Int
    var body: some View {
        let key = model.catalogKey(database, table: table, kind: kind)
        if let error = model.catalogErrors[key] {
            VStack(alignment: .leading, spacing: 4) {
                Text("无法读取：\(error)").font(.caption).foregroundStyle(.secondary).lineLimit(3).help(error)
                Button("重试") { model.loadCatalog(database, table: table, kind: kind) }.disabled(!model.canOperate)
            }.padding(.leading, CGFloat(depth * 13 + 12)).padding(.vertical, 4)
        } else if let objects = model.catalog[key] {
            ForEach(objects.filter { model.sidebarSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.sidebarSearch) || table?.localizedCaseInsensitiveContains(model.sidebarSearch) == true }) { object in
                Button { model.inspectObject(object, database: database) } label: {
                    HStack(spacing: 5) { Image(systemName: kind.symbol).foregroundStyle(.secondary); Text(object.name).lineLimit(1); Spacer() }
                        .padding(.leading, CGFloat(depth * 13 + 12)).padding(.vertical, 4)
                }.buttonStyle(.plain).help(object.name + "\n" + object.detail).disabled(!model.canOperate)
                    .contextMenu {
                        Button("查看定义") { model.inspectObject(object, database: database) }.disabled(object.sql.isEmpty || !model.canOperate)
                        Button("复制名称") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(object.name, forType: .string) }
                    }
            }
            if objects.isEmpty { CatalogEmpty(text: "无\(kind.rawValue)", depth: depth) }
        } else { CatalogEmpty(text: model.busy ? "正在读取…" : "点击重新展开以读取", depth: depth) }
    }
}

private struct CatalogEmpty: View {
    let text: String
    let depth: Int
    var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, CGFloat(depth * 13 + 12)).padding(.vertical, 4) }
}
