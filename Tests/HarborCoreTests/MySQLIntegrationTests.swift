import XCTest
@testable import HarborCore

final class MySQLIntegrationTests: XCTestCase {
    func testLiveMySQLLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["HARBOR_TEST_PORT"], let port = Int(text) else { throw XCTSkip("Set HARBOR_TEST_PORT to run against a disposable local MySQL server.") }
        let profile = ConnectionProfile(name: "Integration", host: "127.0.0.1", port: port, username: env["HARBOR_TEST_USER"] ?? "root")
        let password = env["HARBOR_TEST_PASSWORD"] ?? ""
        let database = "harbor_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let session = MySQLSession()
        do {
            let version = try await session.connect(profile, password: password); XCTAssertFalse(version.isEmpty)
            _ = try await session.execute("CREATE DATABASE \(SQLBuilder.identifier(database)) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
            let table = TableReference(database: database, name: "odd`table")
            _ = try await session.execute("CREATE TABLE \(SQLBuilder.table(table)) (id INT PRIMARY KEY, name VARCHAR(255) NULL, amount DECIMAL(20,4), payload VARBINARY(10), created_at DATETIME)")
            let unusual = "你好🐬 O'Reilly\\%_!"
            _ = try await session.execute("INSERT INTO \(SQLBuilder.table(table)) VALUES (1,\(SQLBuilder.literal(.text(unusual))),1234567890123456.1234,X'00FF01','2026-11-10 09:42:00'),(2,NULL,0.1000,NULL,NULL),(3,'third',9.0000,X'0102',NULL)")
            let databases = try await session.databases(); XCTAssertTrue(databases.contains(database))
            let tables = try await session.tables(in: database); XCTAssertEqual(tables.map(\.name), [table.name])
            let schema = try await session.schema(for: table); XCTAssertEqual(schema.count, 5); XCTAssertTrue(schema[0].primaryKey)
            let info = try await session.info(for: table); XCTAssertEqual(info.values["ENGINE"], "InnoDB")
            _ = try await session.execute("CREATE INDEX idx_name ON \(SQLBuilder.table(table)) (name)")
            _ = try await session.execute("ALTER TABLE \(SQLBuilder.table(table)) ADD CONSTRAINT chk_amount CHECK (amount >= 0)")
            _ = try await session.execute("CREATE TABLE \(SQLBuilder.identifier(database)).child (id INT PRIMARY KEY, parent_id INT, CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES \(SQLBuilder.table(table))(id))")
            _ = try await session.execute("CREATE VIEW \(SQLBuilder.identifier(database)).names AS SELECT id,name FROM \(SQLBuilder.table(table))")
            _ = try await session.execute("CREATE FUNCTION \(SQLBuilder.identifier(database)).double_value(x INT) RETURNS INT DETERMINISTIC RETURN x * 2")
            _ = try await session.execute("CREATE EVENT \(SQLBuilder.identifier(database)).test_event ON SCHEDULE EVERY 1 DAY DISABLE DO SET @harbor_event = 1")
            _ = try await session.execute("CREATE TRIGGER \(SQLBuilder.identifier(database)).before_child BEFORE INSERT ON \(SQLBuilder.identifier(database)).child FOR EACH ROW SET @harbor_trigger = 1")
            let columns = try await session.objects(in: database, table: table.name, kind: .columns)
            XCTAssertEqual(columns.map(\.name), ["id", "name", "amount", "payload", "created_at"])
            let indexes = try await session.objects(in: database, table: table.name, kind: .indexes)
            XCTAssertEqual(Set(indexes.map(\.name)), Set(["PRIMARY", "idx_name"]))
            let keys = try await session.objects(in: database, table: "child", kind: .foreignKeys)
            XCTAssertEqual(keys.first?.name, "fk_parent")
            let checks = try await session.objects(in: database, table: table.name, kind: .checks)
            XCTAssertEqual(checks.first?.name, "chk_amount")
            let triggers = try await session.objects(in: database, table: "child", kind: .triggers)
            XCTAssertEqual(triggers.first?.name, "before_child")
            let routines = try await session.objects(in: database, kind: .routines)
            XCTAssertEqual(routines.first?.name, "double_value")
            let events = try await session.objects(in: database, kind: .events)
            XCTAssertEqual(events.first?.name, "test_event")
            let allObjects = try await session.tables(in: database)
            XCTAssertTrue(allObjects.contains { $0.name == "names" && $0.isView })
            for object in routines + events + triggers + Array(columns.prefix(1)) {
                let ddl = try await session.execute(object.sql); XCTAssertFalse(ddl.rows.isEmpty)
            }
            let result = try await session.execute("SELECT * FROM \(SQLBuilder.table(table)) ORDER BY id")
            XCTAssertEqual(result.rows.count, 3); XCTAssertEqual(result.rows[0][1], .text(unusual))
            XCTAssertEqual(result.rows[0][2], .text("1234567890123456.1234")); XCTAssertEqual(result.rows[0][3], .binary(Data([0,255,1])))
            XCTAssertEqual(result.rows[0][4], .text("2026-11-10 09:42:00")); XCTAssertEqual(result.rows[1][1], .null)
            let empty = try await session.execute("SELECT id,name FROM \(SQLBuilder.table(table)) WHERE 1=0")
            XCTAssertEqual(empty.columns.map(\.name), ["id","name"]); XCTAssertTrue(empty.rows.isEmpty)
            let clipped = try await session.execute("SELECT * FROM \(SQLBuilder.table(table))", maxRows: 1)
            XCTAssertTrue(clipped.truncated); XCTAssertEqual(clipped.rows.count, 1)
            let afterClipped = try await session.execute("SELECT 42 AS answer"); XCTAssertEqual(afterClipped.rows[0][0].text, "42")
            for mode in ["", "NO_BACKSLASH_ESCAPES"] {
                _ = try await session.execute("SET SESSION sql_mode = '\(mode)'")
                let sql = try SQLBuilder.select(table: table, columns: ["id","name"], filter: FilterRule(column: "name", operation: .contains, value: "%_!"), sort: SortRule(column: "id", direction: .descending))
                let filtered = try await session.execute(sql); XCTAssertEqual(filtered.rows.count, 1); XCTAssertEqual(filtered.rows[0][1], .text(unusual))
                let injection = try SQLBuilder.select(table: table, columns: ["id"], filter: FilterRule(column: "name", operation: .equals, value: "' OR 1=1 -- "))
                let injected = try await session.execute(injection); XCTAssertTrue(injected.rows.isEmpty)
            }
            let pageSQL = try SQLBuilder.select(table: table, columns: ["id"], sort: SortRule(column: "id", direction: .descending), page: 1, pageSize: 1)
            let page = try await session.execute(pageSQL); XCTAssertEqual(page.rows[0][0].text, "2")
            let update = try SQLBuilder.update(table: table, column: schema[1], value: .text("changed"), original: result.records()[0], schema: schema)
            let written = try await session.execute(update); XCTAssertEqual(written.affectedRows, 1)
            let staleWrite = try await session.execute(update); XCTAssertEqual(staleWrite.affectedRows, 0)
            do { _ = try await session.execute("SELECT FROM invalid syntax"); XCTFail("SQL syntax error expected") } catch { }
            let afterError = try await session.execute("SELECT 1"); XCTAssertEqual(afterError.rows.count, 1)
            _ = try await session.execute("DROP DATABASE \(SQLBuilder.identifier(database))")
            // Timeout closes the connection; reconnect must recover cleanly.
            do { _ = try await session.execute("SELECT SLEEP(3)", timeoutSeconds: 1); XCTFail("Timeout expected") } catch { }
            let connected = await session.isConnected(); XCTAssertFalse(connected)
            _ = try await session.connect(profile, password: password)
            var encrypted = profile; encrypted.tls = .required
            _ = try await session.connect(encrypted, password: password)
            let cipher = try await session.execute("SHOW STATUS LIKE 'Ssl_cipher'")
            XCTAssertFalse(cipher.rows[0][1].display.isEmpty)
            await session.shutdown()
        } catch {
            _ = try? await session.execute("DROP DATABASE IF EXISTS \(SQLBuilder.identifier(database))")
            await session.shutdown(); throw error
        }
    }
}
