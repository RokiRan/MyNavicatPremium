import AppKit
import MyNavicatCore
import SwiftUI

private enum SidebarSelection: Hashable {
    case connection(UUID)
    case database(UUID, String)
    case category(UUID, String, ObjectKind)
    case table(UUID, String, String)
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showConnections = false
    @State private var exportRequest: ExportRequest?
    @State private var migrationRequest: MigrationRequest?
    @State private var sidebarSelection: SidebarSelection?
    /// 展开的节点：连接 / 数据库 / 类别
    @State private var expanded: Set<String> = []
    /// 拖拽悬停高亮的数据库节点 key
    @State private var dropTargetKey: String?
    @State private var sidebarFilter = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showConnections) {
            ConnectionManagerSheet()
        }
        .sheet(item: $exportRequest) { req in
            ExportSheet(connectionID: req.connectionID, database: req.database, table: req.table)
        }
        .sheet(item: $migrationRequest) { req in
            MigrationSheet(request: req)
        }
        .alert("提示", isPresented: $app.showAlert) {
            Button("好") { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(Color.accentColor)
                Text("我的连接").font(.headline)
                Spacer()
                Button { showConnections = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("管理连接")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(selection: $sidebarSelection) {
                if app.connections.isEmpty {
                    Text("点右上角齿轮新建连接")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.connections) { conn in
                    connectionRow(conn)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: app.nodes) { _, nodes in
                // 连上即展开（首次启动自动连接也生效），与 Navicat 恢复打开连接的行为一致
                for (id, node) in nodes where node.connected {
                    let key = connKey(id)
                    if !expanded.contains(key) { expanded.insert(key) }
                }
            }
            .onChange(of: sidebarSelection) { _, new in
                switch new {
                case .database(let cid, let db):
                    app.openObjects(cid, database: db, kind: .tables)
                case .category(let cid, let db, let kind):
                    app.openObjects(cid, database: db, kind: kind)
                case .table(let cid, let db, let name):
                    app.openTable(cid, database: db, table: name)
                case .connection, nil:
                    break
                }
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选表", text: $sidebarFilter)
                    .textFieldStyle(.plain)
                if !sidebarFilter.isEmpty {
                    Button { sidebarFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(6)
        }
    }

    // MARK: 连接节点

    @ViewBuilder
    private func connectionRow(_ conn: ConnectionConfig) -> some View {
        let node = app.node(for: conn.id)
        DisclosureGroup(isExpanded: expansionBinding(connKey(conn.id)) {
            app.ensureConnected(conn.id)
        }) {
            if node.loading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("连接中…").foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            } else if node.connected {
                ForEach(node.databases, id: \.self) { db in
                    databaseRow(conn, db)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundStyle(node.connected ? .green : .secondary)
                Text(conn.name)
                if node.connected {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
            .tag(SidebarSelection.connection(conn.id))
            .contextMenu {
                if node.connected {
                    Button("关闭连接") { Task { await app.disconnect(conn.id) } }
                    Button("刷新") { Task { await app.refreshDatabases(conn.id) } }
                } else {
                    Button("打开连接") { Task { await app.connect(conn.id) } }
                }
                Divider()
                Button("新建查询") { app.newQuery(connectionID: conn.id) }
                    .disabled(!node.connected)
                Divider()
                Button("连接属性…") { showConnections = true }
            }
        }
    }

    // MARK: 数据库节点（拖放目标）

    @ViewBuilder
    private func databaseRow(_ conn: ConnectionConfig, _ db: String) -> some View {
        let key = dbKey(conn.id, db)
        DisclosureGroup(isExpanded: expansionBinding(key) {
            app.ensureTables(conn.id, database: db)
        }) {
            ForEach(ObjectKind.allCases, id: \.self) { kind in
                categoryRow(conn, db, kind)
            }
        } label: {
            Label {
                Text(db)
            } icon: {
                Image(systemName: "cylinder")
                    .foregroundStyle(AppState.systemSchemas.contains(db) ? .secondary : Color.accentColor)
            }
            .tag(SidebarSelection.database(conn.id, db))
            .background(dropTargetKey == key ? Color.accentColor.opacity(0.25) : .clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onDrop(of: [.mynavicatTables, .text], delegate: tableDropDelegate(targetConn: conn.id, targetDB: db, key: key))
            .contextMenu {
                Button("打开对象视图") { app.openObjects(conn.id, database: db, kind: .tables) }
                Button("新建查询") { app.newQuery(connectionID: conn.id, database: db) }
                Divider()
                Button("刷新表列表") { Task { await app.refreshTables(conn.id, database: db) } }
                Divider()
                Button("迁移整个库到…") {
                    migrationRequest = MigrationRequest(
                        sourceConnectionID: conn.id, sourceDB: db,
                        preselected: nil, targetConnectionID: nil, targetDB: nil
                    )
                }
            }
        }
    }

    // MARK: 类别节点（表 / 视图）

    @ViewBuilder
    private func categoryRow(_ conn: ConnectionConfig, _ db: String, _ kind: ObjectKind) -> some View {
        let key = catKey(conn.id, db, kind)
        let cached = app.tablesCache[app.cacheKey(conn.id, db)]
        let items = (cached ?? []).filter(kind.matches)
        let filtered = sidebarFilter.isEmpty
            ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(sidebarFilter) }
        // 有筛选命中时强制展开，让结果可见
        let forceExpand = !sidebarFilter.isEmpty && !filtered.isEmpty
        let loading = app.isLoadingTables(conn.id, database: db)

        DisclosureGroup(isExpanded: forceExpand ? .constant(true) : expansionBinding(key) {
            app.ensureTables(conn.id, database: db)
        }) {
            if loading && cached == nil {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("加载中…").foregroundStyle(.secondary)
                }
                .padding(.leading, 40)
            } else if filtered.isEmpty {
                Text(sidebarFilter.isEmpty ? "（空）" : "无匹配")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 40)
            } else {
                ForEach(filtered) { t in
                    Label {
                        Text(t.name)
                    } icon: {
                        Image(systemName: t.isView ? "eye" : "tablecells")
                            .foregroundStyle(t.isView ? .orange : Color.accentColor)
                    }
                    .tag(SidebarSelection.table(conn.id, db, t.name))
                    .contextMenu {
                        Button("打开") { app.openTable(conn.id, database: db, table: t.name) }
                        Button("复制表名") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.name, forType: .string)
                        }
                        Divider()
                        Button("导出…") {
                            exportRequest = ExportRequest(connectionID: conn.id, database: db, table: t.name)
                        }
                        Button("迁移到…") {
                            migrationRequest = MigrationRequest(
                                sourceConnectionID: conn.id, sourceDB: db,
                                preselected: [t.name], targetConnectionID: nil, targetDB: nil
                            )
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(cached == nil ? kind.title : "\(kind.title) (\(items.count))")
            } icon: {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(kind == .views ? .orange : Color.accentColor)
            }
            .tag(SidebarSelection.category(conn.id, db, kind))
            .background(dropTargetKey == key ? Color.accentColor.opacity(0.25) : .clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onDrop(of: [.mynavicatTables, .text], delegate: tableDropDelegate(targetConn: conn.id, targetDB: db, key: key))
        }
    }

    // MARK: 展开状态

    private func connKey(_ id: UUID) -> String { "c:\(id.uuidString)" }
    private func dbKey(_ id: UUID, _ db: String) -> String { "d:\(id.uuidString)/\(db)" }
    private func catKey(_ id: UUID, _ db: String, _ kind: ObjectKind) -> String {
        "k:\(id.uuidString)/\(db)/\(kind.rawValue)"
    }

    private func expansionBinding(_ key: String, onExpand: @escaping () -> Void) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { newValue in
                if newValue {
                    if !expanded.contains(key) {
                        expanded.insert(key)
                        onExpand()
                    }
                } else {
                    expanded.remove(key)
                }
            }
        )
    }

    // MARK: 拖放 → 迁移

    /// 数据库/类别节点的拖放处理器
    private func tableDropDelegate(targetConn: UUID, targetDB: String, key: String) -> TableDropDelegate {
        TableDropDelegate(
            onDrop: { payload in
                if payload.connectionID == targetConn && payload.database == targetDB {
                    app.alertMessage = "目标与源相同（\(targetDB)），不能迁移到自己"
                    return false
                }
                migrationRequest = MigrationRequest(
                    sourceConnectionID: payload.connectionID,
                    sourceDB: payload.database,
                    preselected: Set(payload.tables),
                    targetConnectionID: targetConn,
                    targetDB: targetDB
                )
                return true
            },
            onTargeted: { targeted in
                dropTargetKey = targeted ? key : (dropTargetKey == key ? nil : dropTargetKey)
            }
        )
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if app.tabs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("双击左侧连接打开，点选数据库查看对象视图")
                    .foregroundStyle(.secondary)
                Button("新建查询") { app.newQuery() }
                    .disabled(app.focusConnectionID == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TabView(selection: $app.selectedTab) {
                ForEach(app.tabs) { tab in
                    tabContent(tab)
                        .tabItem {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .tag(tab)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: WorkbenchTab) -> some View {
        switch tab {
        case .objects(let cid, let db, let kind):
            ObjectView(connectionID: cid, database: db, kind: kind) { names in
                migrationRequest = MigrationRequest(
                    sourceConnectionID: cid, sourceDB: db,
                    preselected: names, targetConnectionID: nil, targetDB: nil
                )
            }
        case .table(let cid, let db, let t):
            TableDetailView(connectionID: cid, database: db, table: t)
        case .query(let id, _, let cid, let db):
            QueryView(tabID: id, connectionID: cid, initialDatabase: db)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.newQuery()
            } label: {
                Label("新建查询", systemImage: "plus.square")
            }
            .disabled(app.focusConnectionID == nil)

            Button {
                if case .table(let cid, let db, let t) = app.selectedTab {
                    exportRequest = ExportRequest(connectionID: cid, database: db, table: t)
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(!isTableTabSelected)

            Button {
                if let cid = app.focusConnectionID, let db = app.focusDatabase {
                    migrationRequest = MigrationRequest(
                        sourceConnectionID: cid, sourceDB: db,
                        preselected: nil, targetConnectionID: nil, targetDB: nil
                    )
                }
            } label: {
                Label("迁移", systemImage: "arrow.right.arrow.left.square")
            }
            .disabled(app.focusDatabase == nil)

            Button {
                if let tab = app.selectedTab { app.closeTab(tab) }
            } label: {
                Label("关闭标签页", systemImage: "xmark.square")
            }
            .disabled(app.selectedTab == nil)
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }

    private var isTableTabSelected: Bool {
        if case .table = app.selectedTab { return true }
        return false
    }
}

/// 导出弹窗请求
struct ExportRequest: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let database: String
    let table: String
}

/// 侧栏数据库节点的 NSDropDelegate：同时接受新拖拽会话（itemProvider）
/// 和 .draggable 字符串负载，兜底两条路径
struct TableDropDelegate: DropDelegate {
    let onDrop: (TableDragPayload) -> Bool
    let onTargeted: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mynavicatTables, .text])
    }

    func dropEntered(info: DropInfo) {
        onTargeted(true)
    }

    func dropExited(info: DropInfo) {
        onTargeted(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargeted(false)
        let providers = info.itemProviders(for: [.mynavicatTables, .text])
        guard let provider = providers.first else { return false }
        var handled = false
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let payload = TableDragPayload.decode(string) else { return }
            DispatchQueue.main.async {
                if self.onDrop(payload) { handled = true }
            }
        }
        return true
    }
}
