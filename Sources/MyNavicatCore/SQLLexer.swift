import Foundation

/// 高亮 token 类别（对应编辑器配色）
public enum SQLTokenKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case quotedIdentifier
}

/// 高亮 token：`range` 面向 String，`utf16Range` 面向 NSTextStorage/AppKit
public struct SQLToken: Equatable, Sendable {
    public let kind: SQLTokenKind
    public let range: Range<String.Index>
    public let utf16Range: NSRange

    public init(kind: SQLTokenKind, range: Range<String.Index>, utf16Range: NSRange) {
        self.kind = kind
        self.range = range
        self.utf16Range = utf16Range
    }
}

/// SQL 语法高亮分词器。基于 `SQL.scan` 的唯一状态机，
/// 仅在 code 片段内进一步识别关键字与数字；普通标识符/运算符/空白不产出 token（用默认色）。
public enum SQLLexer {

    public static func tokenize(_ sql: String) -> [SQLToken] {
        var tokens: [SQLToken] = []
        for segment in SQL.scan(sql) {
            switch segment.kind {
            case .string:
                tokens.append(SQLToken(kind: .string, range: segment.range, utf16Range: segment.utf16Range))
            case .quotedIdentifier:
                tokens.append(SQLToken(kind: .quotedIdentifier, range: segment.range, utf16Range: segment.utf16Range))
            case .comment:
                tokens.append(SQLToken(kind: .comment, range: segment.range, utf16Range: segment.utf16Range))
            case .code:
                lexCode(sql, segment, into: &tokens)
            }
        }
        return tokens
    }

    /// code 片段内扫描：identifier 查关键字表，digit/`.` 开头按数字字面量消费
    private static func lexCode(_ sql: String, _ segment: SQLSegment, into tokens: inout [SQLToken]) {
        let end = segment.range.upperBound
        var i = segment.range.lowerBound
        var utf16 = segment.utf16Range.location

        func peek(_ n: Int) -> Character? {
            var j = i
            for _ in 0..<n {
                guard j < end else { return nil }
                j = sql.index(after: j)
            }
            return j < end ? sql[j] : nil
        }
        @discardableResult
        func advance() -> Character {
            let c = sql[i]
            utf16 += c.utf16.count
            i = sql.index(after: i)
            return c
        }

        while i < end {
            let c = sql[i]
            if c.isLetter || c == "_" || c == "$" {
                let start = i, startUTF16 = utf16
                var word = ""
                while i < end, sql[i].isLetter || sql[i].isNumber || sql[i] == "_" || sql[i] == "$" {
                    word.append(advance())
                }
                if SQLKeywords.mysql80.contains(word.lowercased()) {
                    tokens.append(SQLToken(
                        kind: .keyword,
                        range: start..<i,
                        utf16Range: NSRange(location: startUTF16, length: utf16 - startUTF16)
                    ))
                }
            } else if c.isNumber || (c == "." && peek(1)?.isNumber == true) {
                let start = i, startUTF16 = utf16
                if c == "0", peek(1) == "x" || peek(1) == "X" {
                    advance() // 0
                    advance() // x
                    while i < end, sql[i].isHexDigit { advance() }
                } else {
                    while i < end, sql[i].isNumber { advance() }
                    if i < end, sql[i] == "." {
                        advance()
                        while i < end, sql[i].isNumber { advance() }
                    }
                    if i < end, sql[i] == "e" || sql[i] == "E" {
                        // 指数：e[+-]?digits，仅在确为指数时消费
                        var j = sql.index(after: i)
                        if j < end, sql[j] == "+" || sql[j] == "-" {
                            j = sql.index(after: j)
                        }
                        if j < end, sql[j].isNumber {
                            advance() // e/E
                            if i < end, sql[i] == "+" || sql[i] == "-" { advance() }
                            while i < end, sql[i].isNumber { advance() }
                        }
                    }
                }
                tokens.append(SQLToken(
                    kind: .number,
                    range: start..<i,
                    utf16Range: NSRange(location: startUTF16, length: utf16 - startUTF16)
                ))
            } else {
                advance()
            }
        }
    }
}

/// MySQL 8.0 reserved words（小写）。
/// https://dev.mysql.com/doc/refman/8.0/en/keywords.html
public enum SQLKeywords {
    public static let mysql80: Set<String> = [
        "accessible", "add", "all", "alter", "analyze", "and", "as", "asc", "asensitive",
        "before", "between", "bigint", "binary", "blob", "both", "by",
        "call", "cascade", "case", "change", "char", "character", "check", "collate",
        "column", "condition", "constraint", "continue", "convert", "create", "cross",
        "cube", "cume_dist", "current_date", "current_time", "current_timestamp",
        "current_user", "cursor",
        "database", "databases", "day_hour", "day_microsecond", "day_minute", "day_second",
        "dec", "decimal", "declare", "default", "delayed", "delete", "dense_rank", "desc",
        "describe", "deterministic", "distinct", "distinctrow", "div", "double", "drop", "dual",
        "each", "else", "elseif", "empty", "enclosed", "escaped", "except", "exists", "exit",
        "explain",
        "false", "fetch", "first_value", "float", "float4", "float8", "for", "force",
        "foreign", "from", "fulltext", "function",
        "generated", "get", "grant", "group", "grouping", "groups",
        "having", "high_priority", "hour_microsecond", "hour_minute", "hour_second",
        "if", "ignore", "in", "index", "infile", "inner", "inout", "insensitive", "insert",
        "int", "int1", "int2", "int3", "int4", "int8", "integer", "interval", "into",
        "io_after_gtids", "io_before_gtids", "is", "iterate",
        "join", "json_table",
        "key", "keys", "kill",
        "lag", "last_value", "lateral", "lead", "leading", "leave", "left", "like", "limit",
        "linear", "lines", "load", "localtime", "localtimestamp", "lock", "long", "longblob",
        "longtext", "loop", "low_priority",
        "master_bind", "master_ssl_verify_server_cert", "match", "maxvalue", "mediumblob",
        "mediumint", "mediumtext", "middleint", "minute_microsecond", "minute_second", "mod",
        "modifies",
        "natural", "not", "no_write_to_binlog", "nth_value", "ntile", "null", "numeric",
        "of", "on", "optimize", "optimizer_costs", "option", "optionally", "or", "order",
        "out", "outer", "outfile", "over",
        "partition", "percent_rank", "precision", "primary", "procedure", "purge",
        "range", "rank", "read", "reads", "read_write", "real", "recursive", "references",
        "regexp", "release", "rename", "repeat", "replace", "require", "resignal", "restrict",
        "return", "revoke", "right", "rlike", "row", "rows", "row_number",
        "schema", "schemas", "second_microsecond", "select", "sensitive", "separator", "set",
        "show", "signal", "smallint", "spatial", "specific", "sql", "sqlexception", "sqlstate",
        "sqlwarning", "sql_big_result", "sql_calc_found_rows", "sql_small_result", "ssl",
        "starting", "stored", "straight_join", "system",
        "table", "terminated", "then", "tinyblob", "tinyint", "tinytext", "to", "trailing",
        "trigger", "true",
        "undo", "union", "unique", "unlock", "unsigned", "update", "usage", "use", "using",
        "utc_date", "utc_time", "utc_timestamp",
        "values", "varbinary", "varchar", "varcharacter", "varying", "virtual",
        "when", "where", "while", "window", "with", "write",
        "xor",
        "year_month",
        "zerofill",
    ]
}
