import Foundation

public struct MigrationOptions: Sendable {
    /// 目标不存在时创建数据库
    public var createDatabaseIfMissing: Bool
    /// 迁移建表语句（视图则是 CREATE VIEW）
    public var createStructure: Bool
    /// 建表前先 DROP TABLE/VIEW IF EXISTS
    public var dropIfExists: Bool
    public var batchSize: Int

    public init(
        createDatabaseIfMissing: Bool = true,
        createStructure: Bool = true,
        dropIfExists: Bool = true,
        batchSize: Int = 500
    ) {
        self.createDatabaseIfMissing = createDatabaseIfMissing
        self.createStructure = createStructure
        self.dropIfExists = dropIfExists
        self.batchSize = batchSize
    }
}

/// 跨库数据迁移：把 source 会话里的若干表复制到 target 会话的另一个库。
/// source 和 target 可以是同一个会话（同服务器跨库），也可以是两台服务器。
///
/// 安全性约定：
/// - 同一连接上 sourceDB == targetDB 会被拒绝（否则会 DROP 掉源表）。
/// - 每张表的数据复制包在一个事务里：要么整表成功，要么回滚，不会留半截。
/// - 复制期间目标会话 SET FOREIGN_KEY_CHECKS=0，结束后恢复。
public enum Migrator {

    /// 返回成功迁移的总行数。任何一张表失败都会抛出并中止。
    @discardableResult
    public static func migrate(
        source: MySQLSession,
        sourceDB: String,
        tables: [TableInfo],
        target: MySQLSession,
        targetDB: String,
        options: MigrationOptions = MigrationOptions(),
        log: (@Sendable (String) -> Void)? = nil,
        progress: (@Sendable (_ table: String, _ rowsCopied: Int) -> Void)? = nil
    ) async throws -> Int {
        if source.config.id == target.config.id, sourceDB == targetDB {
            throw MyNavicatError.migrationFailed("源和目标相同（\(sourceDB)），已拒绝执行以防止数据丢失")
        }

        if options.createDatabaseIfMissing {
            try await target.execute(
                "CREATE DATABASE IF NOT EXISTS \(SQL.qi(targetDB)) DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
            )
            log?("已确认目标库 \(targetDB) 存在")
        }

        try await target.execute("SET FOREIGN_KEY_CHECKS=0")
        var totalRows = 0
        do {
            for table in tables {
                totalRows += try await migrateOne(
                    source: source, sourceDB: sourceDB, table: table,
                    target: target, targetDB: targetDB,
                    options: options, log: log, progress: progress
                )
            }
        } catch {
            _ = try? await target.execute("SET FOREIGN_KEY_CHECKS=1")
            throw error
        }
        try await target.execute("SET FOREIGN_KEY_CHECKS=1")

        log?("全部完成：\(tables.count) 张表，共 \(totalRows) 行")
        return totalRows
    }

    private static func migrateOne(
        source: MySQLSession,
        sourceDB: String,
        table: TableInfo,
        target: MySQLSession,
        targetDB: String,
        options: MigrationOptions,
        log: (@Sendable (String) -> Void)?,
        progress: (@Sendable (_ table: String, _ rowsCopied: Int) -> Void)?
    ) async throws -> Int {
        log?("开始迁移 \(sourceDB).\(table.name) → \(targetDB).\(table.name)")

        if options.createStructure {
            var ddl = try await source.showCreateTable(database: sourceDB, table: table.name)
            if table.isView {
                // DEFINER 里的账号在目标服务器上可能不存在（1449），剥离
                ddl = stripDefiner(ddl)
            }
            let drop = table.isView
                ? "DROP VIEW IF EXISTS \(SQL.qi(table.name))"
                : "DROP TABLE IF EXISTS \(SQL.qi(table.name))"
            var steps = ["USE \(SQL.qi(targetDB))"]
            if options.dropIfExists { steps.append(drop) }
            steps.append(ddl)
            try await target.executeBatch(steps)
            log?("  结构已创建")
        }

        if table.isView {
            log?("  视图不复制数据，已跳过")
            progress?(table.name, 0)
            return 0
        }

        // GENERATED ALWAYS 列由目标库生成，不能显式插入
        let generated = try await source.generatedColumns(database: sourceDB, table: table.name)

        var copied = 0
        var offset = 0
        try await target.execute("BEGIN")
        do {
            while true {
                let rows = try await source.fetchRawRows(
                    database: sourceDB, table: table.name,
                    limit: options.batchSize, offset: offset
                )
                if rows.isEmpty { break }
                let stmts = MySQLSession.insertStatements(
                    database: targetDB, table: table.name,
                    rows: rows, excludeColumns: generated
                )
                for stmt in stmts {
                    try await target.execute(stmt)
                }
                copied += rows.count
                offset += rows.count
                progress?(table.name, copied)
                if rows.count < options.batchSize { break }
            }
        } catch {
            _ = try? await target.execute("ROLLBACK")
            throw error
        }
        try await target.execute("COMMIT")
        log?("  完成：\(copied) 行")
        return copied
    }

    /// 去掉 CREATE VIEW 里的 DEFINER=... 子句
    static func stripDefiner(_ ddl: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "DEFINER\\s*=\\s*(`[^`]*`|\\S+)@(`[^`]*`|\\S+)\\s*",
            options: .caseInsensitive
        ) else { return ddl }
        let range = NSRange(ddl.startIndex..<ddl.endIndex, in: ddl)
        return regex.stringByReplacingMatches(in: ddl, range: range, withTemplate: "")
    }
}
