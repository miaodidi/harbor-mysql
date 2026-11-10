import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

public actor MySQLSession {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var connection: MySQLConnection?
    private var generation = UUID()
    public init() {}

    public func connect(_ profile: ConnectionProfile, password: String) async throws -> String {
        try profile.validate()
        await disconnect()
        let token = generation
        let loop = group.next()
        var tls: TLSConfiguration? = profile.tls == .disabled ? nil : .makeClientConfiguration()
        if profile.tls == .required { tls?.certificateVerification = .none }
        let address = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
        let isIP = (try? SocketAddress(ipAddress: profile.host, port: profile.port)) != nil
        let future = MySQLConnection.connect(to: address, username: profile.username, database: profile.database,
            password: password.isEmpty ? nil : password, tlsConfiguration: tls, serverHostname: isIP ? nil : profile.host,
            logger: Logger(label: "Harbor.MySQL"), on: loop)
        let candidate = try await Self.connectionWithDeadline(future, on: loop).get()
        guard token == generation else { try? await candidate.close().get(); throw CancellationError() }
        do {
            if profile.tls != .disabled {
                // MySQLNIO allows fallback when the server advertises no SSL. Harbor does not.
                _ = try await candidate.channel.pipeline.handler(type: NIOSSLClientHandler.self).map { _ in true }.get()
            }
            connection = candidate
            _ = try await execute("SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci")
            let result = try await execute("SELECT VERSION() AS version")
            return result.rows.first?.first?.display ?? "MySQL"
        } catch {
            try? await candidate.close().get(); connection = nil
            throw error
        }
    }

    private static func connectionWithDeadline(_ future: EventLoopFuture<MySQLConnection>, on loop: any EventLoop) -> EventLoopFuture<MySQLConnection> {
        let promise = loop.makePromise(of: MySQLConnection.self)
        // All access to finished is confined to this event loop.
        var finished = false
        let timer = loop.scheduleTask(in: .seconds(12)) {
            if !finished { finished = true; promise.fail(HarborError.message("连接超时，请检查主机、端口和网络。")) }
        }
        future.whenComplete { result in
            if finished { if case .success(let conn) = result { conn.close().whenComplete { _ in } }; return }
            finished = true; timer.cancel(); promise.completeWith(result)
        }
        return promise.futureResult
    }

    public func disconnect() async {
        generation = UUID()
        let old = connection; connection = nil
        try? await old?.close().get()
    }
    public func isConnected() -> Bool { connection.map { !$0.isClosed } ?? false }
    public func shutdown() async { await disconnect(); try? await group.shutdownGracefully() }

    public func execute(_ sql: String, maxRows: Int = 10_000, timeoutSeconds: Int64 = 30) async throws -> QueryResult {
        guard let connection, !connection.isClosed else { throw HarborError.message("连接已关闭，请重新连接。") }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarborError.message("请输入 SQL。") }
        let command = TextQueryCommand(sql: sql, maxRows: maxRows)
        let start = Date()
        let future = connection.send(command, logger: connection.logger)
        let timer = connection.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            // Closing the socket interrupts the command, without leaving unread packets on the connection.
            connection.close().whenComplete { _ in }
        }
        do {
            try await future.get(); timer.cancel()
            var result = command.result
            result.elapsed = Date().timeIntervalSince(start)
            return result
        } catch {
            timer.cancel()
            if connection.isClosed { throw HarborError.message("连接已中断（取消、超时或网络断开），请重新连接。") }
            throw error
        }
    }

    public func databases() async throws -> [String] {
        try await execute("SHOW DATABASES").rows.compactMap { $0.first?.text }
    }
    public func tables(in database: String) async throws -> [TableReference] {
        let result = try await execute("SHOW FULL TABLES FROM \(SQLBuilder.identifier(database))")
        return result.rows.compactMap { row in
            guard let name = row.first?.text else { return nil }
            return TableReference(database: database, name: name, isView: row.count > 1 && row[1].text == "VIEW")
        }
    }
    public func schema(for table: TableReference) async throws -> [TableColumn] {
        let sql = "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, EXTRA, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(SQLBuilder.literal(.text(table.database))) AND TABLE_NAME = \(SQLBuilder.literal(.text(table.name))) ORDER BY ORDINAL_POSITION"
        return try await execute(sql).records().map { row in
            TableColumn(name: row["COLUMN_NAME"]?.display ?? "", type: row["COLUMN_TYPE"]?.display ?? "",
                nullable: row["IS_NULLABLE"]?.text == "YES", primaryKey: row["COLUMN_KEY"]?.text == "PRI",
                generated: ["VIRTUAL GENERATED", "STORED GENERATED"].contains { (row["EXTRA"]?.text ?? "").uppercased().contains($0) },
                binary: ["binary", "varbinary", "blob", "tinyblob", "mediumblob", "longblob", "geometry"].contains(row["DATA_TYPE"]?.text ?? ""))
        }
    }
    public func info(for table: TableReference) async throws -> TableInfo {
        let result = try await execute("SELECT ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, AUTO_INCREMENT, CREATE_TIME, UPDATE_TIME, TABLE_COLLATION, ROW_FORMAT FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(SQLBuilder.literal(.text(table.database))) AND TABLE_NAME = \(SQLBuilder.literal(.text(table.name)))")
        return TableInfo(values: result.records().first?.mapValues { $0 == .null ? "—" : $0.display } ?? [:])
    }
}

/// Text-protocol result collection adapted from MySQLNIO's MIT-licensed MySQLSimpleQueryCommand.
/// Keeps column metadata for empty results and bounds retained data while draining the wire completely.
private final class TextQueryCommand: MySQLCommand, @unchecked Sendable {
    let sql: String
    let maxRows: Int
    var result = QueryResult()
    private var definitions: [MySQLProtocol.ColumnDefinition41] = []
    private var expectedColumns: Int?
    private var retainedBytes = 0
    private let byteLimit = 32 * 1024 * 1024
    init(sql: String, maxRows: Int) { self.sql = sql; self.maxRows = maxRows }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        .init(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }
    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            let error = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            return .init(done: true, error: HarborError.message(error.errorMessage))
        }
        if expectedColumns == nil {
            if packet.isOK {
                let ok = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                result.affectedRows = ok.affectedRows
                return .init(done: true)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            expectedColumns = Int(response.columnCount)
            return .init()
        }
        if definitions.count < expectedColumns! {
            let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            definitions.append(column)
            result.columns.append(.init(name: column.name, type: String(describing: column.columnType)))
            return .init()
        }
        // A length-encoded row may also begin with FE; an EOF/OK terminator is shorter than 9 bytes.
        if packet.isEOF && packet.payload.readableBytes < 9 { return .init(done: true) }
        let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: definitions.count)
        let bytes = row.values.reduce(0) { $0 + ($1?.readableBytes ?? 0) }
        guard result.rows.count < maxRows, retainedBytes + bytes <= byteLimit else { result.truncated = true; return .init() }
        retainedBytes += bytes
        result.rows.append(zip(definitions, row.values).map { column, buffer in
            guard let buffer else { return .null }
            let data = Data(buffer.readableBytesView)
            let binaryType = [MySQLProtocol.DataType.blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .geometry, .bit].contains(column.columnType)
            if binaryType && column.characterSet == .binary { return .binary(data) }
            if let text = String(data: data, encoding: .utf8) { return .text(text) }
            return .binary(data)
        })
        return .init()
    }
}
