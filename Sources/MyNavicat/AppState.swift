import Foundation
import MyNavicatCore
import SwiftUI

/// 对象类别：侧栏数据库下的「表」「视图」节点，也决定对象视图显示哪一类
enum ObjectKind: String, Hashable, CaseIterable {
    case tables
    case views

    var title: String {
        switch self {
        case .tables: return "表"
        case .views: return "视图"
        }
    }

    var systemImage: String {
        switch self {
        case .tables: return "tablecells"
        case .views: return "eye"
        }
    }

    func matches(_ t: TableInfo) -> Bool {
        switch self {
        case .tables: return !t.isView
        case .views: return t.isView
        }
    }
}

/// 工作区标签页
enum WorkbenchTab: Hashable, Identifiable {
    /// 对象视图：某个库下的表/视图列表（Navicat 的主内容区）
    case objects(connectionID: UUID, database: String, kind: ObjectKind)
    case table(connectionID: UUID, database: String, table: String)
    case query(id: UUID, title: String, connectionID: UUID, database: String?)

    var id: String {
        switch self {
        case .objects(let c, let d, let k): return "objects:\(c.uuidString)/\(d)/\(k.rawValue)"
        case .table(let c, let d, let t): return "table:\(c.uuidString)/\(d)/\(t)"
        case .query(let id, _, _, _): return "query:\(id.uuidString)"
        }
    }

    var connectionID: UUID {
        switch self {
        case .objects(let c, _, _): return c
        case .table(let c, _, _): return c
        case .query(_, _, let c, _): return c
        }
    }

    var database: String? {
        switch self {
        case .objects(_, let d, _): return d
        case .table(_, let d, _): return d
        case .query(_, _, _, let d): return d
        }
    }

    var title: String {
        switch self {
        case .objects(_, let d, _): return d
        case .table(_, _, let t): return t
        case .query(_, let title, _, _): return title
        }
    }

    var systemImage: String {
        switch self {
        case .objects: return "cylinder"
        case .table: return "tablecells"
        case .query: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// 侧栏中每个连接的运行时状态（连接是否打开、库列表）
struct ConnectionNode: Equatable {
    var databases: [String] = []
    var loading = false
    var connected = false
}

/// 对象视图拖拽负载：标记前缀 + JSON，避免和普通文本拖拽混淆
struct TableDragPayload: Codable {
    let connectionID: UUID
    let database: String
    let tables: [String]

    static let marker = "mynavicat-tables:"

    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return Self.marker + json
    }

    static func decode(_ string: String) -> TableDragPayload? {
        guard string.hasPrefix(marker),
              let data = String(string.dropFirst(marker.count)).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TableDragPayload.self, from: data)
    }
}

/// 打开迁移弹窗的请求：来源固定，目标可预填（拖拽落点）
struct MigrationRequest: Identifiable {
    let id = UUID()
    let sourceConnectionID: UUID
    let sourceDB: String
    /// 预选中的表名；nil 表示全部
    let preselected: Set<String>?
    let targetConnectionID: UUID?
    let targetDB: String?
}

func describe(_ error: Error) -> String {
    if let le = error as? LocalizedError, let d = le.errorDescription { return d }
    return "\(error)"
}

@MainActor
final class AppState: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    /// 每个连接的侧栏节点状态（未出现 = 未连接）
    @Published var nodes: [UUID: ConnectionNode] = [:]
    /// 表列表缓存，key 为 cacheKey(connectionID, database)
    @Published var tablesCache: [String: [TableInfo]] = [:]
    @Published var tablesLoading: Set<String> = []

    @Published var tabs: [WorkbenchTab] = []
    @Published var selectedTab: WorkbenchTab?

    @Published var alertMessage: String? {
        didSet { showAlert = alertMessage != nil }
    }
    @Published var showAlert = false

    let sessionManager = SessionManager()
    private let store = ConnectionStore.shared
    private var queryCounter = 0

    static let systemSchemas: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    // MARK: - 基础访问

    func config(for id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    func cacheKey(_ connectionID: UUID, _ database: String) -> String {
        "\(connectionID.uuidString)/\(database)"
    }

    func tables(for connectionID: UUID, database: String) -> [TableInfo] {
        tablesCache[cacheKey(connectionID, database)] ?? []
    }

    func isLoadingTables(_ connectionID: UUID, database: String) -> Bool {
        tablesLoading.contains(cacheKey(connectionID, database))
    }

    func node(for id: UUID) -> ConnectionNode {
        nodes[id] ?? ConnectionNode()
    }

    /// 当前焦点上下文：优先取选中标签页的连接/库，用于「新建查询」等动作
    var focusConnectionID: UUID? {
        if let tab = selectedTab, config(for: tab.connectionID) != nil { return tab.connectionID }
        return nodes.first(where: { $0.value.connected })?.key
    }

    var focusDatabase: String? { selectedTab?.database }

    // MARK: - 生命周期

    func startup() {
        guard connections.isEmpty else { return }
        connections = store.load()
        if let first = connections.first {
            Task { await connect(first.id) }
        }
    }

    func persistConnections() {
        store.save(connections)
    }

    /// 连接配置保存后调用：被删除或修改过的连接要丢弃会话和状态
    func applyConnectionChanges(from old: [ConnectionConfig]) {
        for o in old {
            if connections.first(where: { $0.id == o.id }) != o {
                Task { await teardownConnection(o.id) }
            }
        }
    }

    private func teardownConnection(_ id: UUID) async {
        await sessionManager.close(id: id)
        nodes[id] = nil
        tabs.removeAll { $0.connectionID == id }
        if selectedTab?.connectionID == id { selectedTab = tabs.last }
        let prefix = "\(id.uuidString)/"
        tablesCache = tablesCache.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - 会话

    func session(connectionID: UUID) async throws -> MySQLSession {
        guard let c = config(for: connectionID) else {
            throw MyNavicatError.invalidConfig("连接不存在或已删除")
        }
        return await sessionManager.session(for: c)
    }

    // MARK: - 连接开关

    func connect(_ id: UUID) async {
        guard config(for: id) != nil else { return }
        var node = nodes[id] ?? ConnectionNode()
        guard !node.loading else { return }
        node.loading = true
        nodes[id] = node
        do {
            let s = try await session(connectionID: id)
            let dbs = try await s.listDatabases()
            node.databases = dbs
            node.connected = true
            node.loading = false
            nodes[id] = node
        } catch {
            node.loading = false
            node.connected = false
            nodes[id] = node
            alertMessage = "连接失败：\(describe(error))"
        }
    }

    /// 展开连接节点时调用：未连接则建立连接
    func ensureConnected(_ id: UUID) {
        let node = nodes[id] ?? ConnectionNode()
        if !node.connected && !node.loading {
            Task { await connect(id) }
        }
    }

    func disconnect(_ id: UUID) async {
        await teardownConnection(id)
    }

    func refreshDatabases(_ id: UUID) async {
        guard nodes[id]?.connected == true else { return }
        await connect(id)
    }

    // MARK: - 表列表

    /// 有缓存则直接用；没有则后台加载（展开库节点 / 打开对象视图时调用）
    func ensureTables(_ connectionID: UUID, database: String) {
        let key = cacheKey(connectionID, database)
        guard tablesCache[key] == nil, !tablesLoading.contains(key) else { return }
        Task { await loadTables(connectionID, database: database) }
    }

    func refreshTables(_ connectionID: UUID, database: String) async {
        await loadTables(connectionID, database: database)
    }

    private func loadTables(_ connectionID: UUID, database: String) async {
        let key = cacheKey(connectionID, database)
        tablesLoading.insert(key)
        defer { tablesLoading.remove(key) }
        do {
            let s = try await session(connectionID: connectionID)
            tablesCache[key] = try await s.listTables(in: database)
        } catch {
            alertMessage = "加载表列表失败：\(describe(error))"
        }
    }

    // MARK: - 标签页

    func openObjects(_ connectionID: UUID, database: String, kind: ObjectKind = .tables) {
        let tab = WorkbenchTab.objects(connectionID: connectionID, database: database, kind: kind)
        if !tabs.contains(tab) { tabs.append(tab) }
        selectedTab = tab
        ensureTables(connectionID, database: database)
    }

    func openTable(_ connectionID: UUID, database: String, table name: String) {
        let tab = WorkbenchTab.table(connectionID: connectionID, database: database, table: name)
        if !tabs.contains(tab) { tabs.append(tab) }
        selectedTab = tab
    }

    func newQuery(connectionID: UUID? = nil, database: String? = nil) {
        guard let cid = connectionID ?? focusConnectionID else {
            alertMessage = "没有已打开的连接，请先双击左侧连接"
            return
        }
        queryCounter += 1
        let tab = WorkbenchTab.query(
            id: UUID(),
            title: "查询 \(queryCounter)",
            connectionID: cid,
            database: database ?? focusDatabase
        )
        tabs.append(tab)
        selectedTab = tab
    }

    func closeTab(_ tab: WorkbenchTab) {
        tabs.removeAll { $0 == tab }
        if selectedTab == tab {
            selectedTab = tabs.last
        }
    }
}
