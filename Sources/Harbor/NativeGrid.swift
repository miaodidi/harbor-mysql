import AppKit
import SwiftUI
import HarborCore

struct NativeGrid: NSViewRepresentable {
    let result: QueryResult
    let sort: SortRule?
    let sortable: Bool
    let onSort: (String, SortDirection?) -> Void
    let onSelect: (Int, Int, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = DataTableView()
        table.style = .plain
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.4)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.selectionHighlightStyle = .regular
        table.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 49))
        table.target = context.coordinator; table.action = #selector(Coordinator.clicked); table.doubleAction = #selector(Coordinator.doubleClicked)
        table.copyAction = { [weak coordinator = context.coordinator] in coordinator?.copyCell() }
        (table.headerView as? GridHeaderView)?.makeMenu = { [weak coordinator = context.coordinator] index in coordinator?.menu(for: index) }
        context.coordinator.table = table; scroll.documentView = table
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        let signature = result.columns.map { $0.name + "\0" + $0.type }
        if signature != coordinator.signature {
            coordinator.signature = signature
            // AppKit may synchronously request old row views while columns are replaced.
            // Invalidate cached row counts before changing the column collection.
            table.reloadData()
            let oldWidths = Dictionary(table.tableColumns.map { ($0.identifier.rawValue, $0.width) }, uniquingKeysWith: { a, _ in a })
            for c in table.tableColumns { table.removeTableColumn(c) }
            let number = NSTableColumn(identifier: .init("row-number")); number.title = "#"; number.width = 42; number.minWidth = 35; table.addTableColumn(number)
            for (index, column) in result.columns.enumerated() {
                let c = NSTableColumn(identifier: .init("field-\(index)-\(column.name)"))
                c.headerCell = GridHeaderCell(textCell: column.name)
                let defaultWidth: CGFloat = column.name == "id" ? 70 : column.name == "status" ? 90 : column.name.lowercased().contains("email") ? 190 : column.type.contains("time") ? 180 : 120
                c.width = oldWidths[c.identifier.rawValue] ?? defaultWidth
                c.minWidth = 65; c.maxWidth = 1200; table.addTableColumn(c)
            }
        }
        for (index, column) in result.columns.enumerated() {
            guard index + 1 < table.tableColumns.count, let header = table.tableColumns[index+1].headerCell as? GridHeaderCell else { continue }
            header.fieldName = column.name; header.fieldType = column.type
            header.indicator = sortable ? (sort?.column == column.name ? (sort?.direction == .ascending ? "↑" : "↓") : "⌄") : ""
        }
        table.headerView?.needsDisplay = true
        if coordinator.resultID != result.id {
            coordinator.resultID = result.id; coordinator.selectedCell = nil; table.deselectAll(nil); table.reloadData()
            // The floating header is represented by a top content inset. An origin
            // of zero scrolls the first rows under it; include that inset on reset.
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentView.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeGrid
        weak var table: NSTableView?
        var signature: [String] = []
        var resultID: UUID?
        var selectedCell: (row: Int, column: Int)?
        var updating = false
        private var menuActions: [MenuAction] = []
        init(_ parent: NativeGrid) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
            guard parent.result.rows.indices.contains(row), index == 0 || parent.result.rows[row].indices.contains(index - 1) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("data-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
            let value: CellValue = index == 0 ? .text(String(row+1)) : parent.result.rows[row][index-1]
            cell.textField?.stringValue = value.display
            cell.textField?.textColor = index == 0 || value == .null ? .secondaryLabelColor : .labelColor
            cell.toolTip = String(value.display.prefix(2000))
            return cell
        }
        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = id
            let label = NSTextField(labelWithString: ""); label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        @objc func clicked() { select(open: false) }
        @objc func doubleClicked() { select(open: true) }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, table.selectedRow >= 0, !parent.result.columns.isEmpty else { return }
            let column = min(selectedCell?.column ?? 0, parent.result.columns.count - 1)
            selectedCell = (table.selectedRow, column)
            parent.onSelect(table.selectedRow, column, false)
        }
        private func select(open: Bool) {
            guard let table, table.clickedRow >= 0, table.clickedColumn > 0 else { return }
            selectedCell = (table.clickedRow, table.clickedColumn - 1)
            parent.onSelect(table.clickedRow, table.clickedColumn - 1, open)
        }
        func copyCell() {
            guard let s = selectedCell, parent.result.rows.indices.contains(s.row), parent.result.columns.indices.contains(s.column) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(parent.result.rows[s.row][s.column].display, forType: .string)
        }
        func menu(for index: Int) -> NSMenu? {
            guard parent.sortable, index > 0, index <= parent.result.columns.count else { return nil }
            let name = parent.result.columns[index-1].name
            let menu = NSMenu(); menuActions = []
            for (title, direction) in [("升序排序", SortDirection.ascending as SortDirection?), ("降序排序", SortDirection.descending as SortDirection?), ("清除排序", nil)] {
                let action = MenuAction { [weak self] in self?.parent.onSort(name, direction) }; menuActions.append(action)
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: ""); item.target = action
                if let direction, parent.sort?.column == name && parent.sort?.direction == direction { item.state = .on }
                menu.addItem(item)
            }
            return menu
        }
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
private final class DataTableView: NSTableView {
    var copyAction: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyAction?() }
        else { super.keyDown(with: event) }
    }
}
private final class GridHeaderView: NSTableHeaderView {
    var makeMenu: ((Int) -> NSMenu?)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            if rect.intersects(dirtyRect) { column.headerCell.draw(withFrame: rect, in: self) }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), index = column(at: convert(event.locationInWindow, from: nil))
        if index >= 0 {
            let rect = headerRect(ofColumn: index)
            if abs(point.x - rect.maxX) < 7 || abs(point.x - rect.minX) < 7 { super.mouseDown(with: event); return }
        }
        if let menu = makeMenu?(index) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?(column(at: convert(event.locationInWindow, from: nil))) }
}
private final class GridHeaderCell: NSTableHeaderCell {
    var fieldName = "", fieldType = "", indicator = ""
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.controlBackgroundColor.setFill(); cellFrame.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: cellFrame.maxX-0.5, y: cellFrame.minY)); line.line(to: NSPoint(x: cellFrame.maxX-0.5, y: cellFrame.maxY)); line.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (fieldName as NSString).draw(in: NSRect(x: cellFrame.minX+8, y: cellFrame.minY+6, width: cellFrame.width-30, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        (fieldType as NSString).draw(in: NSRect(x: cellFrame.minX+8, y: cellFrame.minY+25, width: cellFrame.width-15, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemBlue, .paragraphStyle: paragraph])
        (indicator as NSString).draw(at: NSPoint(x: cellFrame.maxX-19, y: cellFrame.minY+7), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
