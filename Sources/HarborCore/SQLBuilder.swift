import Foundation

public enum SQLBuilder {
    public static func identifier(_ value: String) -> String { "`" + value.replacingOccurrences(of: "`", with: "``") + "`" }
    public static func table(_ reference: TableReference) -> String { identifier(reference.database) + "." + identifier(reference.name) }
    // Hex literals work regardless of NO_BACKSLASH_ESCAPES and safely preserve Unicode, quotes and NUL.
    public static func literal(_ value: CellValue) -> String {
        switch value {
        case .null: return "NULL"
        case .text(let text):
            if !text.contains("\\") && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "_utf8mb4 '" + text.replacingOccurrences(of: "'", with: "''") + "'"
            }
            return "_utf8mb4 X'" + Data(text.utf8).map { String(format: "%02X", $0) }.joined() + "'"
        case .binary(let bytes): return "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        }
    }
    public static func select(table reference: TableReference, columns: [String], filter: FilterRule? = nil, sort: SortRule? = nil,
                              page: Int = 0, pageSize: Int = 100) throws -> String {
        guard !columns.isEmpty, page >= 0, (1...1000).contains(pageSize), page <= Int.max / pageSize else {
            throw HarborError.message("请至少显示一列，并使用有效的分页大小。")
        }
        var sql = "SELECT " + columns.map(identifier).joined(separator: ", ") + " FROM " + table(reference)
        if let filter {
            let field = identifier(filter.column)
            switch filter.operation {
            case .isNull: sql += " WHERE \(field) IS NULL"
            case .isNotNull: sql += " WHERE \(field) IS NOT NULL"
            case .contains:
                let pattern = "%" + filter.value.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_") + "%"
                sql += " WHERE \(field) LIKE \(literal(.text(pattern))) ESCAPE '!'"
            default:
                let op = filter.operation == .equals ? "=" : filter.operation == .greater ? ">" : "<"
                sql += " WHERE \(field) \(op) \(literal(.text(filter.value)))"
            }
        }
        if let sort { sql += " ORDER BY \(identifier(sort.column)) \(sort.direction.rawValue)" }
        return sql + " LIMIT \(page * pageSize), \(pageSize);"
    }
    public static func update(table reference: TableReference, column: TableColumn, value: CellValue,
                              original: [String: CellValue], schema: [TableColumn]) throws -> String {
        guard !reference.isView, !column.primaryKey, !column.generated, !column.binary else { throw HarborError.message("该字段只读。主键、生成列、二进制列及视图暂不支持编辑。") }
        if value == .null && !column.nullable { throw HarborError.message("该字段不允许 NULL。") }
        let keys = schema.filter(\.primaryKey)
        guard !keys.isEmpty, keys.allSatisfy({ original[$0.name] != nil }), let old = original[column.name] else {
            throw HarborError.message("编辑需要完整主键，请显示主键列；没有主键的表仅支持浏览。")
        }
        var predicates = keys.map { identifier($0.name) + " <=> " + literal(original[$0.name]!) }
        predicates.append("BINARY " + identifier(column.name) + " <=> BINARY " + literal(old))
        return "UPDATE \(table(reference)) SET \(identifier(column.name)) = \(literal(value)) WHERE " + predicates.joined(separator: " AND ") + " LIMIT 1;"
    }

    public static func requiresWriteConfirmation(_ sql: String) -> Bool {
        // Only recognize a conservative read-only prefix; unknown/CTE statements require confirmation.
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            if text.hasPrefix("-- ") || text.hasPrefix("#") {
                text = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("/*"), !text.hasPrefix("/*!"), let end = text.range(of: "*/") {
                text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else { break }
        }
        let upper = text.uppercased()
        let word = upper.prefix { $0.isLetter }
        guard ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"].contains(String(word)) else { return true }
        return upper.contains("INTO OUTFILE") || upper.contains("INTO DUMPFILE")
    }
}
