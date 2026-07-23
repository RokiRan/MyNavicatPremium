import XCTest
@testable import MyNavicatCore

/// ConnectionStore + PasswordStoring 的单测（临时目录 + 内存密码库，不碰真实 Keychain）
final class ConnectionStoreTests: XCTestCase {

    var dir: URL!
    var file: URL!
    var passwords: InMemoryPasswordStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("connections.json")
        passwords = InMemoryPasswordStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> ConnectionStore {
        ConnectionStore(fileURL: file, passwordStore: passwords)
    }

    func testPasswordNotWrittenToDisk() throws {
        let store = makeStore()
        let c = ConnectionConfig(name: "t", password: "secret123")
        store.save([c])

        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret123"), "明文密码不应写入 connections.json")
        XCTAssertEqual(passwords.password(for: c.id), "secret123")
        // 读回时从密码库回填
        XCTAssertEqual(store.load().first?.password, "secret123")
    }

    func testLegacyPlaintextMigration() throws {
        // 旧版格式：password 明文落盘
        let c = ConnectionConfig(name: "legacy", password: "oldpw")
        try JSONEncoder().encode([c]).write(to: file)

        let store = makeStore()
        XCTAssertEqual(store.load().first?.password, "oldpw")
        // 迁移后：密码库有值，磁盘无明文
        XCTAssertEqual(passwords.password(for: c.id), "oldpw")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("oldpw"))
    }

    func testKeychainWinsOverStalePlaintext() throws {
        // Keychain 里已有新密码，磁盘残留旧明文：以密码库为准
        let c = ConnectionConfig(name: "legacy", password: "oldpw")
        try JSONEncoder().encode([c]).write(to: file)
        passwords.setPassword("newpw", for: c.id)

        XCTAssertEqual(makeStore().load().first?.password, "newpw")
    }

    func testRemovingConnectionDeletesPassword() {
        let store = makeStore()
        let a = ConnectionConfig(name: "a", password: "pa")
        let b = ConnectionConfig(name: "b", password: "pb")
        store.save([a, b])
        store.save([a])
        XCTAssertEqual(passwords.password(for: a.id), "pa")
        XCTAssertNil(passwords.password(for: b.id))
    }

    func testEmptyPasswordDeletesEntry() {
        let store = makeStore()
        var c = ConnectionConfig(name: "a", password: "pa")
        store.save([c])
        c.password = ""
        store.save([c])
        XCTAssertNil(passwords.password(for: c.id))
    }
}
