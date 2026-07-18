import AppKit
import MyNavicatCore
import SwiftUI

private enum SidebarSelection: Hashable {
    case database(String)
    case table(String)
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showConnections = false
    @State private var showExport = false
    @State private var showMigration = false
    @State private var sidebarSelection: SidebarSelection?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showConnections) {
            ConnectionManagerSheet()
        }
        .sheet(isPresented: $showExport) {
            if case .table(let db, let t) = app.selectedTab {
                ExportSheet(database: db, table: t)
            }
        }
        .sheet(isPresented: $showMigration) {
            if let db = app.selectedDatabase {
                MigrationSheet(sourceDB: db)
            }
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
                Picker("连接", selection: Binding(
                    get: { app.activeConnectionID },
                    set: { id in if let id { Task { await app.selectConnection(id) } } }
                )) {
                    ForEach(app.connections) { c in
                        Text(c.name).tag(Optional(c.id))
                    }
                }
                .labelsHidden()
                Button { showConnections = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("管理连接")
            }
            .padding(8)

            Divider()

            List(selection: $sidebarSelection) {
                Section("数据库") {
                    if app.loadingDatabases {
                        ProgressView("连接中…")
                    }
                    ForEach(app.databases, id: \.self) { db in
                        Label {
                            Text(db)
                        } icon: {
                            Image(systemName: "cylinder")
                                .foregroundStyle(AppState.systemSchemas.contains(db) ? .secondary : Color.accentColor)
                        }
                        .tag(SidebarSelection.database(db))
                    }
                }

                if app.selectedDatabase != nil {
                    Section("表 (\(app.tables.count))") {
                        if app.loadingTables {
                            ProgressView("加载中…")
                        }
                        ForEach(app.filteredTables) { t in
                            Label {
                                Text(t.name)
                            } icon: {
                                Image(systemName: t.isView ? "eye" : "tablecells")
                                    .foregroundStyle(t.isView ? .orange : Color.accentColor)
                            }
                            .tag(SidebarSelection.table(t.name))
                            .contextMenu {
                                Button("打开") { app.openTable(t.name) }
                                Button("复制表名") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(t.name, forType: .string)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: sidebarSelection) { _, new in
                switch new {
                case .database(let db):
                    if db != app.selectedDatabase {
                        app.selectedDatabase = db
                        app.tableFilter = ""
                        Task { await app.loadTables() }
                    }
                case .table(let name):
                    app.openTable(name)
                case nil:
                    break
                }
            }

            if app.selectedDatabase != nil {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选表", text: $app.tableFilter)
                        .textFieldStyle(.plain)
                }
                .padding(6)
            }
        }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if app.tabs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
                Text("在左侧选择数据库和表，或新建查询")
                    .foregroundStyle(.secondary)
                Button("新建查询") { app.newQuery() }
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
        case .table(let db, let t):
            TableDetailView(database: db, table: t)
        case .query(let id, _, let db):
            QueryView(tabID: id, initialDatabase: db)
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
            .disabled(app.activeConnection == nil)

            Button {
                showExport = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(!isTableTabSelected)

            Button {
                showMigration = true
            } label: {
                Label("迁移", systemImage: "arrow.right.arrow.left.square")
            }
            .disabled(app.selectedDatabase == nil)

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
