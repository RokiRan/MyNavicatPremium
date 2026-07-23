import Foundation

/// 数据编辑：把网格里的展示值/用户输入转成安全的 SQL 片段。
/// 展示值约定与 DataView 一致：NULL 为 nil，二进制列显示 0x 十六进制，
/// BIT 显示为无符号整数（写回时按字符串/数字字面量由 MySQL 隐式转换）。
public enum RowEditor {

    /// blob/binary/geometry 类列（网格里展示为 0x 十六进制）
    public static func isBinaryColumn(_ columnType: String) -> Bool {
        let t = columnType.lowercased()
        return t.contains("blob") || t.contains("binary") || t.contains("geometry")
    }

    /// "0x" 前缀的合法十六进制串 -> 去掉前缀的 hex；否则 nil
    public static func hexString(_ display: String) -> String? {
        guard display.hasPrefix("0x"), display.count > 2 else { return nil }
        let hex = String(display.dropFirst(2))
        return hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// 展示值 -> WHERE 等值条件：NULL -> IS NULL；二进制列 0x.. -> X'hex'
    public static func matchCondition(column: ColumnInfo, displayValue: String?) -> String {
        let col = SQL.qi(column.name)
        guard let value = displayValue else { return "\(col) IS NULL" }
        if isBinaryColumn(column.columnType), let hex = hexString(value) {
            return "\(col) = X'\(hex)'"
        }
        return "\(col) = \(SQL.quoteString(value))"
    }

    /// 用户输入 -> SQL 字面量：nil -> NULL；二进制列且输入为 0x.. -> X'hex'
    public static func inputLiteral(_ input: String?, column: ColumnInfo) -> String {
        guard let input else { return "NULL" }
        if isBinaryColumn(column.columnType), let hex = hexString(input) {
            return "X'\(hex)'"
        }
        return SQL.quoteString(input)
    }
}

public extension MySQLSession {

    /// 主键列（按表内顺序）；为空表示无主键，行级编辑/删除不可用
    func primaryKeyColumns(database: String, table: String) async throws -> [ColumnInfo] {
        try await tableColumns(database: database, table: table).filter { $0.key == "PRI" }
    }

    /// 按主键定位更新一行。identity 为全部主键列的展示值；set 为用户输入（nil = NULL）。
    /// 返回 affectedRows；值未变化时 MySQL 返回 0，不视为失败。
    @discardableResult
    func updateRow(
        database: String,
        table: String,
        identity: [(column: ColumnInfo, displayValue: String?)],
        set: [(column: ColumnInfo, input: String?)]
    ) async throws -> UInt64 {
        guard !identity.isEmpty else { throw MyNavicatError.noPrimaryKey(table) }
        guard !set.isEmpty else { throw MyNavicatError.editFailed("没有要更新的列") }
        let setClause = set.map {
            "\(SQL.qi($0.column.name)) = \(RowEditor.inputLiteral($0.input, column: $0.column))"
        }.joined(separator: ", ")
        let whereClause = identity.map {
            RowEditor.matchCondition(column: $0.column, displayValue: $0.displayValue)
        }.joined(separator: " AND ")
        let sql = "UPDATE \(SQL.qi(database)).\(SQL.qi(table)) SET \(setClause) WHERE \(whereClause) LIMIT 1"
        let r = try await execute(sql)
        return r.affectedRows ?? 0
    }

    /// 按主键定位删除一行
    @discardableResult
    func deleteRow(
        database: String,
        table: String,
        identity: [(column: ColumnInfo, displayValue: String?)]
    ) async throws -> UInt64 {
        guard !identity.isEmpty else { throw MyNavicatError.noPrimaryKey(table) }
        let whereClause = identity.map {
            RowEditor.matchCondition(column: $0.column, displayValue: $0.displayValue)
        }.joined(separator: " AND ")
        let sql = "DELETE FROM \(SQL.qi(database)).\(SQL.qi(table)) WHERE \(whereClause) LIMIT 1"
        let r = try await execute(sql)
        return r.affectedRows ?? 0
    }

    /// 插入一行；values 只包含要显式赋值的列（自增/生成列由调用方剔除，交给数据库默认值）
    @discardableResult
    func insertRow(
        database: String,
        table: String,
        values: [(column: ColumnInfo, input: String?)]
    ) async throws -> UInt64 {
        guard !values.isEmpty else { throw MyNavicatError.editFailed("没有要插入的列") }
        let cols = values.map { SQL.qi($0.column.name) }.joined(separator: ", ")
        let lits = values.map { RowEditor.inputLiteral($0.input, column: $0.column) }.joined(separator: ", ")
        let sql = "INSERT INTO \(SQL.qi(database)).\(SQL.qi(table)) (\(cols)) VALUES (\(lits))"
        let r = try await execute(sql)
        return r.affectedRows ?? 0
    }
}
