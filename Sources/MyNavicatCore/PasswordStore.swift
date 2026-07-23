import Foundation
import Security

/// 连接密码的存储后端：保存时密码进这里，connections.json 里不落明文
public protocol PasswordStoring: Sendable {
    /// 读取密码；不存在返回 nil
    func password(for id: UUID) -> String?
    /// 写入密码；nil 或空串 = 删除
    func setPassword(_ password: String?, for id: UUID)
}

/// 系统 Keychain 实现（generic password，按连接 UUID 索引）
public final class KeychainPasswordStore: PasswordStoring, @unchecked Sendable {
    public static let shared = KeychainPasswordStore()

    private let service = "com.mynavicat.connection"

    public init() {}

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    public func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) {
        let base = baseQuery(for: id)
        guard let password, !password.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// 内存实现，供单元测试注入（避免测试读写真实 Keychain）
public final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private var map: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map[id]
    }

    public func setPassword(_ password: String?, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let password, !password.isEmpty {
            map[id] = password
        } else {
            map[id] = nil
        }
    }
}
