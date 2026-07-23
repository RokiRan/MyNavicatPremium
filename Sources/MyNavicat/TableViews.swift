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

/// 通用结果网格；传入 selection 即开启行选择（数据编辑用）
struct ResultGrid: View {
    let columns: [String]
    let rows: [GridRow]
    var selection: Binding<Set<GridRow.ID>>? = nil

    var body: some View {
        if let selection {
            Table(rows, selection: selection) { columnContent }
        } else {
            Table(rows) { columnContent }
        }
    }

    @TableColumnBuilder<GridRow, Never>
    private var columnContent: some TableColumnContent<GridRow, Never> {
        TableColumnForEach(Array(columns.enumerated()), id: \.offset) { pair in
            TableColumn(pair.element) { (row: GridRow) in
                cellView(row.cells[safe: pair.offset] ?? nil)
            }
            .width(min: 60, ideal: 150, max: 600)
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
    let connectionID: UUID
    let database: String
    let table: String

    @State private var segment = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(database).\(table)")
                    .font(.headline)
                Text(app.config(for: connectionID)?.name ?? "")
                    .foregroundStyle(.secondary)
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
                StructureView(connectionID: connectionID, database: database, table: table)
            } else {
                DataView(connectionID: connectionID, database: database, table: table)
            }
        }
    }

    @EnvironmentObject var app: AppState
}

/// 表结构：列定义 + 建表语句
struct StructureView: View {
    let connectionID: UUID
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
            let s = try await app.session(connectionID: connectionID)
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
    let connectionID: UUID
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
    @State private var columnInfos: [ColumnInfo] = []
    @State private var selection: Set<GridRow.ID> = []
    @State private var editContext: EditContext?
    @State private var confirmDelete = false

    /// 主键列；无主键的表/视图行编辑、删除不可用
    private var pkColumns: [ColumnInfo] { columnInfos.filter { $0.key == "PRI" } }

    struct EditContext: Identifiable {
        let id = UUID()
        /// nil = 新增行
        let row: GridRow?
    }

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

                Divider().frame(height: 18)

                Button { editContext = EditContext(row: nil) } label: {
                    Image(systemName: "plus")
                }
                .help("新增行")
                .disabled(loading || columnInfos.isEmpty)
                Button {
                    if let row = rows.first(where: { selection.contains($0.id) }) {
                        editContext = EditContext(row: row)
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .help(pkColumns.isEmpty ? "无主键表不可编辑" : "编辑选中行")
                .disabled(loading || selection.count != 1 || pkColumns.isEmpty)
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
                .help(pkColumns.isEmpty ? "无主键表不可删除" : "删除选中行")
                .disabled(loading || selection.isEmpty || pkColumns.isEmpty)

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
                ResultGrid(columns: columns, rows: rows, selection: $selection)
                    .onDeleteCommand {
                        if !selection.isEmpty && !pkColumns.isEmpty { confirmDelete = true }
                    }
            }
        }
        .task {
            await load(page: 0)
        }
        .sheet(item: $editContext) { ctx in
            RowEditSheet(
                connectionID: connectionID, database: database, table: table,
                columnInfos: columnInfos, orderedNames: columns, row: ctx.row
            ) {
                Task { await load(page: page) }
            }
        }
        .confirmationDialog("删除 \(selection.count) 行？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("按主键逐行删除，不可撤销")
        }
    }

    /// 选中行的主键定位信息（列 + 展示值）
    private func identity(of row: GridRow) -> [(column: ColumnInfo, displayValue: String?)] {
        pkColumns.map { col in
            let value = columns.firstIndex(of: col.name).flatMap { row.cells[safe: $0] } ?? nil
            return (col, value)
        }
    }

    private func deleteSelected() async {
        do {
            let s = try await app.session(connectionID: connectionID)
            var firstError: String?
            var failed = 0
            for row in rows where selection.contains(row.id) {
                do {
                    try await s.deleteRow(database: database, table: table, identity: identity(of: row))
                } catch {
                    failed += 1
                    if firstError == nil { firstError = describe(error) }
                }
            }
            selection.removeAll()
            await load(page: page)
            if failed > 0 {
                error = "\(failed) 行删除失败\(firstError.map { "：\($0)" } ?? "")"
            }
        } catch {
            self.error = describe(error)
        }
    }

    private func load(page newPage: Int) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let s = try await app.session(connectionID: connectionID)
            async let cols = s.tableColumns(database: database, table: table)
            total = try await s.countRows(database: database, table: table)
            let clamped = min(max(0, newPage), pageCount - 1)
            let r = try await s.fetchRows(database: database, table: table, limit: pageSize, offset: clamped * pageSize)
            columnInfos = try await cols
            if r.columns.isEmpty {
                // 空表没有结果集元数据，用列定义兜底表头
                columns = columnInfos.map(\.name)
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

/// 行编辑/新增面板：按列逐一填写，可空列可勾选 NULL；
/// 编辑模式以主键原始值定位（WHERE pk... LIMIT 1），自增/生成列留空交给数据库默认
struct RowEditSheet: View {
    let connectionID: UUID
    let database: String
    let table: String
    let columnInfos: [ColumnInfo]
    /// 网格列顺序（SELECT * 顺序），用于从展示行取值
    let orderedNames: [String]
    /// nil = 新增模式
    let row: GridRow?
    let onSaved: () -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    struct Field: Identifiable {
        let id = UUID()
        let column: ColumnInfo
        var text: String
        var isNull: Bool
        /// auto_increment / generated：留空时跳过该列
        let auto: Bool
    }

    @State private var fields: [Field] = []
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(row == nil ? "新增行" : "编辑行").font(.headline)
                Text("\(database).\(table)").foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            Divider()
            ScrollView {
                Form {
                    ForEach($fields) { $f in fieldRow($f) }
                }
                .padding()
            }
            if let error {
                ErrorBanner(message: error)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || fields.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 480)
        .onAppear { initFields() }
    }

    @ViewBuilder
    private func fieldRow(_ f: Binding<Field>) -> some View {
        let col = f.wrappedValue.column
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(col.name).font(.headline)
                Text(col.columnType).font(.caption).foregroundStyle(.secondary)
                if col.key == "PRI" {
                    Image(systemName: "key.fill").foregroundStyle(.yellow).help("主键")
                }
                Spacer()
                if col.isNullable {
                    Toggle("NULL", isOn: f.isNull).toggleStyle(.checkbox)
                }
            }
            TextField(f.wrappedValue.auto ? "留空则自动生成" : "", text: f.text)
                .textFieldStyle(.roundedBorder)
                .disabled(f.wrappedValue.isNull)
        }
    }

    private func initFields() {
        fields = columnInfos.map { col in
            let auto = col.extra.localizedCaseInsensitiveContains("auto_increment")
                || col.extra.localizedCaseInsensitiveContains("generated")
            if let row, let idx = orderedNames.firstIndex(of: col.name) {
                let value = row.cells[safe: idx] ?? nil
                return Field(column: col, text: value ?? "", isNull: value == nil, auto: auto)
            }
            return Field(column: col, text: "", isNull: false, auto: auto)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let s = try await app.session(connectionID: connectionID)
            if let row {
                // 编辑：主键列取原始展示值定位，所有列按表单值写回
                let identity: [(column: ColumnInfo, displayValue: String?)] = columnInfos
                    .filter { $0.key == "PRI" }
                    .map { col in
                        let value = orderedNames.firstIndex(of: col.name).flatMap { row.cells[safe: $0] } ?? nil
                        return (col, value)
                    }
                try await s.updateRow(
                    database: database, table: table,
                    identity: identity,
                    set: fields.map { ($0.column, $0.isNull ? nil : $0.text) }
                )
            } else {
                // 新增：自增/生成列留空则跳过，交给数据库默认值
                let values: [(column: ColumnInfo, input: String?)] = fields.compactMap { f in
                    if f.auto && !f.isNull && f.text.isEmpty { return nil }
                    return (f.column, f.isNull ? nil : f.text)
                }
                try await s.insertRow(database: database, table: table, values: values)
            }
            onSaved()
            dismiss()
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
