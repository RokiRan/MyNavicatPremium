import Foundation

/// 一个 MySQL 连接配置
public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// 默认数据库（可选；为空时自动回退 mysql / information_schema）
    public var database: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String = "127.0.0.1",
        port: Int = 3306,
        username: String = "root",
        password: String = "",
        database: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
    }
}

public struct TableInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// BASE TABLE / VIEW
    public let type: String
    public let estimatedRows: Int64?
    public let comment: String

    public var isView: Bool { type == "VIEW" }
}

public struct ColumnInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// 完整类型，如 varchar(64)、int unsigned
    public let columnType: String
    public let isNullable: Bool
    /// PRI / UNI / MUL / ""
    public let key: String
    public let defaultValue: String?
    public let extra: String
    public let comment: String
}

/// 单条语句的执行结果：要么有结果集，要么有 affectedRows
public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var affectedRows: UInt64?
    public var lastInsertID: UInt64?

    public var isResultSet: Bool { affectedRows == nil }

    public static func statementOK(affected: UInt64, lastInsertID: UInt64?) -> QueryResult {
        QueryResult(columns: [], rows: [], affectedRows: affected, lastInsertID: lastInsertID)
    }
}

public struct StatementOutcome: Sendable {
    public let sql: String
    public let result: QueryResult?
    public let error: String?
}

public enum MyNavicatError: Error, LocalizedError {
    case invalidConfig(String)
    case exportFailed(String)
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let m): return "连接配置无效：\(m)"
        case .exportFailed(let m): return "导出失败：\(m)"
        case .migrationFailed(let m): return "迁移失败：\(m)"
        }
    }
}
