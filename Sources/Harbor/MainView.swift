import SwiftUI
import HarborCore
import AppKit

private struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        init(_ parent: SQLTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let textView = NSTextView()
        textView.delegate = context.coordinator; textView.isEditable = isEditable
        textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor; textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 58); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 58)
        textView.string = text
        scroll.documentView = textView
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // SwiftUI may redraw this view after every keystroke. Only replace the
        // text when an external value changed, preserving the insertion point.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView().frame(minWidth: 185, idealWidth: 260, maxWidth: 380)
                VStack(spacing: 0) {
                    if !model.tabs.isEmpty { tabStrip; Divider() }
                    if let tab = model.active { WorkspaceView(tab: tab).id(tab.id) }
                    else { welcome }
                }.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.openConnectionSheet() } label: { Label("新建连接", systemImage: "cable.connector") }.disabled(model.busy)
                Button { model.newQuery() } label: { Label("新建查询", systemImage: "terminal") }
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(!model.canOperate)
            }
            ToolbarItem(placement: .principal) { Text(model.connectedProfile?.name ?? "Harbor").fontWeight(.medium) }
            ToolbarItem(placement: .automatic) {
                Button { model.showInspector.toggle() } label: { Label("表信息", systemImage: "sidebar.right") }.help("显示或隐藏表信息")
            }
        }
        .sheet(isPresented: $model.connectionSheet) { ConnectionSheet(profile: model.editingProfile).environmentObject(model) }
        .sheet(isPresented: $model.writeConfirmation) { writeSheet }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    HStack(spacing: 8) {
                        Button { model.activeID = tab.id } label: { Label(tab.title, systemImage: tab.table == nil ? "terminal" : "tablecells").padding(.vertical, 11) }.buttonStyle(.plain)
                        Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).disabled(model.busy).help("关闭标签")
                    }
                    .padding(.horizontal, 14)
                    .background(model.activeID == tab.id ? Color(nsColor: .textBackgroundColor) : Color.clear)
                    .overlay(alignment: .bottom) { if model.activeID == tab.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                    Divider().frame(height: 30)
                }
                Button { model.newQuery() } label: { Image(systemName: "plus") }.buttonStyle(.plain).padding(12)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentColor)
            Text(model.connectedID == nil ? "从一个连接开始" : "选择一张表，或开始查询").font(.title2.weight(.medium))
            Text(model.connectedID == nil ? "连接 MySQL，浏览数据、筛选排序和执行 SQL。" : "在左侧展开数据库，双击表名即可打开。")
                .foregroundStyle(.secondary)
            Button(model.connectedID == nil ? "新建连接" : "新建查询") {
                if model.connectedID == nil { model.openConnectionSheet() } else { model.newQuery() }
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("Harbor · 开源 MySQL 客户端").font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.connectedID == nil ? Color.secondary : Color.green).frame(width: 6, height: 6)
            if let profile = model.connectedProfile {
                Text("已连接 \(profile.username)@\(profile.host):\(profile.port)")
                Text("MySQL \(model.serverVersion)").foregroundStyle(.secondary)
            } else { Text("未连接") }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small); Text(model.activity)
                Button("取消并断开") { model.cancel() }.buttonStyle(.link)
            } else { Text("UTF-8").foregroundStyle(.secondary) }
        }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 29).background(Color(nsColor: .controlBackgroundColor))
    }
    private var writeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("确认执行修改", systemImage: "pencil.line").font(.headline)
            Text("这条语句可能更改数据库。请确认目标连接和 SQL。")
            Text("\(model.connectedProfile?.name ?? "") / \(model.active?.database ?? "")").foregroundStyle(.secondary)
            ScrollView { Text(model.pendingSQL).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(12).frame(height: 160).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("取消", role: .cancel) { model.writeConfirmation = false }; Button("执行") { model.writeConfirmation = false; model.confirmWrite() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 600)
    }
}

private struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text("连接").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { model.openConnectionSheet() } label: { Image(systemName: "plus") }.buttonStyle(.plain).disabled(model.busy) }.padding(.horizontal, 14).padding(.top, 16)
            TextField("搜索表…", text: $model.sidebarSearch).textFieldStyle(.roundedBorder).padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: model.connectedID == profile.id ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                Image(systemName: "externaldrive").foregroundStyle(model.connectedID == profile.id ? Color.accentColor : Color.secondary)
                                Text(profile.name).lineLimit(1); Spacer()
                                if model.connectedID == profile.id { Circle().fill(.green).frame(width: 5, height: 5) }
                            }.padding(.vertical, 7).contentShape(Rectangle()).onTapGesture(count: 2) { model.connect(profile) }
                            .contextMenu {
                                Button("连接") { model.connect(profile) }.disabled(model.busy)
                                if model.connectedID == profile.id { Button("断开连接") { model.disconnect() }.disabled(model.busy) }
                                Button("编辑连接…") { model.openConnectionSheet(profile) }.disabled(model.busy)
                                Divider()
                                Button("删除连接…", role: .destructive) { delete(profile) }.disabled(model.busy)
                            }
                            if model.connectedID == profile.id {
                                ForEach(model.databases, id: \.self) { db in
                                    Button { model.toggleDatabase(db) } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: model.expandedDatabases.contains(db) ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                            Image(systemName: "cylinder").foregroundStyle(model.linkedDatabases.contains(db) ? Color.green : Color.secondary)
                                            Text(db).foregroundStyle(model.linkedDatabases.contains(db) ? .primary : .secondary).lineLimit(1); Spacer()
                                            if model.linkedDatabases.contains(db) { Circle().fill(.green).frame(width: 5, height: 5) }
                                        }.padding(.vertical, 5)
                                    }.buttonStyle(.plain).padding(.leading, 12)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.linkDatabase(db) })
                                    .contextMenu {
                                        if model.linkedDatabases.contains(db) {
                                            Button("设为当前数据库") { model.selectDatabase(db) }.disabled(model.busy || model.currentDatabase == db)
                                            Button("断开数据库") { model.unlinkDatabase(db) }.disabled(model.busy)
                                        } else {
                                            Button("连接数据库") { model.linkDatabase(db) }.disabled(model.busy)
                                        }
                                        Button("新建查询") { model.newQuery(); model.editActive { $0.database = db } }.disabled(model.busy)
                                        Button("刷新") { model.refreshDatabase(db) }.disabled(model.busy || !model.linkedDatabases.contains(db))
                                        Divider()
                                        Button("复制数据库名称") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(db, forType: .string) }
                                    }
                                    if model.expandedDatabases.contains(db) && model.linkedDatabases.contains(db) {
                                        CatalogDatabaseView(database: db)
                                    }
                                }
                            }
                        }
                    }
                }.font(.system(size: 12)).padding(.horizontal, 10)
            }
            if model.profiles.isEmpty { Text("点击 + 添加 MySQL 连接").font(.caption).foregroundStyle(.secondary).padding() }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func delete(_ profile: ConnectionProfile) {
        let alert = NSAlert(); alert.messageText = "删除连接“\(profile.name)”？"; alert.informativeText = "将移除本机配置和钥匙串密码，数据库不会被删除。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.deleteProfile(profile) }
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let tab: WorkspaceTab
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if tab.table != nil {
                    tableToolbar
                    if tab.filterVisible { Divider(); FilterPanel(tab: tab) }
                } else { queryEditor }
                Divider()
                HStack { Label(tab.table?.name ?? "查询结果", systemImage: "tablecells"); Spacer(); Text(tab.status).foregroundStyle(.secondary) }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 31)
                Divider()
                ZStack {
                    NativeGrid(result: tab.result, sort: tab.sort, sortable: tab.table != nil && model.canUseTableTools,
                        onSort: { model.sort(column: $0, direction: $1) }, onSelect: { model.selectCell(row: $0, column: $1, openEditor: $2) })
                    if tab.result.rows.isEmpty && !model.busy {
                        Text(tab.executedSQL.isEmpty ? "执行查询后，结果将显示在这里" : tab.result.columns.isEmpty ? "语句已执行" : "没有符合条件的数据")
                            .foregroundStyle(.secondary).font(.callout).allowsHitTesting(false)
                    }
                }.frame(minHeight: 150, maxHeight: .infinity)
                if tab.editorVisible && tab.table != nil { Divider(); CellEditor(tab: tab) }
                Divider()
                sqlFooter
                if tab.table != nil && tab.customSQL == nil { Divider(); pagination }
            }.frame(minWidth: 490, maxWidth: .infinity)
            if model.showInspector && tab.table != nil { InspectorView(tab: tab).frame(minWidth: 176, idealWidth: 190, maxWidth: 220) }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var tableToolbar: some View {
        HStack(spacing: 8) {
            Button { model.editActive { $0.editorVisible.toggle() } } label: { Label("编辑器", systemImage: "square.and.pencil") }.tint(tab.editorVisible ? .accentColor : nil)
            Button { model.editActive { $0.filterVisible.toggle() } } label: { Label("筛选 & 排序", systemImage: "line.3.horizontal.decrease") }.tint(tab.filterVisible ? .accentColor : nil)
            Menu {
                Button("反转选择") { model.invertColumns() }
                Divider()
                ForEach(tab.schema) { column in
                    Toggle(column.name, isOn: Binding(get: { tab.visibleColumns.contains(column.name) }, set: { model.setColumn(column.name, visible: $0) }))
                        .disabled(!model.canUseTableTools || (tab.visibleColumns.count == 1 && tab.visibleColumns.contains(column.name)))
                }
            } label: { Label("列", systemImage: "rectangle.split.3x1") }.fixedSize()
            Spacer()
        }.disabled(!model.canUseTableTools).controlSize(.small).padding(.horizontal, 12).frame(height: 44).background(Color(nsColor: .controlBackgroundColor))
    }
    private var queryEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.runQuery() } label: { Label("运行 ⌘↵", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(!model.canOperate)
                Picker("数据库", selection: Binding(get: { tab.database }, set: { value in model.editActive { $0.database = value } })) {
                    Text("未选择").tag(""); ForEach(model.databases, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 270).disabled(model.busy)
                Spacer()
                Button("导出 SQL") { model.exportSQL() }
            }.controlSize(.small).padding(10)
            TextEditor(text: Binding(get: { tab.sql }, set: { value in model.editActive { $0.sql = value } }))
                .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(.horizontal, 8).frame(height: 160)
        }
    }
    private var sqlFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tab.table != nil {
                HStack(spacing: 8) {
                    Label(tab.customSQL == nil ? "实时 SQL" : "自定义 SQL · 结果只读", systemImage: "terminal").foregroundStyle(Color.accentColor)
                    if tab.footerDirty { Text("未保存").foregroundStyle(.orange) }
                    Spacer()
                    if tab.customSQL != nil || tab.footerDirty { Button("恢复表浏览") { model.restoreTableSQL() }.disabled(!model.canOperate) }
                    Button("保存并刷新") { model.saveFooter() }.buttonStyle(.borderedProminent).disabled(!model.canOperate || tab.footerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab.footerDraft, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("复制 SQL")
                }.font(.system(size: 11)).controlSize(.small)
                SQLTextEditor(text: Binding(get: { tab.footerDraft }, set: { value in model.editActive { $0.footerDraft = value } }), isEditable: !model.busy)
                    .frame(height: 58)
                    .accessibilityLabel("底部 SQL 编辑器")
            } else {
                Text(tab.executedSQL.isEmpty ? "等待查询…" : tab.executedSQL)
                    .font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled).help(tab.executedSQL).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(10).background(Color(nsColor: .controlBackgroundColor))
    }
    private var pagination: some View {
        HStack(spacing: 12) {
            Text("本页 \(tab.result.rows.count) 行").foregroundStyle(.secondary)
            Spacer()
            Text("每页 \(tab.pageSize) 行").foregroundStyle(.secondary)
            Button { model.page(-1) } label: { Image(systemName: "chevron.left") }.disabled(!model.canUseTableTools || tab.page == 0)
            Text("第 \(tab.page+1) 页").monospacedDigit()
            Button { model.page(1) } label: { Image(systemName: "chevron.right") }.disabled(!model.canUseTableTools || !tab.canNext)
        }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 12).frame(height: 34)
    }
}

private struct FilterPanel: View {
    @EnvironmentObject var model: AppModel
    let tab: WorkspaceTab
    @State private var field = ""
    @State private var operation = FilterOperator.equals
    @State private var value = ""
    @State private var sortField = ""
    @State private var direction = SortDirection.ascending
    @State private var enabled = false
    @State private var sortEnabled = false
    @State private var suggestions: [String] = []
    @State private var showingSuggestions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Toggle("筛选", isOn: $enabled).toggleStyle(.checkbox).frame(width: 76, alignment: .leading)
                Picker("字段", selection: $field) { ForEach(tab.schema) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 150)
                Picker("条件", selection: $operation) { ForEach(FilterOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 120)
                TextField("筛选值", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .disabled(operation == .isNull || operation == .isNotNull)
                    .onTapGesture { showingSuggestions = !suggestions.isEmpty }
                    .onChange(of: value) { _, newValue in refreshSuggestions(newValue) }
                    .popover(isPresented: $showingSuggestions, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("建议值").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 7)
                            Divider()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(suggestions, id: \.self) { suggestion in
                                        Button { value = suggestion; showingSuggestions = false } label: {
                                            Text(suggestion).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }.frame(width: 220, height: min(CGFloat(max(80, suggestions.count * 30 + 34)), 220))
                    }
                Spacer()
            }
            HStack(spacing: 9) {
                Toggle("排序", isOn: $sortEnabled).toggleStyle(.checkbox).frame(width: 76, alignment: .leading)
                Picker("排序字段", selection: $sortField) { Text("选择字段").tag(""); ForEach(tab.schema) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 150).disabled(!sortEnabled)
                Picker("方向", selection: $direction) { Text("升序").tag(SortDirection.ascending); Text("降序").tag(SortDirection.descending) }.labelsHidden().frame(width: 120).disabled(!sortEnabled)
                Spacer()
                Button("清除") { enabled = false; value = ""; sortEnabled = false; sortField = ""; model.applyFilter(nil, sort: nil) }
                Button("应用") { model.applyFilter(enabled ? FilterRule(column: field, operation: operation, value: value) : nil, sort: sortEnabled && !sortField.isEmpty ? SortRule(column: sortField, direction: direction) : nil) }.buttonStyle(.borderedProminent)
            }
        }.controlSize(.small).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 88, maxHeight: 104, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).disabled(!model.canUseTableTools)
        .onAppear { field = tab.filter?.column ?? tab.schema.first?.name ?? ""; operation = tab.filter?.operation ?? .equals; value = tab.filter?.value ?? ""; enabled = tab.filter != nil; sortEnabled = tab.sort != nil; syncSort(); refreshSuggestions(value) }
        .onChange(of: tab.sort) { _, _ in syncSort() }
        .onChange(of: field) { _, _ in refreshSuggestions(value) }
    }
    private func syncSort() { sortField = tab.sort?.column ?? ""; direction = tab.sort?.direction ?? .ascending; sortEnabled = tab.sort != nil }
    private func refreshSuggestions(_ query: String) {
        guard operation != .isNull, operation != .isNotNull, !field.isEmpty, model.canUseTableTools else { suggestions = []; return }
        let expected = query
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            let values = await model.filterSuggestions(for: tab, column: field, query: expected)
            guard value == expected else { return }
            suggestions = values
            showingSuggestions = !values.isEmpty
        }
    }
}

private struct CellEditor: View {
    @EnvironmentObject var model: AppModel
    let tab: WorkspaceTab
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("字段编辑器").fontWeight(.medium)
                if let column = model.editableColumn { Text(column.name + " · " + column.type).foregroundStyle(.secondary) }
                Spacer()
                Button { model.editActive { $0.editorVisible = false } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if tab.selectedRow != nil {
                TextEditor(text: Binding(get: { tab.editValue }, set: { value in model.editActive { $0.editValue = value } }))
                    .font(.system(size: 12, design: .monospaced)).frame(height: 70).disabled(!model.canEditCell || tab.editNull)
                HStack {
                    Toggle("NULL", isOn: Binding(get: { tab.editNull }, set: { value in model.editActive { $0.editNull = value } })).disabled(!model.canEditCell || model.editableColumn?.nullable != true)
                    Text(model.canEditCell ? "按主键定位，保存前确认 SQL" : "只读：需要主键列；主键、二进制和生成列不能编辑").foregroundStyle(.secondary).lineLimit(2)
                    Spacer(); Button("保存修改") { model.saveCell() }.buttonStyle(.borderedProminent).disabled(!model.canEditCell)
                }
            } else { Text("点击单元格查看内容，双击可直接打开编辑器。").foregroundStyle(.secondary).padding(.vertical, 10) }
        }.controlSize(.small).font(.system(size: 11)).padding(12).background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct InspectorView: View {
    let tab: WorkspaceTab
    private let fields = [("TABLE_ROWS", "行数（估算）"), ("DATA_LENGTH", "数据长度（字节）"), ("ENGINE", "引擎"), ("CREATE_TIME", "创建日期"), ("UPDATE_TIME", "修改日期"), ("TABLE_COLLATION", "排序规则"), ("ROW_FORMAT", "行格式"), ("INDEX_LENGTH", "索引长度（字节）"), ("AUTO_INCREMENT", "自动递增")]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("表信息", systemImage: "info.circle").foregroundStyle(Color.accentColor)
                HStack(spacing: 10) {
                    Image(systemName: "tablecells.fill").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) { Text(tab.title).font(.headline); Text(tab.table?.isView == true ? "视图" : "表").foregroundStyle(.secondary) }
                }
                Label(tab.database, systemImage: "cylinder").textSelection(.enabled)
                Divider()
                ForEach(fields, id: \.0) { field in
                    VStack(alignment: .leading, spacing: 4) { Text(field.1).foregroundStyle(.secondary); Text(tab.info.values[field.0] ?? "—").textSelection(.enabled) }
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(15)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}
