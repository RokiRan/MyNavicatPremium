import AppKit
import MyNavicatCore
import SwiftUI

/// TextKit2 SQL 编辑器：语法高亮（关键字/字符串/注释/数字/反引号标识符）。
/// 配色全部用自适应系统色，深浅色模式自动切换。
struct SQLEditor: NSViewRepresentable {

    @Binding var text: String

    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
    ]

    private static func color(for kind: SQLTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .systemGreen
        case .number: .systemBlue
        case .quotedIdentifier: .systemBrown
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit2 栈：contentStorage → layoutManager → container → textView。
        // 不触碰 textView.layoutManager / textView.textContainer 等 TextKit1 访问器以免降级。
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 显式给 container 尺寸：宽度随 textView，高度无限（纵向滚动）
        let container = NSTextContainer(size: NSSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        // SQL 编辑器禁用一切自动替换/拼写
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TK2 栈的 retain 链较弱，coordinator 强引用保住 contentStorage/layoutManager
        context.coordinator.retainTextKitStack(contentStorage, layoutManager)
        context.coordinator.textView = textView
        context.coordinator.setText(text, external: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // 仅处理外部对 binding 的修改；编辑器内输入走 textDidChange，这里 string 已一致
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        context.coordinator.setText(text, external: true)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        /// 外部写入/高亮应用期间置 true，避免 textDidChange 反馈环
        private var applying = false
        private var stack: (NSTextContentStorage, NSTextLayoutManager)?

        init(text: Binding<String>) {
            _text = text
        }

        func retainTextKitStack(_ storage: NSTextContentStorage, _ layout: NSTextLayoutManager) {
            stack = (storage, layout)
        }

        /// 外部文本写入（初始值 / 未来对象补全插入 SQL 片段），保持选区不越界
        func setText(_ newText: String, external: Bool) {
            guard let textView else { return }
            applying = true
            let selected = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: newText, attributes: SQLEditor.baseAttributes)
            )
            let location = min(selected.location, newText.utf16.count)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            highlight(textView)
            applying = false
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView else { return }
            text = textView.string
            highlight(textView)
        }

        /// 全量重着色：先重置为基础属性，再叠加 token 颜色。
        /// 属性变更不进 undo 栈、不影响选区。查询级文本规模下 O(n) 足够。
        private func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(SQLEditor.baseAttributes, range: full)
            for token in SQLLexer.tokenize(textView.string) {
                storage.addAttribute(
                    .foregroundColor,
                    value: SQLEditor.color(for: token.kind),
                    range: token.utf16Range
                )
            }
            storage.endEditing()
        }
    }
}
