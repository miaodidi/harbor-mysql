import Foundation

public enum CatalogKind: String, CaseIterable, Sendable {
    case tables = "表", views = "视图", routines = "函数", events = "事件", queries = "查询", backups = "备份"
    case columns = "字段", indexes = "索引", foreignKeys = "外键", checks = "检查", triggers = "触发器"
    public static let databaseKinds: [Self] = [.tables, .views, .routines, .events, .queries, .backups]
    public static let tableKinds: [Self] = [.columns, .indexes, .foreignKeys, .checks, .triggers]
    public var symbol: String {
        switch self {
        case .tables: return "tablecells.fill"
        case .views: return "eyeglasses"
        case .routines: return "function"
        case .events: return "clock.arrow.circlepath"
        case .queries: return "terminal"
        case .backups: return "externaldrive.badge.timemachine"
        case .columns: return "rectangle.split.3x1"
        case .indexes: return "list.bullet.rectangle"
        case .foreignKeys: return "link"
        case .checks: return "checkmark.circle"
        case .triggers: return "bolt.fill"
        }
    }
}

public struct CatalogObject: Identifiable, Sendable {
    public let name: String
    public let detail: String
    public let sql: String
    public var id: String { name }
    public init(name: String, detail: String, sql: String = "") { self.name = name; self.detail = detail; self.sql = sql }
}

extension MySQLSession {
    public func objects(in database: String, table: String? = nil, kind: CatalogKind) async throws -> [CatalogObject] {
        let db = SQLBuilder.literal(.text(database)), name = SQLBuilder.literal(.text(table ?? ""))
        let sql: String
        switch kind {
        case .routines:
            sql = "SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS detail FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(db) ORDER BY ROUTINE_NAME"
        case .events:
            sql = "SELECT EVENT_NAME AS name, CONCAT(STATUS, ' · ', EVENT_TYPE) AS detail FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(db) ORDER BY EVENT_NAME"
        case .columns:
            sql = "SELECT COLUMN_NAME AS name, CONCAT(COLUMN_TYPE, IF(COLUMN_KEY = 'PRI', ' · PRIMARY KEY', ''), IF(IS_NULLABLE = 'YES', ' · NULL', ' · NOT NULL')) AS detail FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(db) AND TABLE_NAME = \(name) ORDER BY ORDINAL_POSITION"
        case .indexes:
            sql = "SELECT INDEX_NAME AS name, CONCAT(IF(MIN(NON_UNIQUE) = 0, 'UNIQUE · ', ''), GROUP_CONCAT(COALESCE(COLUMN_NAME, '(expression)') ORDER BY SEQ_IN_INDEX SEPARATOR ', ')) AS detail FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(db) AND TABLE_NAME = \(name) GROUP BY INDEX_NAME ORDER BY INDEX_NAME"
        case .foreignKeys:
            sql = "SELECT CONSTRAINT_NAME AS name, GROUP_CONCAT(CONCAT(COLUMN_NAME, ' → ', REFERENCED_TABLE_SCHEMA, '.', REFERENCED_TABLE_NAME, '.', REFERENCED_COLUMN_NAME) ORDER BY ORDINAL_POSITION SEPARATOR ', ') AS detail FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = \(db) AND TABLE_NAME = \(name) AND REFERENCED_TABLE_NAME IS NOT NULL GROUP BY CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME"
        case .checks:
            sql = "SELECT tc.CONSTRAINT_NAME AS name, cc.CHECK_CLAUSE AS detail FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA = \(db) AND tc.TABLE_NAME = \(name) AND tc.CONSTRAINT_TYPE = 'CHECK' ORDER BY tc.CONSTRAINT_NAME"
        case .triggers:
            sql = "SELECT TRIGGER_NAME AS name, CONCAT(ACTION_TIMING, ' ', EVENT_MANIPULATION, ' · ', ACTION_STATEMENT) AS detail FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(db) AND EVENT_OBJECT_TABLE = \(name) ORDER BY TRIGGER_NAME"
        default: return []
        }
        return try await execute(sql).records().map { record in
            let objectName = record["name"]?.text ?? "", detail = record["detail"]?.text ?? ""
            let qualified = SQLBuilder.identifier(database) + "." + SQLBuilder.identifier(objectName)
            let inspect: String
            switch kind {
            case .routines: inspect = "SHOW CREATE \(detail == "PROCEDURE" ? "PROCEDURE" : "FUNCTION") \(qualified);"
            case .events: inspect = "SHOW CREATE EVENT \(qualified);"
            case .triggers: inspect = "SHOW CREATE TRIGGER \(qualified);"
            default: inspect = "SHOW CREATE TABLE \(SQLBuilder.identifier(database)).\(SQLBuilder.identifier(table ?? ""));"
            }
            return CatalogObject(name: objectName, detail: detail, sql: inspect)
        }
    }
}
