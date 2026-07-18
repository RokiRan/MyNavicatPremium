import Foundation
import MyNavicatCore
import SwiftUI

/// 工作区标签页
enum WorkbenchTab: Hashable, Identifiable {
    case table(database: String, table: String)
    case query(id: UUID, title: String, database: String?)

    var id: String {
        switch self {
        case .table(let d, let t): return "table:\(d)/\(t)"
        case .query(let id, _, _): return "query:\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .table(_, let t): return t
        case .query(_, let title, _): return title
        }
    }

    var systemImage: String {
        switch self {
        case .table: return "tablecells"
        case .query: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

func describe(_ error: Error) -> String {
    if let le = error as? LocalizedError, let d = le.errorDescription { return d }
    return "\(error)"
}

@MainActor
final class AppState: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    @Published var activeConnectionID: UUID?
    @Published var databases: [String] = []
    @Published var loadingDatabases = false
    @Published var selectedDatabase: String?
    @Published var tables: [TableInfo] = []
    @Published var loadingTables = false
    @Published var tableFilter = ""

    @Published var tabs: [WorkbenchTab] = []
    @Published var selectedTab: WorkbenchTab?

    @Published var alertMessage: String? {
        didSet { showAlert = alertMessage != nil }
    }
    @Published var showAlert = false

    let sessionManager = SessionManager()
    private let store = ConnectionStore.shared
    private var queryCounter = 0

    var activeConnection: ConnectionConfig? {
        connections.first { $0.id == activeConnectionID }
    }

    var filteredTables: [TableInfo] {
        if tableFilter.isEmpty { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(tableFilter) }
    }

    static let systemSchemas: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    func startup() {
        guard connections.isEmpty else { return }
        connections = store.load()
        if let first = connections.first {
            Task { await selectConnection(first.id) }
        }
    }

    func persistConnections() {
        store.save(connections)
    }

    func session(for config: ConnectionConfig? = nil) async throws -> MySQLSession {
        guard let c = config ?? activeConnection else {
            throw MyNavicatError.invalidConfig("尚未选择连接")
        }
        return await sessionManager.session(for: c)
    }

    func selectConnection(_ id: UUID) async {
        activeConnectionID = id
        databases = []
        tables = []
        selectedDatabase = nil
        tabs = []
        selectedTab = nil
        loadingDatabases = true
        defer { loadingDatabases = false }
        do {
            let s = try await session()
            databases = try await s.listDatabases()
        } catch {
            alertMessage = "连接失败：\(describe(error))"
        }
    }

    func reconnectActive() async {
        guard let id = activeConnectionID else { return }
        await sessionManager.close(id: id)
        await selectConnection(id)
    }

    func loadTables() async {
        guard let db = selectedDatabase else {
            tables = []
            return
        }
        loadingTables = true
        defer { loadingTables = false }
        do {
            let s = try await session()
            tables = try await s.listTables(in: db)
        } catch {
            alertMessage = "加载表列表失败：\(describe(error))"
            tables = []
        }
    }

    func openTable(_ name: String) {
        guard let db = selectedDatabase else { return }
        let tab = WorkbenchTab.table(database: db, table: name)
        if !tabs.contains(tab) { tabs.append(tab) }
        selectedTab = tab
    }

    func newQuery() {
        queryCounter += 1
        let tab = WorkbenchTab.query(
            id: UUID(),
            title: "查询 \(queryCounter)",
            database: selectedDatabase
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
