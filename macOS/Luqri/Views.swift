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
        didSet {
            initialFirstResponder = sourceEditor
            focusEditorOnOpen()
        }
    }
    private var didFocusEditor = false
    private var focusTask: Task<Void, Never>?
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
        guard isKeyWindow, sourceEditor != nil, !didFocusEditor, focusTask == nil else { return }
        focusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.focusTask = nil
            if self.isKeyWindow { self.didFocusEditor = self.focusSourceEditor() }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let character = event.charactersIgnoringModifiers,
           character == "\r" || character == "\u{3}",
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           let editor = firstResponder as? NSTextView, editor === sourceEditor, !editor.hasMarkedText(),
           let onEditorReturn, event.isARepeat || onEditorReturn() { return }
        super.sendEvent(event)
    }
}

private struct TranslationWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
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
        TranslationPanelLayout {
            panelContent(providers: providers, editorHeight: editorHeight, resultHeight: resultHeight)
        }
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
        .background { AppleTranslationTask(model: model) }
    }

    private func panelContent(providers: [Provider], editorHeight: CGFloat, resultHeight: CGFloat) -> some View {
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
                    let expanded = !collapsedProviders.contains(provider) && hasText
                    TranslationServiceRow(
                        model: model, provider: provider, expanded: expanded,
                        resultWidth: Self.preferredWidth - 2 * (Self.windowPadding + TranslationServiceRow.resultPadding),
                        resultHeight: resultHeight,
                        copiedResult: $copiedResult, speech: $speech
                    ) {
                        if expanded { collapsedProviders.insert(provider) }
                        else { collapsedProviders.remove(provider) }
                    }
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
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .overlay { TranslationWindowDragArea().accessibilityHidden(true) }
            iconButton("pin", label: pinned ? "取消置顶" : "置顶浮窗", selected: pinned) {
                pinned.toggle()
                setPinned(pinned)
            }
            .accessibilityAddTraits(pinned ? .isSelected : [])

            iconButton("settings", label: "设置", action: openSettings)
            iconButton("x", label: "关闭", size: 16, action: close)
        }
        .foregroundStyle(.secondary)
    }

    private func editor(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TranslationEditor(text: editorText, inputError: model.inputError, isLoading: model.isLoadingInput) {
                editorFocused = $0
            }
            .overlay(alignment: .topLeading) {
                if model.isLoadingInput {
                    LoadingSweepLabel(title: "正在识别文字")
                        .padding(.leading, TranslationEditor.placeholderLeading)
                        .padding(.top, TranslationEditor.verticalInset)
                        .allowsHitTesting(false)
                }
            }
            .font(.system(size: TranslationEditor.fontSize))
            .frame(height: height)

            HStack(spacing: 3) {
                SpeechButton(item: .source, text: model.text, language: model.source, speech: $speech)
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
                .help("翻译（Enter）")
                .disabled(model.isLoadingInput || model.enabledProviders.isEmpty)
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

    private func translate() {
        guard hasText else {
            pasteAndTranslate()
            return
        }
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
}

// Keep the editor at the top of the old window frame while AppKit applies the new fitting height.
private struct TranslationPanelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard let height = proposal.height, height.isFinite, height > 0 else { return size }
        return CGSize(width: size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct AppleTranslationTask: View {
    let model: TranslationModel

    var body: some View {
        if let job = model.appleJob {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(job.appleConfiguration, action: model.appleAction(for: job))
                .id(job.id)
        }
    }
}

private struct TranslationServiceRow: View {
    static let resultPadding: CGFloat = 10

    let model: TranslationModel
    let provider: Provider
    let expanded: Bool
    let resultWidth: CGFloat
    let resultHeight: CGFloat
    @Binding var copiedResult: Provider?
    @Binding var speech: SpeechPlayback?
    let toggleExpanded: () -> Void

    var body: some View {
        let output = model.output(for: provider)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpanded()
                if expanded, speech?.playing == .translation(provider) { speech?.stop() }
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
                serviceOutput(output, for: provider)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.055)))
        .onChange(of: output) {
            if copiedResult == provider { copiedResult = nil }
            if speech?.playing == .translation(provider) { speech?.stop() }
        }
    }

    private func serviceOutput(_ output: TranslationOutput, for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch output {
            case .translating:
                LoadingSweepLabel(title: "正在翻译")
            case .failed(let error):
                TranslationResultText(text: error, width: resultWidth, maximumHeight: resultHeight)
            case .translated(let text, let language):
                TranslationResultText(text: text, width: resultWidth, maximumHeight: resultHeight)
                let copied = copiedResult == provider
                HStack(spacing: 3) {
                    SpeechButton(item: .translation(provider), text: text, language: language, speech: $speech)
                    iconButton(copied ? "check" : "copy", label: copied ? "已复制" : "复制译文") {
                        Clipboard.write(text)
                        copiedResult = provider
                    }
                }
            case .idle:
                Text("按 Enter 翻译").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, Self.resultPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranslationResultText: View {
    let text: String
    let width: CGFloat
    let maximumHeight: CGFloat

    var body: some View {
        if text.utf8.count >= 4_096 {
            scrollable
        } else {
            ViewThatFits(in: .vertical) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                scrollable
            }
            .frame(maxHeight: maximumHeight, alignment: .topLeading)
        }
    }

    private var scrollable: some View {
        ScrollableResultText(text: text)
            .frame(width: width, height: maximumHeight)
    }
}

private struct ScrollableResultText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.setAccessibilityLabel("译文")
        scroll.documentView = view
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.text != text, let view = scroll.documentView as? NSTextView else { return }
        view.string = text
        context.coordinator.text = text
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    final class Coordinator {
        var text = ""
    }
}

private struct SpeechButton: View {
    let item: SpeechPlayback.Item
    let text: String
    let language: Language?
    @Binding var speech: SpeechPlayback?

    var body: some View {
        let playing = speech?.playing == item
        let label = item == .source ? "朗读原文" : "朗读译文"
        iconButton(playing ? "square" : "volume-2", label: playing ? "停止\(label)" : label) {
            let playback = speech ?? SpeechPlayback()
            speech = playback
            playback.toggle(item, text: text, language: language)
        }
    }
}

@MainActor
private func iconButton(
    _ icon: String, label: String, selected: Bool = false, size: CGFloat = 14, action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        LucideIcon(name: icon, size: size)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
    .buttonStyle(PanelButtonStyle(prominent: selected))
    .help(label)
    .accessibilityLabel(label)
}

private struct TranslationEditor: NSViewRepresentable {
    static let fontSize: CGFloat = 15
    static let minimumHeight: CGFloat = 72
    static let maximumHeight: CGFloat = 176
    private static let linePadding: CGFloat = 5
    private static let caretSpacing: CGFloat = 3
    static let placeholderLeading = linePadding + caretSpacing
    static let verticalInset: CGFloat = 1
    private static let layoutProbeLength = 4_096
    private static let paragraphBreaks = CharacterSet(charactersIn: "\r\n\u{2029}")

    @Binding var text: String
    let inputError: String?
    let isLoading: Bool
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
        let editor = EditorView(usingTextLayoutManager: true)
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
        let placeholder = isLoading ? "" : (inputError ?? "输入或粘贴文字")
        if editor.placeholder != placeholder {
            editor.placeholder = placeholder
            editor.setAccessibilityHelp(inputError)
        }
        if context.coordinator.committedText != text, !editor.hasMarkedText() {
            let needsPlaceholderUpdate = context.coordinator.committedText.isEmpty != text.isEmpty
            editor.string = text
            context.coordinator.committedText = text
            if needsPlaceholderUpdate { editor.needsDisplay = true }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: TranslationEditor
        var committedText = ""

        init(_ editor: TranslationEditor) { self.editor = editor }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? EditorView else { return }
            publishCommittedText(from: view)
        }

        func publishCommittedText(from view: EditorView) {
            guard !view.isSettingMarkedText, !view.hasMarkedText() else { return }
            let text = view.string
            if committedText.isEmpty != text.isEmpty { view.needsDisplay = true }
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

        var showsPlaceholder: Bool { textStorage?.length == 0 && !hasMarkedText() }

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
            let hadPlaceholder = showsPlaceholder
            isSettingMarkedText = true
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            isSettingMarkedText = false
            if hadPlaceholder != showsPlaceholder { needsDisplay = true }
        }

        override func unmarkText() {
            let wasMarked = hasMarkedText()
            super.unmarkText()
            if wasMarked {
                if showsPlaceholder { needsDisplay = true }
                onUnmark?()
            }
        }

        override func draw(_ dirtyRect: CGRect) {
            super.draw(dirtyRect)
            guard showsPlaceholder, !placeholder.isEmpty else { return }
            let text = NSAttributedString(string: placeholder, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: TranslationEditor.fontSize), .foregroundColor: NSColor.secondaryLabelColor
            ])
            let origin = textContainerOrigin
            let leading = origin.x + TranslationEditor.placeholderLeading
            let rect = CGRect(x: leading, y: origin.y, width: max(0, bounds.width - leading - origin.x),
                              height: bounds.height - origin.y)
            text.draw(with: rect, options: .usesLineFragmentOrigin)
        }
    }
}

private struct LoadingSweepLabel: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        Text(title)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .overlay {
                if !reduceMotion {
                    Text(title)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 0.8)
                        .mask {
                            GeometryReader { proxy in
                                let width = proxy.size.width
                                let band = width / 2
                                LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: band)
                                    .offset(x: sweeping ? width : -band)
                            }
                        }
                        .onAppear {
                            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                                sweeping = true
                            }
                        }
                        .onDisappear { sweeping = false }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}
