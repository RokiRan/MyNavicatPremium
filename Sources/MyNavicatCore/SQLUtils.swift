import Foundation

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
        var inSingle = false, inDouble = false, inBacktick = false
        var inLineComment = false, inBlockComment = false
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"

            if inLineComment {
                current.append(c)
                if c == "\n" { inLineComment = false }
                i += 1
                continue
            }
            if inBlockComment {
                current.append(c)
                if c == "*" && next == "/" {
                    current.append(next)
                    i += 2
                    inBlockComment = false
                } else {
                    i += 1
                }
                continue
            }
            if inSingle || inDouble || inBacktick {
                current.append(c)
                if c == "\\" && !inBacktick && next != "\0" {
                    current.append(next)
                    i += 2
                    continue
                }
                if inSingle && c == "'" { inSingle = false }
                else if inDouble && c == "\"" { inDouble = false }
                else if inBacktick && c == "`" { inBacktick = false }
                i += 1
                continue
            }

            if c == "-" && next == "-" {
                // MySQL 要求 -- 后必须是空白/控制字符才是注释
                let after = i + 2 < chars.count ? chars[i + 2] : "\0"
                if after == "\0" || after == " " || after == "\t" || after == "\n" || after == "\r" {
                    inLineComment = true
                    current.append(c)
                    i += 1
                    continue
                }
                current.append(c)
                i += 1
                continue
            }
            if c == "#" {
                inLineComment = true
                current.append(c)
                i += 1
                continue
            }
            if c == "/" && next == "*" {
                inBlockComment = true
                current.append(c)
                i += 1
                continue
            }
            if c == "'" { inSingle = true; current.append(c); i += 1; continue }
            if c == "\"" { inDouble = true; current.append(c); i += 1; continue }
            if c == "`" { inBacktick = true; current.append(c); i += 1; continue }
            if c == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { statements.append(trimmed) }
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { statements.append(trimmed) }
        return statements
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
