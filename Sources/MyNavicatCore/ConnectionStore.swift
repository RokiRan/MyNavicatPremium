import Foundation

/// 连接配置的持久化（~/Library/Application Support/MyNavicat/connections.json）
public final class ConnectionStore: @unchecked Sendable {
    public static let shared = ConnectionStore()

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
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
        guard let configs = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            // 文件损坏：备份而不是直接覆盖，避免丢用户配置
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        }
        return configs
    }

    public func save(_ configs: [ConnectionConfig]) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(configs)
    }

    private func saveUnlocked(_ configs: [ConnectionConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(configs) {
            try? data.write(to: fileURL, options: .atomic)
            // 含密码，限制为仅当前用户可读
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }
}
