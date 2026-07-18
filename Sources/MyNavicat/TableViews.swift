import MyNavicatCore
import SwiftUI

struct GridRow: Identifiable {
    let id: Int
    let cells: [String?]
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 通用结果网格
struct ResultGrid: View {
    let columns: [String]
    let rows: [GridRow]

    var body: some View {
        Table(rows) {
            TableColumnForEach(Array(columns.enumerated()), id: \.offset) { pair in
                TableColumn(pair.element) { (row: GridRow) in
                    cellView(row.cells[safe: pair.offset] ?? nil)
                }
                .width(min: 60, ideal: 150, max: 600)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ value: String?) -> some View {
        if let value {
            Text(value)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
        } else {
            Text("NULL")
                .italic()
                .foregroundStyle(.tertiary)
        }
    }
}

/// 表详情：结构 / 数据
struct TableDetailView: View {
    let database: String
    let table: String

    @State private var segment = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(database).\(table)")
                    .font(.headline)
                Spacer()
                Picker("", selection: $segment) {
                    Text("结构").tag(0)
                    Text("数据").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(10)
            Divider()
            if segment == 0 {
                StructureView(database: database, table: table)
            } else {
                DataView(database: database, table: table)
            }
        }
    }
}

/// 表结构：列定义 + 建表语句
struct StructureView: View {
    let database: String
    let table: String

    @EnvironmentObject var app: AppState
    @State private var columns: [ColumnInfo] = []
    @State private var ddl: String = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                ErrorBanner(message: error)
            }
            Table(columns) {
                TableColumn("名称") { (c: ColumnInfo) in
                    HStack(spacing: 4) {
                        if c.key == "PRI" {
                            Image(systemName: "key.fill").foregroundStyle(.yellow)
                                .help("主键")
                        }
                        Text(c.name).textSelection(.enabled)
                    }
                }
                .width(min: 100, ideal: 160)
                TableColumn("类型") { (c: ColumnInfo) in Text(c.columnType).textSelection(.enabled) }
                    .width(min: 100, ideal: 140)
                TableColumn("可空") { (c: ColumnInfo) in Text(c.isNullable ? "YES" : "NO") }
                    .width(ideal: 50, max: 70)
                TableColumn("键") { (c: ColumnInfo) in Text(c.key) }
                    .width(ideal: 45, max: 60)
                TableColumn("默认值") { (c: ColumnInfo) in
                    Text(c.defaultValue ?? "NULL").foregroundStyle(c.defaultValue == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
                .width(min: 60, ideal: 90)
                TableColumn("额外") { (c: ColumnInfo) in Text(c.extra) }
                    .width(min: 60, ideal: 110)
                TableColumn("注释") { (c: ColumnInfo) in Text(c.comment).textSelection(.enabled) }
                    .width(min: 80, ideal: 140)
            }

            if !ddl.isEmpty {
                DisclosureGroup("建表语句") {
                    ScrollView {
                        Text(ddl)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .padding(8)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        do {
            let s = try await app.session()
            async let cols = s.tableColumns(database: database, table: table)
            async let d = s.showCreateTable(database: database, table: table)
            columns = try await cols
            ddl = (try? await d) ?? ""
        } catch {
            self.error = describe(error)
        }
    }
}

/// 表数据：分页网格
struct DataView: View {
    let database: String
    let table: String

    @EnvironmentObject var app: AppState
    @State private var columns: [String] = []
    @State private var rows: [GridRow] = []
    @State private var total: Int64 = 0
    @State private var page = 0
    @State private var pageSize = 500
    @State private var loading = false
    @State private var error: String?

    private var pageCount: Int {
        max(1, Int((total + Int64(pageSize) - 1) / Int64(pageSize)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await load(page: page) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                .disabled(loading)

                Button { Task { await load(page: 0) } } label: {
                    Image(systemName: "backward.end")
                }
                .disabled(loading || page == 0)
                Button { Task { await load(page: page - 1) } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(loading || page == 0)

                Text("第 \(page + 1) / \(pageCount) 页")

                Button { Task { await load(page: page + 1) } } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(loading || page + 1 >= pageCount)
                Button { Task { await load(page: pageCount - 1) } } label: {
                    Image(systemName: "forward.end")
                }
                .disabled(loading || page + 1 >= pageCount)

                Spacer()

                Picker("每页", selection: $pageSize) {
                    Text("100 / 页").tag(100)
                    Text("500 / 页").tag(500)
                    Text("2000 / 页").tag(2000)
                }
                .frame(width: 110)
                .onChange(of: pageSize) { _, _ in Task { await load(page: 0) } }

                Text("共 \(total) 行")
                    .foregroundStyle(.secondary)
                if loading { ProgressView().scaleEffect(0.6) }
            }
            .padding(8)

            Divider()

            if let error {
                ErrorBanner(message: error)
            }
            if columns.isEmpty && !loading {
                ContentUnavailableView("没有数据", systemImage: "tray")
            } else {
                ResultGrid(columns: columns, rows: rows)
            }
        }
        .task {
            await load(page: 0)
        }
    }

    private func load(page newPage: Int) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let s = try await app.session()
            total = try await s.countRows(database: database, table: table)
            let clamped = min(max(0, newPage), pageCount - 1)
            let r = try await s.fetchRows(database: database, table: table, limit: pageSize, offset: clamped * pageSize)
            if r.columns.isEmpty {
                // 空表没有结果集元数据，用列定义兜底表头
                columns = try await s.tableColumns(database: database, table: table).map(\.name)
                rows = []
            } else {
                columns = r.columns
                rows = r.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }
            }
            page = clamped
        } catch {
            self.error = describe(error)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}
