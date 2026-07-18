import AppKit
import MyNavicatCore
import SwiftUI
import UniformTypeIdentifiers

/// 应用内拖拽表的专用类型（声明在 Info.plist 的 UTExportedTypeDeclarations）
extension UTType {
    static let mynavicatTables = UTType("com.mynavicat.tables") ?? .data
}

/// 数据长度格式化，对齐 Navicat 风格：16 KB / 7.5 MB / 1.2 GB
func formatDataLength(_ n: Int64?) -> String {
    guard let n else { return "" }
    let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
    let v = Double(n)
    switch v {
    case ..<(kb): return "\(n) B"
    case ..<(mb): return "\(Int((v / kb).rounded())) KB"
    case ..<(gb):
        let s = String(format: "%.1f", v / mb)
        return "\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s) MB"
    default:
        let s = String(format: "%.1f", v / gb)
        return "\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s) GB"
    }
}

/// 行数格式化：13,297
func formatRowCount(_ n: Int64?) -> String {
    guard let n else { return "" }
    return n.formatted(.number)
}

/// Optional 没有 Comparable 遵循，SwiftUI 排序列需要非可选键。
/// NULL 统一按最小值处理（-1 / 空串），排在最前。
private extension TableInfo {
    var sortRows: Int64 { estimatedRows ?? -1 }
    var sortDataLength: Int64 { dataLength ?? -1 }
    var sortCreatedAt: String { createdAt ?? "" }
    var sortUpdatedAt: String { updatedAt ?? "" }
}

/// 铺在 Table 背景里的 NSView：监听本窗口双击（clickCount==2），
/// 命中自身区域（排除列表头）时回调。SwiftUI Table 不提供双击 API，
/// 单元格内的 onTapGesture 又会被行选中手势拦截，只能下沉到 NSView。
private struct DoubleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(action: action)
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    final class CatcherView: NSView {
        var action: () -> Void
        private var monitor: Any?
        /// 列表头高度，双击表头（排序）不触发打开；行高 24，首行从 30 以下开始
        private let headerHeight: CGFloat = 30
        /// 上一次点击的位置/时间：合成事件 clickCount 恒为 0，
        /// 用快速二连击兑底识别双击（阈值取系统双击间隔）
        private var lastUp: (time: Date, point: CGPoint)?

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                // 监听 mouseDown 而非 mouseUp：NSTableView 的行选中在 tracking loop
                // 里直接消费 mouseUp（不经 sendEvent），local monitor 收不到
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, event.window == self.window else { return event }
                    let p = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(p), p.y < self.bounds.height - self.headerHeight else {
                        self.lastUp = nil
                        return event
                    }
                    let now = Date()
                    let rapidPair = self.lastUp.map {
                        now.timeIntervalSince($0.time) < NSEvent.doubleClickInterval
                            && abs($0.point.x - p.x) < 6 && abs($0.point.y - p.y) < 6
                    } ?? false
                    self.lastUp = (now, p)
                    if event.clickCount == 2 || rapidPair {
                        self.lastUp = nil
                        self.action()
                    }
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// 对象视图：某个库下表/视图的列表（Navicat 右侧内容区）。
/// 支持多选、按列排序、搜索、双击/回车打开、拖拽到侧栏数据库触发迁移。
struct ObjectView: View {
    let connectionID: UUID
    let database: String
    let kind: ObjectKind
    /// 右键「迁移到…」：把选中的表名交给上层（ContentView 统一弹迁移窗口）
    let onMigrate: (Set<String>) -> Void

    @EnvironmentObject var app: AppState

    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<TableInfo>] = [
        .init(\.name, order: .forward)
    ]
    @State private var search = ""

    private var allObjects: [TableInfo] {
        app.tables(for: connectionID, database: database).filter(kind.matches)
    }

    private var objects: [TableInfo] {
        var list = allObjects
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        list.sort(using: sortOrder)
        return list
    }

    private var connectionName: String {
        app.config(for: connectionID)?.name ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.isLoadingTables(connectionID, database: database), allObjects.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("加载对象列表…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            Divider()
            footer
        }
        .task {
            app.ensureTables(connectionID, database: database)
        }
    }

    // MARK: - 头部：对象 + 面包屑 + 刷新 + 搜索

    private var header: some View {
        HStack(spacing: 10) {
            Text("对象")
                .font(.headline)
            Label {
                Text("\(kind.title) @ \(database)")
            } icon: {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(Color.accentColor)
            }
            Text("(\(connectionName))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                Task { await app.refreshTables(connectionID, database: database) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .disabled(app.isLoadingTables(connectionID, database: database))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 对象列表

    private var table: some View {
        Table(of: TableInfo.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { (t: TableInfo) in
                HStack(spacing: 6) {
                    Image(systemName: t.isView ? "eye" : "tablecells")
                        .foregroundStyle(t.isView ? .orange : Color.accentColor)
                    Text(t.name).textSelection(.enabled)
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("行", value: \.sortRows) { (t: TableInfo) in
                Text(formatRowCount(t.estimatedRows))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("数据长度", value: \.sortDataLength) { (t: TableInfo) in
                Text(formatDataLength(t.dataLength))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("引擎", value: \.engine) { (t: TableInfo) in
                Text(t.engine).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("创建日期", value: \.sortCreatedAt) { (t: TableInfo) in
                Text(t.createdAt ?? "").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("修改日期", value: \.sortUpdatedAt) { (t: TableInfo) in
                Text(t.updatedAt ?? "").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("排序规则", value: \.collation) { (t: TableInfo) in
                Text(t.collation).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("注释", value: \.comment) { (t: TableInfo) in
                Text(t.comment)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(objects) { t in
                TableRow(t)
                    .itemProvider { dragProvider(for: t) }
            }
        }
        .contextMenu(forSelectionType: String.self) { items in
            if let first = items.sorted().first {
                Button("打开") { app.openTable(connectionID, database: database, table: first) }
            }
            Button(items.count > 1 ? "复制 \(items.count) 个表名" : "复制表名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.sorted().joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("迁移到…") { onMigrate(items) }
        }
        // SwiftUI Table 的行手势会吃掉单元格内的 onTapGesture，
        // 双击打开只能用 NSView 级监听实现（见文件底部 DoubleClickCatcher）
        .background(DoubleClickCatcher {
            if selection.count == 1, let name = selection.first {
                app.openTable(connectionID, database: database, table: name)
            }
        })
        .onKeyPress(.return) {
            if selection.count == 1, let name = selection.first {
                app.openTable(connectionID, database: database, table: name)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - 底部状态栏

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(objects.count) 个\(kind.title == "表" ? "表" : "视图")")
                .foregroundStyle(.secondary)
            if !selection.isEmpty {
                Text("已选 \(selection.count)")
                    .foregroundStyle(.secondary)
                Text("可拖动到左侧目标数据库进行迁移")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 拖拽

    /// 拖的表在选中集里就带走整组，否则只带这一张
    private func dragProvider(for t: TableInfo) -> NSItemProvider {
        let names: [String]
        if selection.contains(t.name), selection.count > 1 {
            names = objects.filter { selection.contains($0.name) }.map(\.name)
        } else {
            names = [t.name]
        }
        let string = TableDragPayload(
            connectionID: connectionID,
            database: database,
            tables: names
        ).encode() ?? ""
        return NSItemProvider(object: string as NSString)
    }
}
