import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, sql
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

public struct ExportOptions: Sendable {
    public var includeStructure: Bool   // 仅 sql 格式：附带 DROP/CREATE
    public var batchSize: Int

    public init(includeStructure: Bool = true, batchSize: Int = 1000) {
        self.includeStructure = includeStructure
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

    private static func run(
        session: MySQLSession,
        database: String,
        table: String,
        format: ExportFormat,
        handle: FileHandle,
        options: ExportOptions,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> Int {
        var written = 0

        func write(_ s: String) throws {
            handle.write(Data(s.utf8))
        }

        // 表头/前缀
        var generated: Set<String> = []
        switch format {
        case .csv:
            let cols = try await session.tableColumns(database: database, table: table)
            try write(cols.map { csvEscape($0.name) }.joined(separator: ",") + "\n")
        case .json:
            try write("[\n")
        case .sql:
            try write("-- MyNavicat 导出\n-- 来源: \(database).\(table)\n\n")
            if options.includeStructure {
                let ddl = try await session.showCreateTable(database: database, table: table)
                try write("DROP TABLE IF EXISTS \(SQL.qi(table));\n\(ddl);\n\n")
            }
            generated = try await session.generatedColumns(database: database, table: table)
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
                // 导出不限定数据库，使 SQL 可在任意库重放（同 mysqldump）；
                // 生成列由目标库自动生成，不能显式插入
                for stmt in MySQLSession.insertStatements(
                    database: nil, table: table, rows: rows, excludeColumns: generated
                ) {
                    try write(stmt + ";\n")
                }
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
