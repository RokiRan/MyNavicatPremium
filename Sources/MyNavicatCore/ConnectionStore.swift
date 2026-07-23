import Foundation

/// 连接配置的持久化（~/Library/Application Support/MyNavicat/connections.json）
/// 密码不落盘：保存时写入 PasswordStoring（默认系统 Keychain），文件里只留空串；
/// 加载时从 PasswordStoring 回填，并自动迁移旧版明文密码。
public final class ConnectionStore: @unchecked Sendable {
    public static let shared = ConnectionStore()

    private let fileURL: URL
    private let passwordStore: any PasswordStoring
    private let lock = NSLock()
    /// 已知的连接 ID 集合，用于在连接被删除时清理其密码
    private var knownIDs: Set<UUID> = []

    public init(fileURL: URL? = nil, passwordStore: (any PasswordStoring)? = nil) {
        self.passwordStore = passwordStore ?? KeychainPasswordStore.shared
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyNavicat", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("connections.json")
        }
    }

    public func load() -> [ConnectionConfig] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            // 首次启动：预置本机连接
            let seed = [ConnectionConfig(
                name: "本地 MySQL",
                host: "127.0.0.1",
                port: 3306,
                username: "root",
                password: "123456"
            )]
            saveUnlocked(seed)
            return seed
        }
        guard var configs = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            // 文件损坏：备份而不是直接覆盖，避免丢用户配置
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        }
        // 解码出来的 password 非空 = 磁盘上仍是明文（旧版文件）。Keychain 优先；
        // Keychain 无条目时才把明文迁移进去，然后重写脱敏文件。
        let hadPlaintext = configs.contains { !$0.password.isEmpty }
        var migrationFailed = false
        for i in configs.indices {
            if let stored = passwordStore.password(for: configs[i].id) {
                configs[i].password = stored
            } else if !configs[i].password.isEmpty {
                passwordStore.setPassword(configs[i].password, for: configs[i].id)
                // Keychain 不可写时保留明文文件，下次启动重试，避免丢密码
                if passwordStore.password(for: configs[i].id) == nil { migrationFailed = true }
            }
        }
        if hadPlaintext && !migrationFailed { saveUnlocked(configs) }
        knownIDs = Set(configs.map(\.id))
        return configs
    }

    public func save(_ configs: [ConnectionConfig]) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(configs)
    }

    private func saveUnlocked(_ configs: [ConnectionConfig]) {
        for c in configs {
            passwordStore.setPassword(c.password.isEmpty ? nil : c.password, for: c.id)
        }
        let newIDs = Set(configs.map(\.id))
        for removed in knownIDs.subtracting(newIDs) {
            passwordStore.setPassword(nil, for: removed)
        }
        knownIDs = newIDs

        var sanitized = configs
        for i in sanitized.indices { sanitized[i].password = "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sanitized) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }
}
