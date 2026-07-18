import AppKit
import SwiftUI

@main
struct MyNavicatApp: App {
    @StateObject private var app = AppState()

    init() {
        // 裸可执行文件运行时默认是 BackgroundOnly，不会创建窗口
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MyNavicat — MySQL 客户端") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { app.startup() }
        }
        .windowToolbarStyle(.unified)
    }
}
