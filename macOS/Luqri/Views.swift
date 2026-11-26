import AppKit
import SwiftUI
import Translation

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        if let image = Self.load(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @MainActor
    static func menuImage(_ name: String, size: CGFloat) -> NSImage? {
        guard let icon = load(name)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: size, height: size)
        icon.isTemplate = true
        return icon
    }

    @MainActor
    private static func load(_ name: String) -> NSImage? {
        let cacheKey = NSImage.Name("Luqri.Lucide.\(name)")
        if let image = NSImage(named: cacheKey) { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.setName(cacheKey)
        return image
    }
}

@MainActor
final class UtilityPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onEditorReturn: (() -> Bool)?
    weak var sourceEditor: NSTextView? {
        didSet { focusEditorOnOpen() }
    }
    private var didFocusEditor = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func becomeKey() {
        super.becomeKey()
        focusEditorOnOpen()
    }

    @discardableResult
    func focusSourceEditor() -> Bool {
        guard let sourceEditor, sourceEditor.window === self else { return false }
        return makeFirstResponder(sourceEditor)
    }

    private func focusEditorOnOpen() {
        guard isKeyWindow, !didFocusEditor else { return }
        didFocusEditor = focusSourceEditor()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.charactersIgnoringModifiers == "\r",
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           let editor = firstResponder as? NSTextView, !editor.hasMarkedText(),
           let onEditorReturn, event.isARepeat || onEditorReturn() { return }
        super.sendEvent(event)
    }
}

private struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, prominent: prominent, cornerRadius: cornerRadius)
    }

    private struct ButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        let configuration: Configuration
        let prominent: Bool
        let cornerRadius: CGFloat

        var body: some View {
            configuration.label
                .foregroundColor(prominent ? prominentTextColor : nil)
                .background {
                    let shape = RoundedRectangle(cornerRadius: cornerRadius)
                    if prominent {
                        shape.fill(isEnabled ? Color.accentColor : Color.primary.opacity(0.09))
                        if isEnabled {
                            shape.fill(.black.opacity(configuration.isPressed ? 0.18 : hovered ? 0.08 : 0))
                        }
                    } else {
                        shape.fill(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.14 : hovered ? 0.075 : 0) : 0))
                    }
                }
                .opacity(isEnabled || prominent ? 1 : 0.42)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
        }

        private var prominentTextColor: Color {
            isEnabled ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary
        }
    }
}

struct TranslationView: View {
    static let preferredWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 13
    private static let windowPadding: CGFloat = 12
    private static let editorPadding: CGFloat = 8

    @State private var editorFocused = false
    @State private var editorMeasurements = TranslationEditor.HeightCache()
    @State private var pinned = false
    @State private var collapsedProviders = Set<Provider>()
    @State private var copiedSource = false
    @State private var copiedResult: Provider?
    @State private var speech: SpeechPlayback?
    @State private var showEmptyClipboardHint = false

    @Bindable var model: TranslationModel
    let availableHeight: CGFloat
    let focusEditor: () -> Void
    let close: () -> Void
    let openSettings: () -> Void
    let setPinned: (Bool) -> Void
    let resize: (CGSize) -> Void

    private var hasText: Bool { model.hasText }

    private var editorText: Binding<String> {
        Binding(get: { model.text }, set: { model.edit($0) })
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.055))
    }

    var body: some View {
        let providers = model.enabledProviders
        let expanded = hasText ? providers.filter { !collapsedProviders.contains($0) }.count : 0
        let visibleResults = CGFloat(max(1, expanded))
        // Reserve room for the service cards and their controls on short displays.
        let controlsHeight = 110 + 42 * CGFloat(providers.count) + 50 * visibleResults
        let speechErrorHeight: CGFloat = speech?.error == nil ? 0 : 32
        let contentHeight = availableHeight - controlsHeight - speechErrorHeight
        let editorLimit = max(TranslationEditor.minimumHeight, contentHeight - 48 * visibleResults)
        let editorHeight = editorMeasurements.height(
            for: model.isLoadingInput ? "" : model.text,
            width: Self.preferredWidth - 2 * (Self.windowPadding + Self.editorPadding),
            maximumHeight: min(TranslationEditor.maximumHeight, availableHeight * 0.3, editorLimit)
        )
        let resultHeight = max(24, min(expanded > 1 ? 160 : 220, (contentHeight - editorHeight) / visibleResults))
        VStack(alignment: .leading, spacing: 8) {
            header
            editor(height: editorHeight)
            if let error = speech?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !hasText && showEmptyClipboardHint {
                clipboardHint
            }
            if providers.isEmpty {
                notice("请先开启翻译服务", action: "打开设置", perform: openSettings)
            } else {
                ForEach(providers) { provider in
                    serviceRow(provider, resultHeight: resultHeight)
                }
            }
        }
        .padding(Self.windowPadding)
        .frame(width: Self.preferredWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGSize.self, of: { proxy in
            CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height))
        }, action: resize)
        .onDisappear { speech?.stop() }
        .onChange(of: model.text) {
            copiedSource = false
            if hasText { showEmptyClipboardHint = false }
            speech?.stop()
        }
        .onChange(of: model.isTranslating) {
            if model.isTranslating { collapsedProviders.removeAll() }
        }
        .onChange(of: model.enabledProviders) {
            collapsedProviders.formIntersection(model.enabledProviders)
            if case .translation(let provider) = speech?.playing, !model.enabledProviders.contains(provider) {
                speech?.stop()
            }
        }
        .onExitCommand(perform: close)
        .background {
            if let job = model.appleJob {
                Color.clear
                    .frame(width: 0, height: 0)
                    .translationTask(job.appleConfiguration, action: model.appleAction(for: job))
                    .id(job.id)
            }
        }
    }

    private func notice(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: perform) {
                Text(action)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 26)
            }
            .buttonStyle(PanelButtonStyle())
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(card)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("翻译")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            iconButton("pin", label: pinned ? "取消置顶" : "置顶浮窗") {
                pinned.toggle()
                setPinned(pinned)
            }
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .accessibilityAddTraits(pinned ? .isSelected : [])

            iconButton("settings", label: "设置", action: openSettings)
            iconButton("x", label: "关闭", action: close)
        }
        .foregroundStyle(.secondary)
    }

    private func editor(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if model.isLoadingInput {
                    LoadingIndicator(title: "正在识别文字")
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TranslationEditor(text: editorText, inputError: model.inputError) { editorFocused = $0 }
                }
            }
            .font(.system(size: TranslationEditor.fontSize))
            .frame(height: height)

            HStack(spacing: 3) {
                speechButton(.source, text: model.text, language: model.source)
                    .disabled(!hasText)
                iconButton(copiedSource ? "check" : "copy", label: copiedSource ? "已复制" : "复制原文") {
                    Clipboard.write(model.text)
                    copiedSource = true
                }
                .disabled(!hasText)
                iconButton("clipboard-paste", label: "翻译剪贴板", action: pasteAndTranslate)
                    .disabled(model.isLoadingInput)
                Spacer()
                Button(action: translate) {
                    Text("翻译")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .help("翻译（⌘↩）")
                .disabled(!hasText || model.enabledProviders.isEmpty)
            }
        }
        .padding(Self.editorPadding)
        .background(card)
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(editorFocused ? Color.accentColor.opacity(0.5) : .clear)
                .allowsHitTesting(false)
        }
    }

    private var clipboardHint: some View {
        Label {
            Text("剪贴板中没有可翻译的文字")
                .font(.system(size: 13))
        } icon: {
            LucideIcon(name: "lightbulb", size: 13)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func serviceRow(_ provider: Provider, resultHeight: CGFloat) -> some View {
        let output = model.output(for: provider)
        let expanded = !collapsedProviders.contains(provider) && hasText
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded {
                    collapsedProviders.insert(provider)
                    if speech?.playing == .translation(provider) { speech?.stop() }
                } else {
                    collapsedProviders.remove(provider)
                }
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(name: provider == .volcengine ? "flame" : "languages", size: 14)
                        .foregroundStyle(Color.accentColor)
                    Text(provider.title)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    LucideIcon(name: expanded ? "chevron-down" : "chevron-right", size: 13)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle(cornerRadius: 9))
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                Divider().padding(.horizontal, 10)
                serviceOutput(output, for: provider, resultHeight: resultHeight)
            }
        }
        .background(card)
        .onChange(of: output) {
            if copiedResult == provider { copiedResult = nil }
            if speech?.playing == .translation(provider) { speech?.stop() }
        }
    }

    private func serviceOutput(_ output: TranslationOutput, for provider: Provider, resultHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch output {
            case .translating:
                LoadingIndicator(title: "正在翻译")
            case .failed(let error):
                readableOutput(error, maximumHeight: resultHeight)
            case .translated(let text, let language):
                readableOutput(text, maximumHeight: resultHeight)
                let copied = copiedResult == provider
                HStack(spacing: 3) {
                    speechButton(.translation(provider), text: text, language: language)
                    iconButton(copied ? "check" : "copy", label: copied ? "已复制" : "复制译文") {
                        Clipboard.write(text)
                        copiedResult = provider
                    }
                }
            case .idle:
                Text("按 ⌘↩ 翻译").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readableOutput(_ text: String, maximumHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: maximumHeight, alignment: .topLeading)
    }

    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(name: icon, size: 14)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func translate() {
        collapsedProviders.removeAll()
        model.translate()
    }

    private func pasteAndTranslate() {
        let input = Clipboard.text
        guard input.hasNonWhitespace else {
            if !hasText { showEmptyClipboardHint = true }
            focusEditor()
            return
        }
        collapsedProviders.removeAll()
        model.begin(with: input)
    }

    private func speechButton(_ item: SpeechPlayback.Item, text: String, language: Language?) -> some View {
        let playing = speech?.playing == item
        let label = item == .source ? "朗读原文" : "朗读译文"
        return iconButton(playing ? "square" : "volume-2", label: playing ? "停止\(label)" : label) {
            let playback = speech ?? SpeechPlayback()
            speech = playback
            playback.toggle(item, text: text, language: language)
        }
    }
}

private struct TranslationEditor: NSViewRepresentable {
    static let fontSize: CGFloat = 15
    static let minimumHeight: CGFloat = 72
    static let maximumHeight: CGFloat = 176
    private static let linePadding: CGFloat = 5
    private static let verticalInset: CGFloat = 1
    private static let layoutProbeLength = 4_096
    private static let paragraphBreaks = CharacterSet(charactersIn: "\r\n\u{2029}")

    @Binding var text: String
    let inputError: String?
    let onFocusChange: (Bool) -> Void

    static func fittingHeight(for text: String, width: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return minimumHeight }
        let storage = text as NSString
        let viewport = CGSize(width: max(1, width - 2 * linePadding), height: maximumHeight + 2 * fontSize)
        if storage.length > layoutProbeLength {
            // Complete paragraphs let us bound the height without shaping the rest of a long paste.
            let range = NSRange(location: 0, length: layoutProbeLength)
            let paragraph = storage.rangeOfCharacter(from: paragraphBreaks, options: .backwards, range: range)
            if paragraph.location != NSNotFound {
                var end = NSMaxRange(paragraph)
                if storage.character(at: end - 1) == 13, storage.character(at: end) == 10 { end += 1 }
                let prefix = storage.substring(to: end) as NSString
                if measuredHeight(of: prefix, viewport: viewport) >= maximumHeight {
                    return max(minimumHeight, maximumHeight)
                }
            }
        }
        let measured = text.last?.isNewline == true ? (text + " ") as NSString : storage
        return max(minimumHeight, min(maximumHeight, measuredHeight(of: measured, viewport: viewport)))
    }

    private static func measuredHeight(of text: NSString, viewport: CGSize) -> CGFloat {
        let bounds = text.boundingRect(
            with: viewport,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)],
            context: nil
        )
        return ceil(bounds.height) + 2 * verticalInset
    }

    @MainActor
    final class HeightCache {
        private var text: String?
        private var width: CGFloat = 0
        private var intrinsicHeight: CGFloat = minimumHeight

        func height(for text: String, width: CGFloat, maximumHeight: CGFloat) -> CGFloat {
            if self.text != text || self.width != width {
                intrinsicHeight = fittingHeight(for: text, width: width, maximumHeight: TranslationEditor.maximumHeight)
                self.text = text
                self.width = width
            }
            return max(minimumHeight, min(maximumHeight, intrinsicHeight))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = EditorView()
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: Self.minimumHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = Self.linePadding
        editor.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: Self.fontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.setAccessibilityLabel("原文")
        editor.delegate = context.coordinator
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            Task { @MainActor in coordinator?.editor.onFocusChange(focused) }
        }
        editor.onUnmark = { [weak coordinator = context.coordinator, weak editor] in
            Task { @MainActor in
                if let editor { coordinator?.publishCommittedText(from: editor) }
            }
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.editor = self
        guard let editor = scroll.documentView as? EditorView else { return }
        let placeholder = inputError ?? "输入或粘贴文字"
        if editor.placeholder != placeholder {
            editor.placeholder = placeholder
            editor.setAccessibilityHelp(inputError)
        }
        if context.coordinator.committedText != text, !editor.hasMarkedText() {
            editor.string = text
            context.coordinator.committedText = text
            editor.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: TranslationEditor
        var committedText = ""

        init(_ editor: TranslationEditor) { self.editor = editor }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? EditorView else { return }
            view.needsDisplay = true
            publishCommittedText(from: view)
        }

        func publishCommittedText(from view: EditorView) {
            guard !view.isSettingMarkedText, !view.hasMarkedText() else { return }
            let text = view.string
            committedText = text
            if editor.text != text { editor.text = text }
        }
    }

    final class EditorView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?
        var onUnmark: (() -> Void)?
        private(set) var isSettingMarkedText = false
        var placeholder = "" {
            didSet { if oldValue != placeholder { needsDisplay = true } }
        }

        var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? UtilityPanel)?.sourceEditor = self
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            onFocusChange?(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            onFocusChange?(false)
            return true
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            isSettingMarkedText = true
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            isSettingMarkedText = false
            needsDisplay = true
        }

        override func unmarkText() {
            let wasMarked = hasMarkedText()
            super.unmarkText()
            if wasMarked {
                needsDisplay = true
                onUnmark?()
            }
        }

        override func draw(_ dirtyRect: CGRect) {
            super.draw(dirtyRect)
            guard showsPlaceholder, !placeholder.isEmpty else { return }
            let origin = textContainerOrigin
            let leading = origin.x + (textContainer?.lineFragmentPadding ?? 0)
            let rect = CGRect(x: leading, y: origin.y, width: max(0, bounds.width - leading * 2), height: bounds.height - origin.y)
            (placeholder as NSString).draw(with: rect, options: .usesLineFragmentOrigin, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: TranslationEditor.fontSize), .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
    }
}

private struct LoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Group {
                if reduceMotion {
                    dots(highlighted: nil)
                } else {
                    PhaseAnimator(0..<3) { phase in
                        dots(highlighted: phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.24)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }

    private func dots(highlighted: Int?) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 4, height: 4)
                    .opacity(highlighted == nil || highlighted == index ? 1 : 0.25)
            }
        }
    }
}

struct OCRErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(name: "x")
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 9))
    }
}
