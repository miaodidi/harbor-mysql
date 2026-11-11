import XCTest
@testable import HarborCore

final class SQLBuilderTests: XCTestCase {
    func testIdentifierAndUnicodeLiteralEscaping() {
        XCTAssertEqual(SQLBuilder.identifier("a`b"), "`a``b`")
        XCTAssertEqual(SQLBuilder.literal(.text("'\\\0")), "_utf8mb4 X'275C00'")
        XCTAssertEqual(SQLBuilder.literal(.null), "NULL")
        XCTAssertEqual(SQLBuilder.literal(.binary(Data([0, 255]))), "X'00FF'")
        XCTAssertEqual(SQLBuilder.literal(.text("你好🐬")), "_utf8mb4 '你好🐬'")
        XCTAssertEqual(SQLBuilder.literal(.text("O'Reilly")), "_utf8mb4 'O''Reilly'")
    }
    func testPaginationAndClearSort() throws {
        let table = TableReference(database: "demo", name: "users")
        let sorted = try SQLBuilder.select(table: table, columns: ["id"], sort: SortRule(column: "id", direction: .descending), page: 2)
        XCTAssertEqual(sorted, "SELECT `id` FROM `demo`.`users` ORDER BY `id` DESC LIMIT 200, 100;")
        XCTAssertFalse(try SQLBuilder.select(table: table, columns: ["id"]).contains("ORDER BY"))
        XCTAssertThrowsError(try SQLBuilder.select(table: table, columns: []))
        XCTAssertThrowsError(try SQLBuilder.select(table: table, columns: ["id"], page: -1))
        XCTAssertEqual(try SQLBuilder.select(table: table, columns: ["id", "name"], allColumns: true), "SELECT * FROM `demo`.`users` LIMIT 0, 100;")
        XCTAssertEqual(try SQLBuilder.select(table: table, columns: ["id"], allColumns: false), "SELECT `id` FROM `demo`.`users` LIMIT 0, 100;")
    }
    func testNullAndContainsFilters() throws {
        let table = TableReference(database: "demo", name: "users")
        XCTAssertTrue(try SQLBuilder.select(table: table, columns: ["name"], filter: FilterRule(column: "name", operation: .isNull)).contains("`name` IS NULL"))
        let sql = try SQLBuilder.select(table: table, columns: ["name"], filter: FilterRule(column: "name", operation: .contains, value: "%_!"))
        XCTAssertTrue(sql.contains("ESCAPE '!'")); XCTAssertTrue(sql.contains("%!%!_!!%"))
    }
    func testUpdateRequiresPrimaryKeyAndOriginalValue() throws {
        let table = TableReference(database: "demo", name: "users")
        let id = TableColumn(name: "id", type: "int", primaryKey: true)
        let name = TableColumn(name: "name", type: "text")
        let sql = try SQLBuilder.update(table: table, column: name, value: .text("new"), original: ["id": .text("1"), "name": .null], schema: [id,name])
        XCTAssertTrue(sql.contains("BINARY `name` <=> BINARY NULL")); XCTAssertTrue(sql.hasSuffix("LIMIT 1;"))
        XCTAssertThrowsError(try SQLBuilder.update(table: table, column: name, value: .text("new"), original: ["name": .null], schema: [id,name]))
        XCTAssertThrowsError(try SQLBuilder.update(table: table, column: id, value: .text("2"), original: ["id": .text("1")], schema: [id,name]))
        XCTAssertThrowsError(try SQLBuilder.update(table: table, column: name, value: .text("new"), original: ["name": .null], schema: [name]))
    }
    func testWriteConfirmation() {
        XCTAssertFalse(SQLBuilder.requiresWriteConfirmation("/* hello */\nSELECT 1;"))
        XCTAssertFalse(SQLBuilder.requiresWriteConfirmation("-- read\nSHOW TABLES"))
        XCTAssertTrue(SQLBuilder.requiresWriteConfirmation("DELETE FROM users"))
        XCTAssertTrue(SQLBuilder.requiresWriteConfirmation("WITH ids AS (SELECT 1) DELETE FROM users"))
        XCTAssertTrue(SQLBuilder.requiresWriteConfirmation("SELECT 1 INTO OUTFILE '/tmp/test'"))
        XCTAssertTrue(SQLBuilder.requiresWriteConfirmation("/*!50000 DROP TABLE users */"))
    }
    func testProfilePersistenceContainsNoPassword() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(file: dir.appendingPathComponent("connections.json"))
        let profile = ConnectionProfile(name: "测试", tls: .required)
        try store.save([profile]); XCTAssertEqual(try store.load(), [profile])
        let json = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(json.contains("\"password\""))
        XCTAssertThrowsError(try ConnectionProfile(port: 99999).validate())
    }
}
