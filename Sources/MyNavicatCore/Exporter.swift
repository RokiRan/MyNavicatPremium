import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, sql
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

public struct ExportOptions: Sendable {
    public var includeStructure: Bool   // 仅 sql 格式：附带 DROP/CREATE
    public var includeData: Bool        // 仅 sql 格式：附带 INSERT 数据
    public var batchSize: Int

    public init(includeStructure: Bool = true, includeData: Bool = true, batchSize: Int = 1000) {
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.batchSize = batchSize
    }
}

/// 把一张表流式导出到文件，返回导出的行数。
public enum Exporter {

    public static func export(
        session: MySQLSession,
        database: String,
        table: String,
        format: ExportFormat,
        to url: URL,
        options: ExportOptions = ExportOptions(),
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        // 先写临时文件，全部成功后原子替换目标，避免半途截断已有导出
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".mynavicat-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        let total: Int
        do {
            total = try await run(
                session: session, database: database, table: table,
                format: format, handle: handle, options: options, progress: progress
            )
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        return total
    }

    /// 整个库导出为一个 SQL 转储文件（mysqldump 风格）：基表 DDL + 数据，视图只导 DDL。
    /// 返回 (对象数, 数据行数)。
    @discardableResult
    public static func exportDatabase(
        session: MySQLSession,
        database: String,
        to url: URL,
        options: ExportOptions = ExportOptions(),
        progress: (@Sendable (String, Int) -> Void)? = nil   // (当前对象名, 累计行数)
    ) async throws -> (objects: Int, rows: Int) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".mynavicat-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var result: (objects: Int, rows: Int)
        do {
            result = try await dumpDatabase(
                session: session, database: database, handle: handle,
                options: options, progress: progress
            )
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        return result
    }

    private static func dumpDatabase(
        session: MySQLSession,
        database: String,
        handle: FileHandle,
        options: ExportOptions,
        progress: (@Sendable (String, Int) -> Void)?
    ) async throws -> (objects: Int, rows: Int) {
        func write(_ s: String) throws {
            handle.write(Data(s.utf8))
        }

        let objects = try await session.listTables(in: database)
        let tables = objects.filter { $0.type == "BASE TABLE" }
        // 视图放最后：定义可能引用基表或其他视图；数据不导（查询时动态生成）
        let views = objects.filter { $0.type == "VIEW" }

        try write("-- MyNavicat 数据库导出\n-- 来源: \(database)\n\n")
        if options.includeStructure {
            try write("CREATE DATABASE IF NOT EXISTS \(SQL.qi(database));\nUSE \(SQL.qi(database));\n\n")
        }

        var totalRows = 0
        for t in tables {
            progress?(t.name, totalRows)
            let base = totalRows
            totalRows += try await writeTableSQL(
                session: session, database: database, table: t.name,
                handle: handle, options: options,
                progress: { n in progress?(t.name, base + n) }
            )
        }
        if options.includeStructure {
            for v in views {
                progress?(v.name, totalRows)
                let ddl = try await session.showCreateTable(database: database, table: v.name)
                try write("DROP VIEW IF EXISTS \(SQL.qi(v.name));\n\(ddl);\n\n")
            }
        }
        return (tables.count + views.count, totalRows)
    }

    /// 一张表的 SQL 转储（DROP/CREATE + 分批 INSERT），返回数据行数。
    /// INSERT 不限定数据库，使转储可在任意库重放（同 mysqldump）。
    private static func writeTableSQL(
        session: MySQLSession,
        database: String,
        table: String,
        handle: FileHandle,
        options: ExportOptions,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> Int {
        func write(_ s: String) throws {
            handle.write(Data(s.utf8))
        }

        if options.includeStructure {
            let ddl = try await session.showCreateTable(database: database, table: table)
            try write("DROP TABLE IF EXISTS \(SQL.qi(table));\n\(ddl);\n\n")
        }
        guard options.includeData else { return 0 }

        // 生成列由目标库自动生成，不能显式插入
        let generated = try await session.generatedColumns(database: database, table: table)
        var written = 0
        var offset = 0
        while true {
            let rows = try await session.fetchRawRows(
                database: database, table: table,
                limit: options.batchSize, offset: offset
            )
            if rows.isEmpty { break }
            for stmt in MySQLSession.insertStatements(
                database: nil, table: table, rows: rows, excludeColumns: generated
            ) {
                try write(stmt + ";\n")
            }
            written += rows.count
            progress?(written)
            offset += rows.count
            if rows.count < options.batchSize { break }
        }
        return written
    }

    private static func run(
        session: MySQLSession,
        database: String,
        table: String,
        format: ExportFormat,
        handle: FileHandle,
        options: ExportOptions,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> Int {
        // SQL 转储与整库导出共用同一实现，保证两种入口产物一致
        if format == .sql {
            func write(_ s: String) throws {
                handle.write(Data(s.utf8))
            }
            try write("-- MyNavicat 导出\n-- 来源: \(database).\(table)\n\n")
            return try await writeTableSQL(
                session: session, database: database, table: table,
                handle: handle, options: options, progress: progress
            )
        }

        var written = 0

        func write(_ s: String) throws {
            handle.write(Data(s.utf8))
        }

        // 表头/前缀
        switch format {
        case .csv:
            let cols = try await session.tableColumns(database: database, table: table)
            try write(cols.map { csvEscape($0.name) }.joined(separator: ",") + "\n")
        case .json:
            try write("[\n")
        case .sql:
            break
        }

        var offset = 0
        var firstJSONRow = true
        while true {
            let rows = try await session.fetchRawRows(
                database: database, table: table,
                limit: options.batchSize, offset: offset
            )
            if rows.isEmpty { break }

            switch format {
            case .csv:
                for row in rows {
                    let line = zip(row.columnDefinitions, row.values).map { def, buf -> String in
                        guard let s = MySQLSession.displayString(
                            columnType: def.columnType, characterSet: def.characterSet, buffer: buf
                        ) else { return "" }
                        return csvEscape(s)
                    }.joined(separator: ",")
                    try write(line + "\n")
                }
            case .json:
                for row in rows {
                    var fields: [String] = []
                    for (def, buf) in zip(row.columnDefinitions, row.values) {
                        let key = jsonEscape(def.name)
                        if let s = MySQLSession.displayString(
                            columnType: def.columnType, characterSet: def.characterSet, buffer: buf
                        ) {
                            fields.append("\"\(key)\": \"\(jsonEscape(s))\"")
                        } else {
                            fields.append("\"\(key)\": null")
                        }
                    }
                    if !firstJSONRow { try write(",\n") }
                    firstJSONRow = false
                    try write("  {" + fields.joined(separator: ", ") + "}")
                }
            case .sql:
                break
            }

            written += rows.count
            progress?(written)
            offset += rows.count
            if rows.count < options.batchSize { break }
        }

        if format == .json { try write("\n]\n") }
        return written
    }

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch < "\u{20}" {
                    out += String(format: "\\u%04x", ch.unicodeScalars.first!.value)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}
