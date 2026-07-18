import XCTest
@testable import MyNavicatCore

/// 针对本机 MySQL (root/123456@127.0.0.1:3306) 的集成测试。
/// 可用环境变量覆盖：MYNAVICAT_HOST / PORT / USER / PASS
final class IntegrationTests: XCTestCase {

    var session: MySQLSession!

    let dbA = "mynavicat_test_a"
    let dbB = "mynavicat_test_b"

    override func setUp() async throws {
        let config = ConnectionConfig(
            name: "test",
            host: ProcessInfo.processInfo.environment["MYNAVICAT_HOST"] ?? "127.0.0.1",
            port: Int(ProcessInfo.processInfo.environment["MYNAVICAT_PORT"] ?? "3306") ?? 3306,
            username: ProcessInfo.processInfo.environment["MYNAVICAT_USER"] ?? "root",
            password: ProcessInfo.processInfo.environment["MYNAVICAT_PASS"] ?? "123456"
        )
        session = MySQLSession(config: config)

        // 环境自检：连不上就直接失败，提示先启动 MySQL
        _ = try await session.ping()

        try await session.execute("DROP DATABASE IF EXISTS \(dbA)")
        try await session.execute("DROP DATABASE IF EXISTS \(dbB)")
        try await session.execute("CREATE DATABASE \(dbA) DEFAULT CHARACTER SET utf8mb4")
        try await session.execute("CREATE DATABASE \(dbB) DEFAULT CHARACTER SET utf8mb4")
    }

    override func tearDown() async throws {
        try? await session.execute("DROP DATABASE IF EXISTS \(dbA)")
        try? await session.execute("DROP DATABASE IF EXISTS \(dbB)")
        await session.close()
    }

    private func makeSampleTable() async throws {
        try await session.execute("""
        CREATE TABLE \(dbA).users (
            id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(64) NOT NULL COMMENT '姓名',
            email VARCHAR(128) NULL,
            balance DECIMAL(10,2) NOT NULL DEFAULT 0.00,
            active BIT(1) NOT NULL DEFAULT b'1',
            avatar BLOB NULL,
            created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
        try await session.execute("""
        INSERT INTO \(dbA).users (name, email, balance, active, avatar) VALUES
        ('张三', 'zhang@example.com', 100.50, b'1', X'0102FF'),
        ('李四', NULL, -20.00, b'0', NULL),
        ('O''Brien " quoted, comma', 'o@example.com', 9999.99, b'1', X'DEADBEEF')
        """)
    }

    func testPing() async throws {
        let version = try await session.ping()
        XCTAssertFalse(version.isEmpty)
        print("MySQL version:", version)
    }

    func testListDatabasesAndTables() async throws {
        try await makeSampleTable()
        let dbs = try await session.listDatabases()
        XCTAssertTrue(dbs.contains(dbA))

        let tables = try await session.listTables(in: dbA)
        XCTAssertEqual(tables.map(\.name), ["users"])
        XCTAssertEqual(tables.first?.type, "BASE TABLE")
    }

    func testTableStructure() async throws {
        try await makeSampleTable()
        let cols = try await session.tableColumns(database: dbA, table: "users")
        XCTAssertEqual(cols.count, 7)
        XCTAssertEqual(cols[0].name, "id")
        XCTAssertEqual(cols[0].key, "PRI")
        XCTAssertTrue(cols[0].extra.contains("auto_increment"))
        XCTAssertEqual(cols[1].comment, "姓名")
        XCTAssertTrue(cols[2].isNullable)

        let ddl = try await session.showCreateTable(database: dbA, table: "users")
        XCTAssertTrue(ddl.contains("CREATE TABLE `users`"))
    }

    func testFetchRowsAndValues() async throws {
        try await makeSampleTable()
        let total = try await session.countRows(database: dbA, table: "users")
        XCTAssertEqual(total, 3)

        let page1 = try await session.fetchRows(database: dbA, table: "users", limit: 2, offset: 0)
        XCTAssertEqual(page1.columns.count, 7)
        XCTAssertEqual(page1.rows.count, 2)
        let nameIdx = try XCTUnwrap(page1.columns.firstIndex(of: "name"))
        let emailIdx = try XCTUnwrap(page1.columns.firstIndex(of: "email"))
        let activeIdx = try XCTUnwrap(page1.columns.firstIndex(of: "active"))
        let avatarIdx = try XCTUnwrap(page1.columns.firstIndex(of: "avatar"))

        XCTAssertEqual(page1.rows[0][nameIdx], "张三")
        XCTAssertNil(page1.rows[1][emailIdx])               // NULL
        XCTAssertEqual(page1.rows[0][activeIdx], "1")       // BIT -> 整数
        XCTAssertEqual(page1.rows[0][avatarIdx], "0x0102ff") // BLOB -> hex

        let page2 = try await session.fetchRows(database: dbA, table: "users", limit: 2, offset: 2)
        XCTAssertEqual(page2.rows.count, 1)
    }

    func testExecuteDMLMetadata() async throws {
        try await makeSampleTable()
        let r = try await session.execute("UPDATE \(dbA).users SET balance = balance + 1 WHERE id >= 2")
        XCTAssertEqual(r.affectedRows, 2)
        XCTAssertFalse(r.isResultSet)
    }

    func testSplitStatements() {
        let script = """
        SELECT 'a;b' AS x; -- comment ;
        SELECT "y;z";
        /* block ; comment */
        INSERT INTO t VALUES ('it\\'s');
        """
        let stmts = SQL.splitStatements(script)
        XCTAssertEqual(stmts.count, 3)
        XCTAssertTrue(stmts[2].contains("it\\'s"))
    }

    func testSplitStatementsDoubleDashRequiresWhitespace() {
        // `--` 后无空白不是 MySQL 注释
        XCTAssertEqual(SQL.splitStatements("SELECT 1--2").count, 1)
        XCTAssertEqual(SQL.splitStatements("SELECT 1 -- 注释\n; SELECT 2").count, 2)
    }

    func testFirstKeywordSkipsParens() {
        XCTAssertEqual(SQL.firstKeyword("(SELECT 1)"), "select")
        XCTAssertEqual(SQL.firstKeyword("/* c */ ( ( select 1"), "select")
        XCTAssertEqual(SQL.firstKeyword("insert into t values (1)"), "insert")
    }

    func testExportCSV() async throws {
        try await makeSampleTable()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp_test.csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = try await Exporter.export(session: session, database: dbA, table: "users", format: .csv, to: url)
        XCTAssertEqual(n, 3)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("id,name,email"))
        XCTAssertTrue(content.contains("张三"))
        // 含引号和逗号的字段必须被 CSV 转义
        XCTAssertTrue(content.contains("\"O'Brien \"\" quoted, comma\""))
    }

    func testExportJSON() async throws {
        try await makeSampleTable()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp_test.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = try await Exporter.export(session: session, database: dbA, table: "users", format: .json, to: url)
        XCTAssertEqual(n, 3)
        let data = try Data(contentsOf: url)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(arr?.count, 3)
        XCTAssertEqual(arr?[0]["name"] as? String, "张三")
        XCTAssertTrue(arr?[1]["email"] is NSNull)
    }

    func testExportSQLAndReimport() async throws {
        try await makeSampleTable()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp_test.sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = try await Exporter.export(session: session, database: dbA, table: "users", format: .sql, to: url)
        XCTAssertEqual(n, 3)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("INSERT INTO"))
        XCTAssertTrue(content.contains("X'0102ff'") || content.contains("X'0102FF'"))
        XCTAssertTrue(content.contains("NULL"))

        // 把导出的 SQL 在 B 库重放，验证可往返
        let statements = SQL.splitStatements(content).filter { !$0.hasPrefix("--") }
        try await session.executeBatch(["USE \(dbB)"] + statements)
        let count = try await session.countRows(database: dbB, table: "users")
        XCTAssertEqual(count, 3)
    }

    func testMigration() async throws {
        try await makeSampleTable()
        let tables = try await session.listTables(in: dbA)
        let rows = try await Migrator.migrate(
            source: session, sourceDB: dbA,
            tables: tables,
            target: session, targetDB: dbB
        )
        XCTAssertEqual(rows, 3)

        // 校验目标库内容一致
        let r = try await session.execute("SELECT name, email, balance, active, avatar FROM \(dbB).users ORDER BY id")
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.rows[0][0], "张三")
        XCTAssertNil(r.rows[1][1])
        XCTAssertEqual(r.rows[0][3], "1")
        XCTAssertEqual(r.rows[0][4], "0x0102ff")
        XCTAssertEqual(r.rows[2][0], "O'Brien \" quoted, comma")

        // 结构也应一致
        let cols = try await session.tableColumns(database: dbB, table: "users")
        XCTAssertEqual(cols.count, 7)
    }

    func testMigrationSameConnectionCrossDatabase() async throws {
        // 同连接跨库：直接在同一库下换目标名
        try await makeSampleTable()
        try await session.execute("CREATE DATABASE IF NOT EXISTS \(dbB)")
        let tables = try await session.listTables(in: dbA)
        _ = try await Migrator.migrate(
            source: session, sourceDB: dbA,
            tables: tables,
            target: session, targetDB: dbB,
            options: MigrationOptions(dropIfExists: true)
        )
        let count = try await session.countRows(database: dbB, table: "users")
        XCTAssertEqual(count, 3)
    }

    func testMigrationSameDatabaseRejected() async throws {
        // 同连接同库迁移会先 DROP 源表 —— 必须被拒绝
        try await makeSampleTable()
        let tables = try await session.listTables(in: dbA)
        do {
            _ = try await Migrator.migrate(
                source: session, sourceDB: dbA,
                tables: tables,
                target: session, targetDB: dbA
            )
            XCTFail("不应允许同库迁移")
        } catch {
            // 期望抛出
        }
        // 源表必须完好
        let count = try await session.countRows(database: dbA, table: "users")
        XCTAssertEqual(count, 3)
    }

    func testMigrationWithGeneratedColumn() async throws {
        try await session.execute("""
        CREATE TABLE \(dbA).geo (
            a INT NOT NULL,
            b INT NOT NULL,
            total INT GENERATED ALWAYS AS (a + b) STORED
        )
        """)
        try await session.execute("INSERT INTO \(dbA).geo (a, b) VALUES (1, 2), (3, 4)")
        let tables = try await session.listTables(in: dbA)
        let rows = try await Migrator.migrate(
            source: session, sourceDB: dbA,
            tables: tables.filter { $0.name == "geo" },
            target: session, targetDB: dbB
        )
        XCTAssertEqual(rows, 2)
        let r = try await session.execute("SELECT a, b, total FROM \(dbB).geo ORDER BY a")
        XCTAssertEqual(r.rows[0][2], "3")
        XCTAssertEqual(r.rows[1][2], "7")
    }

    func testExportJSONControlChars() async throws {
        try await session.execute("""
        CREATE TABLE \(dbA).ctrl (id INT PRIMARY KEY, note VARCHAR(64))
        """)
        try await session.execute("INSERT INTO \(dbA).ctrl VALUES (1, 'a\\nb\\tc')")
        // 写入一个真实控制字符 U+0001
        try await session.execute("UPDATE \(dbA).ctrl SET note = CONCAT(note, CHAR(1)) WHERE id = 1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp_ctrl.json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await Exporter.export(session: session, database: dbA, table: "ctrl", format: .json, to: url)
        let data = try Data(contentsOf: url)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        XCTAssertEqual(arr?[0]["note"] as? String, "a\nb\tc\u{1}")
    }
}
