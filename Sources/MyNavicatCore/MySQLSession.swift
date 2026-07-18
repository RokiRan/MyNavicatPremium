import Foundation
import MySQLNIO
import NIOCore
import NIOPosix

/// 一个到 MySQL 的会话：按需建立连接，断线自动重连一次。
/// 所有方法都是 actor 隔离的，调用方直接 await 即可。
public actor MySQLSession {
    public let config: ConnectionConfig

    private var connection: MySQLConnection?

    /// 进行中的连接任务，防止 actor 重入导致并发建连泄漏连接
    private var connecting: Task<MySQLConnection, Error>?

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    public init(config: ConnectionConfig) {
        self.config = config
    }

    // MARK: - 连接管理

    private func open(database: String?) async throws -> MySQLConnection {
        let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
        let db = (database?.isEmpty == false) ? database! : "mysql"
        do {
            return try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: db,
                password: config.password.isEmpty ? nil : config.password,
                tlsConfiguration: nil,
                on: Self.group.next()
            ).get()
        } catch {
            // 非 root 账号可能无权访问 mysql 库；用 information_schema 兜底
            if database == nil || database?.isEmpty == true {
                return try await MySQLConnection.connect(
                    to: address,
                    username: config.username,
                    database: "information_schema",
                    password: config.password.isEmpty ? nil : config.password,
                    tlsConfiguration: nil,
                    on: Self.group.next()
                ).get()
            }
            throw error
        }
    }

    private func ensureConnection() async throws -> MySQLConnection {
        if let c = connection, !c.isClosed { return c }
        if let t = connecting { return try await t.value }
        let t = Task { () throws -> MySQLConnection in
            if let old = connection { _ = try? await old.close().get() }
            let conn = try await open(database: config.database)
            _ = try? await conn.simpleQuery("SET NAMES utf8mb4").get()
            return conn
        }
        connecting = t
        defer { connecting = nil }
        let conn = try await t.value
        connection = conn
        // 恢复重连前的 USE 上下文
        if let db = currentDatabase {
            _ = try? await conn.simpleQuery("USE \(SQL.qi(db))").get()
        }
        return conn
    }

    public func close() async {
        if let c = connection {
            connection = nil
            _ = try? await c.close().get()
        }
    }

    public func ping() async throws -> String {
        let r = try await execute("SELECT VERSION()")
        if let row = r.rows.first, let v = row.first, let s = v { return s }
        return "unknown"
    }

    // MARK: - 执行

    @discardableResult
    public func execute(_ sql: String) async throws -> QueryResult {
        var conn = try await ensureConnection()
        do {
            let r = try await Self.run(sql, on: conn)
            trackDatabaseContext(sql)
            return r
        } catch {
            // 只对幂等的读语句自动重试；DML/DDL 重试可能重复提交
            if conn.isClosed && SQL.returnsResultSet(sql) {
                connection = nil
                conn = try await ensureConnection()
                let r = try await Self.run(sql, on: conn)
                trackDatabaseContext(sql)
                return r
            }
            throw error
        }
    }

    private func trackDatabaseContext(_ sql: String) {
        guard SQL.firstKeyword(sql) == "use" else { return }
        let rest = sql
            .drop(while: { $0.isLetter })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { currentDatabase = rest }
    }

    /// 同一个会话里顺序执行多条语句（保证 USE 之类的上下文不被其他调用穿插）
    @discardableResult
    public func executeBatch(_ statements: [String]) async throws -> [QueryResult] {
        var results: [QueryResult] = []
        for stmt in statements {
            results.append(try await execute(stmt))
        }
        return results
    }

    /// 跟踪最后使用的数据库，断线重连后恢复 USE 上下文
    private var currentDatabase: String?

    /// 顺序执行脚本，遇错即止；每条语句都有结果记录
    public func runScript(_ statements: [String]) async -> [StatementOutcome] {
        var out: [StatementOutcome] = []
        for sql in statements {
            do {
                let r = try await execute(sql)
                out.append(StatementOutcome(sql: sql, result: r, error: nil))
            } catch {
                out.append(StatementOutcome(sql: sql, result: nil, error: "\(error)"))
                break
            }
        }
        return out
    }

    private static func run(_ sql: String, on conn: MySQLConnection) async throws -> QueryResult {
        if SQL.returnsResultSet(sql) {
            let rows = try await conn.simpleQuery(sql).get()
            return makeResult(rows)
        } else {
            var affected: UInt64 = 0
            var lastID: UInt64? = nil
            _ = try await conn.query(sql, [], onMetadata: { meta in
                affected = meta.affectedRows
                lastID = meta.lastInsertID
            }).get()
            return .statementOK(affected: affected, lastInsertID: lastID)
        }
    }

    // MARK: - 元数据

    public func listDatabases() async throws -> [String] {
        let r = try await execute("SHOW DATABASES")
        return r.rows.compactMap { $0.first ?? nil }
    }

    public func listTables(in database: String) async throws -> [TableInfo] {
        let sql = """
        SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT,
               ENGINE, DATA_LENGTH, TABLE_COLLATION, CREATE_TIME, UPDATE_TIME
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(SQL.quoteString(database))
        ORDER BY TABLE_NAME
        """
        let r = try await execute(sql)
        return r.rows.map { row in
            TableInfo(
                name: row[0] ?? "",
                type: row[1] ?? "",
                estimatedRows: row[2].flatMap { Int64($0) },
                comment: row[3] ?? "",
                engine: row[4] ?? "",
                dataLength: row[5].flatMap { Int64($0) },
                collation: row[6] ?? "",
                createdAt: row[7],
                updatedAt: row[8]
            )
        }
    }

    public func tableColumns(database: String, table: String) async throws -> [ColumnInfo] {
        let sql = """
        SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = \(SQL.quoteString(database)) AND TABLE_NAME = \(SQL.quoteString(table))
        ORDER BY ORDINAL_POSITION
        """
        let r = try await execute(sql)
        return r.rows.map { row in
            ColumnInfo(
                name: row[0] ?? "",
                columnType: row[1] ?? "",
                isNullable: (row[2] ?? "YES") == "YES",
                key: row[3] ?? "",
                defaultValue: row[4],
                extra: row[5] ?? "",
                comment: row[6] ?? ""
            )
        }
    }

    public func showCreateTable(database: String, table: String) async throws -> String {
        let r = try await execute("SHOW CREATE TABLE \(SQL.qi(database)).\(SQL.qi(table))")
        guard let row = r.rows.first, row.count > 1, let ddl = row[1] else {
            throw MyNavicatError.migrationFailed("无法获取 \(table) 的建表语句")
        }
        return ddl
    }

    public func countRows(database: String, table: String) async throws -> Int64 {
        let r = try await execute("SELECT COUNT(*) FROM \(SQL.qi(database)).\(SQL.qi(table))")
        return r.rows.first?.first.flatMap { $0 }.flatMap { Int64($0) } ?? 0
    }

    public func fetchRows(database: String, table: String, limit: Int, offset: Int) async throws -> QueryResult {
        try await execute("SELECT * FROM \(SQL.qi(database)).\(SQL.qi(table)) LIMIT \(limit) OFFSET \(offset)")
    }

    /// 原始行（保留列定义和二进制缓冲），供导出/迁移使用
    public func fetchRawRows(database: String, table: String, limit: Int, offset: Int) async throws -> [MySQLRow] {
        let conn = try await ensureConnection()
        let sql = "SELECT * FROM \(SQL.qi(database)).\(SQL.qi(table)) LIMIT \(limit) OFFSET \(offset)"
        do {
            return try await conn.simpleQuery(sql).get()
        } catch {
            if conn.isClosed {
                connection = nil
                let fresh = try await ensureConnection()
                return try await fresh.simpleQuery(sql).get()
            }
            throw error
        }
    }

    // MARK: - 结果物化

    static func makeResult(_ rows: [MySQLRow]) -> QueryResult {
        guard let first = rows.first else {
            return QueryResult(columns: [], rows: [], affectedRows: nil, lastInsertID: nil)
        }
        let columns = first.columnDefinitions.map { $0.name }
        let data: [[String?]] = rows.map { row in
            zip(row.columnDefinitions, row.values).map { def, buffer in
                displayString(columnType: def.columnType, characterSet: def.characterSet, buffer: buffer)
            }
        }
        return QueryResult(columns: columns, rows: data, affectedRows: nil, lastInsertID: nil)
    }

    /// 单元格 -> 展示字符串；NULL 返回 nil；二进制列显示 0x 十六进制
    static func displayString(
        columnType: MySQLProtocol.DataType,
        characterSet: MySQLProtocol.CharacterSet,
        buffer: ByteBuffer?
    ) -> String? {
        guard var buffer else { return nil }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        if columnType == .bit {
            var v: UInt64 = 0
            for b in bytes { v = (v << 8) | UInt64(b) }
            return String(v)
        }
        if characterSet == .binary && isBinaryType(columnType) {
            return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func isBinaryType(_ t: MySQLProtocol.DataType) -> Bool {
        t == .blob || t == .tinyBlob || t == .mediumBlob || t == .longBlob
            || t == .geometry || t == .string || t == .varString || t == .varchar
    }

    /// 单元格 -> INSERT 用的 SQL 字面量
    static func sqlLiteral(
        columnType: MySQLProtocol.DataType,
        characterSet: MySQLProtocol.CharacterSet,
        buffer: ByteBuffer?
    ) -> String {
        guard var buffer else { return "NULL" }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        if columnType == .bit {
            var v: UInt64 = 0
            for b in bytes { v = (v << 8) | UInt64(b) }
            return String(v)
        }
        if characterSet == .binary && isBinaryType(columnType) {
            return "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
        }
        return SQL.quoteString(String(decoding: bytes, as: UTF8.self))
    }

    /// 把一批行转成 INSERT ... VALUES (...),(...) 语句；超过 maxBytes 会拆成多条。
    /// database 为 nil 时不限定数据库（导出场景，由使用方自行 USE）。
    /// excludeColumns 用于剔除 GENERATED ALWAYS 列（目标库会自动生成），
    /// 非空时会生成显式列清单。
    public static func insertStatements(
        database: String?,
        table: String,
        rows: [MySQLRow],
        excludeColumns: Set<String> = [],
        maxBytes: Int = 4 * 1024 * 1024
    ) -> [String] {
        guard let defs = rows.first?.columnDefinitions, !rows.isEmpty else { return [] }
        let includeIdx = defs.indices.filter { !excludeColumns.contains(defs[$0].name) }
        let target = database.map { "\(SQL.qi($0)).\(SQL.qi(table))" } ?? SQL.qi(table)
        let columnList = excludeColumns.isEmpty
            ? ""
            : " (" + includeIdx.map { SQL.qi(defs[$0].name) }.joined(separator: ",") + ")"
        let prefix = "INSERT INTO \(target)\(columnList) VALUES "
        var statements: [String] = []
        var current = prefix
        for row in rows {
            let tuple = "(" + includeIdx.map { i in
                sqlLiteral(
                    columnType: row.columnDefinitions[i].columnType,
                    characterSet: row.columnDefinitions[i].characterSet,
                    buffer: row.values[i]
                )
            }.joined(separator: ",") + ")"
            if current.utf8.count + tuple.utf8.count + 1 > maxBytes, current.count > prefix.count {
                statements.append(current)
                current = prefix
            }
            if current.count > prefix.count { current += "," }
            current += tuple
        }
        if current.count > prefix.count { statements.append(current) }
        return statements
    }

    /// 一张表里的 GENERATED ALWAYS 列名（这类列不能直接 INSERT）
    public func generatedColumns(database: String, table: String) async throws -> Set<String> {
        let cols = try await tableColumns(database: database, table: table)
        return Set(cols.filter { $0.extra.localizedCaseInsensitiveContains("generated") }.map(\.name))
    }
}

/// 按连接配置缓存会话
public actor SessionManager {
    private var sessions: [UUID: MySQLSession] = [:]

    public init() {}

    public func session(for config: ConnectionConfig) -> MySQLSession {
        if let s = sessions[config.id] { return s }
        let s = MySQLSession(config: config)
        sessions[config.id] = s
        return s
    }

    public func close(id: UUID) async {
        if let s = sessions.removeValue(forKey: id) { await s.close() }
    }

    public func closeAll() async {
        let all = Array(sessions.values)
        sessions.removeAll()
        for s in all { await s.close() }
    }
}
