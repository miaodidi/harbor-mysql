import Foundation

public enum TLSMode: String, Codable, CaseIterable, Sendable {
    case disabled, required, verified
    public var title: String {
        switch self {
        case .disabled: return "关闭（本地 / 可信网络）"
        case .required: return "加密，不验证证书"
        case .verified: return "加密并验证证书"
        }
    }
}

public struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    public var tls: TLSMode
    public var rememberPassword: Bool
    public init(id: UUID = UUID(), name: String = "本地开发", host: String = "127.0.0.1", port: Int = 3306,
                username: String = "root", database: String = "", tls: TLSMode = .disabled, rememberPassword: Bool = true) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.username = username
        self.database = database; self.tls = tls; self.rememberPassword = rememberPassword
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.isEmpty, (1...65535).contains(port) else {
            throw HarborError.message("请填写连接名称、主机和用户名，端口应在 1–65535 之间。")
        }
    }
}

public enum HarborError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum CellValue: Equatable, Sendable {
    case null
    case text(String)
    case binary(Data)
    public var text: String? { if case .text(let value) = self { return value }; return nil }
    public var display: String {
        switch self {
        case .null: return "NULL"
        case .text(let text): return text
        case .binary(let data): return "0x" + data.prefix(512).map { String(format: "%02X", $0) }.joined() + (data.count > 512 ? "…" : "")
        }
    }
}

public struct ResultColumn: Equatable, Sendable {
    public var name: String
    public var type: String
    public init(name: String, type: String = "") { self.name = name; self.type = type }
}

public struct QueryResult: Sendable {
    public let id = UUID()
    public var columns: [ResultColumn] = []
    public var rows: [[CellValue]] = []
    public var affectedRows: UInt64 = 0
    public var elapsed: TimeInterval = 0
    public var truncated = false
    public init() {}
    public func records() -> [[String: CellValue]] {
        rows.map { row in
            var record: [String: CellValue] = [:]
            for (column, value) in zip(columns, row) { record[column.name] = value }
            return record
        }
    }
}

public struct TableReference: Hashable, Identifiable, Sendable {
    public let database: String
    public let name: String
    public let isView: Bool
    public var id: String { database + "\0" + name }
    public init(database: String, name: String, isView: Bool = false) { self.database = database; self.name = name; self.isView = isView }
}

public struct TableColumn: Identifiable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let primaryKey: Bool
    public let generated: Bool
    public let binary: Bool
    public var id: String { name }
    public init(name: String, type: String, nullable: Bool = true, primaryKey: Bool = false, generated: Bool = false, binary: Bool = false) {
        self.name = name; self.type = type; self.nullable = nullable; self.primaryKey = primaryKey; self.generated = generated; self.binary = binary
    }
}

public struct TableInfo: Sendable {
    public var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
}

public enum SortDirection: String, CaseIterable, Codable, Sendable { case ascending = "ASC", descending = "DESC" }
public struct SortRule: Equatable, Sendable {
    public var column: String
    public var direction: SortDirection
    public init(column: String, direction: SortDirection) { self.column = column; self.direction = direction }
}
public enum FilterOperator: String, CaseIterable, Sendable {
    case equals = "等于", contains = "包含", greater = "大于", less = "小于", isNull = "是 NULL", isNotNull = "不是 NULL"
}
public struct FilterRule: Equatable, Sendable {
    public var column: String
    public var operation: FilterOperator
    public var value: String
    public init(column: String, operation: FilterOperator, value: String = "") { self.column = column; self.operation = operation; self.value = value }
}
