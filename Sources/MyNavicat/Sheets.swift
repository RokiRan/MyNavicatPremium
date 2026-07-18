import AppKit
import MyNavicatCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 连接管理

struct ConnectionManagerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: [ConnectionConfig] = []
    @State private var selection: UUID?
    @State private var testResult: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack {
                List(draft, selection: $selection) { c in
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text("\(c.host):\(c.port)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(c.id)
                }
                HStack {
                    Button {
                        let c = ConnectionConfig(name: "新连接 \(draft.count + 1)")
                        draft.append(c)
                        selection = c.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selection {
                            draft.removeAll { $0.id == selection }
                            self.selection = draft.first?.id
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 200)

            Divider()

            VStack {
                if let idx = draft.firstIndex(where: { $0.id == selection }) {
                    Form {
                        TextField("名称", text: $draft[idx].name)
                        TextField("主机", text: $draft[idx].host)
                        TextField("端口", value: $draft[idx].port, format: .number)
                        TextField("用户名", text: $draft[idx].username)
                        SecureField("密码", text: $draft[idx].password)
                        TextField("默认数据库（可选）", text: Binding(
                            get: { draft[idx].database ?? "" },
                            set: { draft[idx].database = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .padding()

                    HStack {
                        Button("测试连接") { test(draft[idx]) }
                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(testResult.hasPrefix("成功") ? .green : .red)
                        }
                        Spacer()
                    }
                    .padding([.horizontal, .bottom])
                } else {
                    ContentUnavailableView("选择或新建一个连接", systemImage: "network")
                }

                Divider()
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.isEmpty)
                }
                .padding()
            }
        }
        .frame(width: 620, height: 420)
        .onAppear {
            draft = app.connections
            selection = app.activeConnectionID ?? draft.first?.id
        }
    }

    private func test(_ config: ConnectionConfig) {
        testResult = "连接中…"
        Task {
            let s = MySQLSession(config: config)
            do {
                let v = try await s.ping()
                testResult = "成功 (MySQL \(v))"
            } catch {
                testResult = "失败：\(describe(error))"
            }
            await s.close()
        }
    }

    private func save() {
        app.connections = draft
        app.persistConnections()
        dismiss()
        // 配置可能变了，丢弃旧会话重连
        if app.activeConnectionID != nil {
            Task { await app.reconnectActive() }
        }
    }
}

// MARK: - 导出

struct ExportSheet: View {
    let database: String
    let table: String

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .csv
    @State private var includeStructure = true
    @State private var destURL: URL?
    @State private var running = false
    @State private var progressRows = 0
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出 \(database).\(table)").font(.headline)

            Form {
                Picker("格式", selection: $format) {
                    Text("CSV").tag(ExportFormat.csv)
                    Text("JSON").tag(ExportFormat.json)
                    Text("SQL (INSERT 语句)").tag(ExportFormat.sql)
                }
                if format == .sql {
                    Toggle("包含建表语句 (DROP + CREATE)", isOn: $includeStructure)
                }
                HStack {
                    Text(destURL?.path ?? "未选择")
                        .foregroundStyle(destURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择位置…") { chooseDestination() }
                }
            }

            if running {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("已导出 \(progressRows) 行…")
                }
            }
            if let message {
                Text(message)
                    .foregroundStyle(failed ? .red : .green)
                    .textSelection(.enabled)
            }

            Spacer()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button("开始导出") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destURL == nil || running)
            }
        }
        .padding()
        .frame(width: 520, height: 320)
        .onChange(of: format) { _, _ in destURL = nil }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table).\(format.fileExtension)"
        switch format {
        case .csv: panel.allowedContentTypes = [.commaSeparatedText]
        case .json: panel.allowedContentTypes = [.json]
        case .sql: break
        }
        if panel.runModal() == .OK {
            destURL = panel.url
        }
    }

    private func start() {
        guard let destURL else { return }
        running = true
        message = nil
        failed = false
        progressRows = 0
        Task {
            do {
                let s = try await app.session()
                let n = try await Exporter.export(
                    session: s,
                    database: database,
                    table: table,
                    format: format,
                    to: destURL,
                    options: ExportOptions(includeStructure: includeStructure),
                    progress: { n in
                        Task { @MainActor [self] in progressRows = n }
                    }
                )
                message = "完成：导出 \(n) 行 → \(destURL.path)"
            } catch {
                failed = true
                message = describe(error)
            }
            running = false
        }
    }
}

// MARK: - 跨库迁移

struct MigrationSheet: View {
    let sourceDB: String

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var targetConnectionID: UUID?
    @State private var targetDBs: [String] = []
    @State private var targetDBName = ""
    @State private var createStructure = true
    @State private var dropIfExists = true
    @State private var selectedTables: Set<String> = []
    @State private var running = false
    @State private var progressText = ""
    @State private var logs: [String] = []
    @State private var message: String?
    @State private var failed = false

    private var targetConnection: ConnectionConfig? {
        app.connections.first { $0.id == targetConnectionID }
    }

    /// 同连接同库 = 源，执行会先 DROP 掉源表，必须禁止
    private var isSameAsSource: Bool {
        targetConnectionID == app.activeConnectionID && targetDBName == sourceDB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据迁移").font(.headline)

            HStack(alignment: .top) {
                Form {
                    LabeledContent("来源") {
                        Text("\(app.activeConnection?.name ?? "-") · \(sourceDB)")
                    }
                    Picker("目标连接", selection: $targetConnectionID) {
                        ForEach(app.connections) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                    .onChange(of: targetConnectionID) { _, _ in loadTargetDBs() }

                    Picker("目标已有库", selection: $targetDBName) {
                        Text("（选择已有库）").tag("")
                        ForEach(targetDBs, id: \.self) { db in
                            Text(db).tag(db)
                        }
                    }
                    TextField("新库名（自动创建）", text: $targetDBName)

                    Toggle("迁移结构（建表语句）", isOn: $createStructure)
                    Toggle("覆盖已存在的表", isOn: $dropIfExists)
                        .disabled(!createStructure)
                }
                .frame(width: 300)

                VStack(alignment: .leading) {
                    HStack {
                        Text("选择表 (\(selectedTables.count)/\(app.tables.count))")
                        Spacer()
                        Button("全选") { selectedTables = Set(app.tables.map(\.name)) }
                        Button("清空") { selectedTables = [] }
                    }
                    .font(.caption)
                    List(app.tables) { t in
                        HStack {
                            Image(systemName: selectedTables.contains(t.name) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedTables.contains(t.name) ? Color.accentColor : .secondary)
                            Text(t.name)
                            if t.isView {
                                Text("视图").font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedTables.contains(t.name) {
                                selectedTables.remove(t.name)
                            } else {
                                selectedTables.insert(t.name)
                            }
                        }
                    }
                    .border(Color(nsColor: .separatorColor))
                }
            }

            if running {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text(progressText)
                }
            }
            if !logs.isEmpty {
                ScrollView {
                    Text(logs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
            }
            if let message {
                Text(message)
                    .foregroundStyle(failed ? .red : .green)
            }
            if isSameAsSource {
                Text("目标与源相同，不能迁移到自己（会先 DROP 源表）")
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .disabled(running)
                Button("开始迁移") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || selectedTables.isEmpty || targetDBName.isEmpty || targetConnection == nil || isSameAsSource)
            }
        }
        .padding()
        .frame(width: 680, height: 560)
        .onAppear {
            targetConnectionID = app.activeConnectionID
            targetDBName = sourceDB
            selectedTables = Set(app.tables.map(\.name))
            loadTargetDBs()
        }
    }

    private func loadTargetDBs() {
        guard let target = targetConnection else { return }
        Task {
            do {
                let s = try await app.session(for: target)
                targetDBs = try await s.listDatabases()
            } catch {
                message = "目标连接失败：\(describe(error))"
                failed = true
            }
        }
    }

    private func start() {
        guard let target = targetConnection else { return }
        running = true
        failed = false
        message = nil
        logs = []
        progressText = ""
        let tables = app.tables.filter { selectedTables.contains($0.name) }
        let options = MigrationOptions(
            createDatabaseIfMissing: true,
            createStructure: createStructure,
            dropIfExists: dropIfExists
        )
        let targetDB = targetDBName
        Task {
            do {
                let source = try await app.session()
                let targetSession = try await app.session(for: target)
                let total = try await Migrator.migrate(
                    source: source,
                    sourceDB: sourceDB,
                    tables: tables,
                    target: targetSession,
                    targetDB: targetDB,
                    options: options,
                    log: { line in
                        Task { @MainActor [self] in logs.append(line) }
                    },
                    progress: { table, n in
                        Task { @MainActor [self] in progressText = "\(table)：已复制 \(n) 行" }
                    }
                )
                message = "完成：\(tables.count) 张表，共迁移 \(total) 行"
            } catch {
                failed = true
                message = describe(error)
            }
            running = false
        }
    }
}
