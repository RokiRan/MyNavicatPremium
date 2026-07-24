import Foundation

/// 词法片段类别：`SQL.scan` 的输出单位
public enum SQLSegmentKind: Equatable, Sendable {
    case code               // 普通 SQL 代码（关键字、标识符、数字、运算符、空白…）
    case string             // '...' 或 "..."（含起止引号与转义序列）
    case quotedIdentifier   // `...`（含起止反引号）
    case comment            // -- / # 行注释（含结尾换行）或 /* */ 块注释
}

/// 词法片段：`range` 面向 String，`utf16Range` 面向 NSTextStorage/AppKit
public struct SQLSegment: Equatable, Sendable {
    public let kind: SQLSegmentKind
    public let range: Range<String.Index>
    public let utf16Range: NSRange

    public init(kind: SQLSegmentKind, range: Range<String.Index>, utf16Range: NSRange) {
        self.kind = kind
        self.range = range
        self.utf16Range = utf16Range
    }
}

public enum SQL {
    /// `name` -> `` `name` ``，内部反引号转义
    public static func qi(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// MySQL 字符串字面量转义（默认 SQL 模式，反斜杠转义）
    public static func quoteString(_ s: String) -> String {
        var out = "'"
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\0": out += "\\0"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\"": out += "\\\""
            case "\u{1A}": out += "\\Z"
            default: out.append(ch)
            }
        }
        out += "'"
        return out
    }

    /// 把一个 SQL 脚本按分号切成多条语句。
    /// 处理单/双引号、反引号、行注释(-- / #)、块注释。不支持 DELIMITER（存储过程）。
    public static func splitStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        for segment in scan(sql) {
            guard segment.kind == .code else {
                current += sql[segment.range]
                continue
            }
            var rest = sql[segment.range]
            while let semi = rest.firstIndex(of: ";") {
                current += rest[..<semi]
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { statements.append(trimmed) }
                current = ""
                rest = rest[rest.index(after: semi)...]
            }
            current += rest
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { statements.append(trimmed) }
        return statements
    }

    /// 词法扫描：把 SQL 文本切成连续的 代码/字符串/引号标识符/注释 片段。
    /// 是 `splitStatements` 与语法高亮共用的唯一状态机。规则与 MySQL 一致：
    /// - 字符串支持单/双引号，反斜杠转义（`\'` 不结束字符串）；相邻字符串各自成段
    /// - 反引号标识符不处理转义（与 MySQL 默认行为一致）
    /// - `--` 后必须跟空白/控制字符/结尾才是注释（`1--2` 是减法）；`#` 行注释；`/* */` 块注释
    /// - 未闭合的字符串/块注释一直延伸到文本末尾
    /// - 不支持 DELIMITER（存储过程）
    public static func scan(_ sql: String) -> [SQLSegment] {
        var segments: [SQLSegment] = []
        let end = sql.endIndex
        var i = sql.startIndex          // 当前扫描位置
        var segStart = i                // 当前片段起点
        var kind: SQLSegmentKind = .code
        var quote: Character = "\0"     // kind == .string 时的起止引号
        var blockComment = false        // kind == .comment 时区分 行/块
        var segUTF16Start = 0
        var utf16Offset = 0

        func advance(_ n: Int = 1) {
            for _ in 0..<n {
                utf16Offset += sql[i].utf16.count
                i = sql.index(after: i)
            }
        }
        func peek(_ n: Int) -> Character? {
            var j = i
            for _ in 0..<n {
                guard j < end else { return nil }
                j = sql.index(after: j)
            }
            return j < end ? sql[j] : nil
        }
        func flush() {
            guard segStart != i else { return }
            segments.append(SQLSegment(
                kind: kind,
                range: segStart..<i,
                utf16Range: NSRange(location: segUTF16Start, length: utf16Offset - segUTF16Start)
            ))
        }
        func open(_ newKind: SQLSegmentKind) {
            flush()
            kind = newKind
            segStart = i
            segUTF16Start = utf16Offset
        }
        func close() {
            flush()
            kind = .code
            segStart = i
            segUTF16Start = utf16Offset
        }

        while i < end {
            let c = sql[i]
            switch kind {
            case .string:
                if c == "\\", let _ = peek(1) {
                    advance(2)              // 转义序列，两字符都属于字符串
                    continue
                }
                advance()
                if c == quote { close() }   // 结束引号归入字符串段
            case .quotedIdentifier:
                advance()
                if c == "`" { close() }
            case .comment:
                if blockComment {
                    if c == "*", peek(1) == "/" {
                        advance(2)
                        close()
                    } else {
                        advance()
                    }
                } else {
                    advance()
                    if c == "\n" { close() } // 换行归入注释段
                }
            case .code:
                if c == "-", peek(1) == "-" {
                    // MySQL 要求 -- 后必须是空白/控制字符才是注释
                    let after = peek(2)
                    if after == nil || after == " " || after == "\t" || after == "\n" || after == "\r" {
                        open(.comment)
                        blockComment = false
                        advance()
                        continue
                    }
                    advance()
                } else if c == "#" {
                    open(.comment)
                    blockComment = false
                    advance()
                } else if c == "/", peek(1) == "*" {
                    open(.comment)
                    blockComment = true
                    advance()
                } else if c == "'" || c == "\"" {
                    open(.string)
                    quote = c
                    advance()
                } else if c == "`" {
                    open(.quotedIdentifier)
                    advance()
                } else {
                    advance()
                }
            }
        }
        flush()
        return segments
    }

    /// 语句首关键字（小写），跳过注释和前导括号/空白
    public static func firstKeyword(_ sql: String) -> String {
        var s = sql
        // 去掉前导注释
        while true {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("--") {
                if let nl = t.firstIndex(of: "\n") { s = String(t[t.index(after: nl)...]) } else { return "" }
            } else if t.hasPrefix("#") {
                if let nl = t.firstIndex(of: "\n") { s = String(t[t.index(after: nl)...]) } else { return "" }
            } else if t.hasPrefix("/*") {
                if let end = t.range(of: "*/") { s = String(t[end.upperBound...]) } else { return "" }
            } else {
                s = t
                break
            }
        }
        // 跳过前导括号，让 (SELECT ...) 也能被正确分类
        while s.first == "(" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var kw = ""
        for ch in s {
            if ch.isLetter { kw.append(ch.lowercased()) } else { break }
        }
        return kw
    }

    /// 该语句是否应走文本协议并期待结果集（其余走预处理协议拿 affectedRows）
    public static func returnsResultSet(_ sql: String) -> Bool {
        switch firstKeyword(sql) {
        case "select", "show", "desc", "describe", "explain", "with", "table", "values",
             "handler", "check", "checksum", "analyze", "repair", "optimize",
             // 不支持预处理协议的语句也走文本协议（OK 包，无结果集）
             "use", "set", "begin", "commit", "rollback", "start",
             "lock", "unlock", "xa", "prepare", "execute", "deallocate", "do":
            return true
        default:
            return false
        }
    }
}
