import MyNavicatCore
import SwiftUI

/// SQL 查询编辑器
struct QueryView: View {
    let tabID: UUID
    let initialDatabase: String?

    @EnvironmentObject var app: AppState

    @State private var sql: String
    @State private var database: String?
    @State private var outcomes: [StatementOutcome] = []
    @State private var running = false
    @State private var duration: TimeInterval?
    @State private var errorMessage: String?

    init(tabID: UUID, initialDatabase: String?) {
        self.tabID = tabID
        self.initialDatabase = initialDatabase
        _database = State(initialValue: initialDatabase)
        _sql = State(initialValue: initialDatabase.map { "-- 当前数据库: \($0)\n" } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { run() } label: {
                    Label("运行", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(running || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Picker("数据库", selection: $database) {
                    Text("不限定").tag(Optional<String>.none)
                    ForEach(app.databases, id: \.self) { db in
                        Text(db).tag(Optional(db))
                    }
                }
                .frame(width: 200)

                Spacer()
                if let duration {
                    Text(String(format: "%.3f 秒", duration))
                        .foregroundStyle(.secondary)
                }
                if running { ProgressView().scaleEffect(0.6) }
            }
            .padding(8)

            TextEditor(text: $sql)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 220)
                .border(Color(nsColor: .separatorColor))

            Divider()

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { pair in
                        outcomeView(pair.offset, pair.element)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func outcomeView(_ index: Int, _ outcome: StatementOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(index + 1)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(outcome.sql)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            if let err = outcome.error {
                ErrorBanner(message: err)
            } else if let r = outcome.result {
                if r.isResultSet {
                    if r.rows.isEmpty {
                        Text("返回 0 行")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("返回 \(r.rows.count) 行")
                            .foregroundStyle(.secondary)
                        ResultGrid(
                            columns: r.columns,
                            rows: r.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }
                        )
                        .frame(minHeight: 200, maxHeight: 420)
                        .border(Color(nsColor: .separatorColor))
                    }
                } else {
                    Text("执行成功，影响 \(r.affectedRows ?? 0) 行")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func run() {
        let statements = SQL.splitStatements(sql)
        guard !statements.isEmpty else { return }
        running = true
        outcomes = []
        errorMessage = nil
        duration = nil
        let started = Date()
        Task {
            defer { running = false }
            do {
                let s = try await app.session()
                var batch: [String] = []
                if let database {
                    batch.append("USE \(SQL.qi(database))")
                }
                batch.append(contentsOf: statements)
                let results = await s.runScript(batch)
                outcomes = database != nil ? Array(results.dropFirst()) : results
                duration = Date().timeIntervalSince(started)
            } catch {
                errorMessage = describe(error)
            }
        }
    }
}
