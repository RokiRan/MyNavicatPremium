import XCTest
@testable import MyNavicatCore

final class SQLLexerTests: XCTestCase {

    /// 断言 token 序列的 (kind, 文本) 与期望一致
    private func assertTokens(
        _ sql: String,
        _ expected: [(SQLTokenKind, String)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = SQLLexer.tokenize(sql).map { ($0.kind, String(sql[$0.range])) }
        XCTAssertEqual(actual.count, expected.count, "token 数不一致: \(actual.map { "\($0.0):\($0.1)" })", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.0, e.0, "kind 不一致", file: file, line: line)
            XCTAssertEqual(a.1, e.1, "text 不一致", file: file, line: line)
        }
    }

    // MARK: - 关键字

    func testKeywordsCaseInsensitive() {
        assertTokens("select id FROM users Where x = 1", [
            (.keyword, "select"),
            (.keyword, "FROM"),
            (.keyword, "Where"),
            (.number, "1"),
        ])
    }

    func testIdentifierContainingKeywordPrefixIsNotKeyword() {
        // `selected` / `where1` 不是关键字（词边界判定）
        assertTokens("SELECT selected, where1 FROM t", [(.keyword, "SELECT"), (.keyword, "FROM")])
    }

    // MARK: - 字符串

    func testStringWithBackslashEscapeIsOneToken() {
        assertTokens("SELECT 'a\\'b'", [(.keyword, "SELECT"), (.string, "'a\\'b'")])
    }

    func testAdjacentDoubledQuoteStringsAreTwoTokens() {
        // MySQL 中 'it''s' 是两个相邻字符串字面量，与 splitStatements 行为一致
        assertTokens("'it''s'", [(.string, "'it'"), (.string, "'s'")])
    }

    func testDoubleQuotedString() {
        assertTokens("SELECT \"a;b\"", [(.keyword, "SELECT"), (.string, "\"a;b\"")])
    }

    func testUnterminatedStringRunsToEOF() {
        assertTokens("SELECT 'abc", [(.keyword, "SELECT"), (.string, "'abc")])
    }

    // MARK: - 注释

    func testDoubleDashRequiresWhitespace() {
        // `--` 后无空白不是注释（MySQL 规则）：1--2 是减法
        assertTokens("SELECT 1--2", [(.keyword, "SELECT"), (.number, "1"), (.number, "2")])
        assertTokens("-- 注释\nSELECT 1", [(.comment, "-- 注释\n"), (.keyword, "SELECT"), (.number, "1")])
        // 行尾 `--` 也是注释
        assertTokens("SELECT 1 --", [(.keyword, "SELECT"), (.number, "1"), (.comment, "--")])
    }

    func testHashAndBlockComments() {
        assertTokens("# c\nSELECT 1", [(.comment, "# c\n"), (.keyword, "SELECT"), (.number, "1")])
        assertTokens("/* a;-- */ SELECT 1", [(.comment, "/* a;-- */"), (.keyword, "SELECT"), (.number, "1")])
        // 未闭合块注释延伸到 EOF
        assertTokens("/* abc", [(.comment, "/* abc")])
    }

    func testKeywordInsideStringOrCommentIsNotKeyword() {
        assertTokens("'select'", [(.string, "'select'")])
        assertTokens("-- select\n1", [(.comment, "-- select\n"), (.number, "1")])
        assertTokens("/* from */ 1", [(.comment, "/* from */"), (.number, "1")])
    }

    // MARK: - 数字

    func testNumberForms() {
        assertTokens("1.5", [(.number, "1.5")])
        assertTokens("1e10", [(.number, "1e10")])
        assertTokens("1E-10", [(.number, "1E-10")])
        assertTokens("0x1F", [(.number, "0x1F")])
        assertTokens(".5", [(.number, ".5")])
        // `1e` 后面不是数字 → `1` 是数字，`e` 是普通标识符
        assertTokens("1e + 1", [(.number, "1"), (.number, "1")])
    }

    // MARK: - 反引号标识符

    func testBacktickIdentifier() {
        assertTokens("SELECT `select` FROM `t`", [
            (.keyword, "SELECT"), (.quotedIdentifier, "`select`"),
            (.keyword, "FROM"), (.quotedIdentifier, "`t`"),
        ])
    }

    // MARK: - UTF-16 偏移

    func testUTF16RangesWithEmojiAndCJK() {
        // 😀 占 2 个 UTF-16 code unit，中文占 1 个
        let sql = "-- 😀注释\nSELECT '甲' /* 😀 */ 1"
        let ns = sql as NSString
        let tokenized = SQLLexer.tokenize(sql)
        for token in tokenized {
            // utf16Range 切出的文本必须与 String.Index range 切出的一致
            XCTAssertEqual(ns.substring(with: token.utf16Range), String(sql[token.range]))
        }
        XCTAssertEqual(tokenized.map(\.kind), [.comment, .keyword, .string, .comment, .number])
        // SELECT 起点 = "-- 😀注释\n" = 2(-) + 1(空格) + 2(😀) + 2(注释) + 1(\n) = 8
        XCTAssertEqual(tokenized[1].utf16Range, NSRange(location: 8, length: 6))
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertTrue(SQLLexer.tokenize("").isEmpty)
        XCTAssertTrue(SQLLexer.tokenize("  \n\t ").isEmpty)
    }

    // MARK: - splitStatements 回归（scanner 重构后行为不变，无需数据库）

    func testSplitStatementsParity() {
        XCTAssertEqual(SQL.splitStatements("SELECT 1--2").count, 1)
        XCTAssertEqual(SQL.splitStatements("SELECT 1 -- 注释\n; SELECT 2").count, 2)
        XCTAssertEqual(SQL.splitStatements("SELECT 'a;b'; SELECT 2").count, 2)
        // 注释文本保留在语句中（与重构前行为一致）
        XCTAssertEqual(SQL.splitStatements("/* ; */ SELECT 1; # ;\nSELECT 2"), ["/* ; */ SELECT 1", "# ;\nSELECT 2"])
        XCTAssertEqual(SQL.splitStatements("INSERT INTO t VALUES ('it\\'s'); SELECT 1").count, 2)
        XCTAssertTrue(SQL.splitStatements("").isEmpty)
        XCTAssertEqual(SQL.splitStatements("-- 只有注释\n"), ["-- 只有注释"])
    }
}
