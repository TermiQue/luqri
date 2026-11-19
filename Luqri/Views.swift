import AppKit
import AVFoundation
import NaturalLanguage
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.charactersIgnoringModifiers == "\r",
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           let editor = firstResponder as? NSTextView, !editor.hasMarkedText(),
           let onEditorReturn, event.isARepeat || onEditorReturn() { return }
        super.sendEvent(event)
    }
}

enum MissingInput {
    case selection, clipboard

    var message: String {
        switch self {
        case .selection: "划词翻译没有获取到文字"
        case .clipboard: "剪贴板中没有可翻译的文字"
        }
    }
}

struct TranslationView: View {
    @FocusState private var editorFocused: Bool
    @State private var pinned = false
    @State private var collapsedProviders = Set<Provider>()
    @State private var showingHelp = false
    @State private var copiedSource = false
    @State private var copiedResult: Provider?
    @State private var speaker: AVSpeechSynthesizer?
    @State var missingInput: MissingInput?

    @Bindable var model: TranslationModel
    let startsEditing: Bool
    let close: () -> Void
    let openSettings: () -> Void
    let setPinned: (Bool) -> Void
    let resize: (CGSize) -> Void

    private var hasText: Bool {
        !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var editorText: Binding<String> {
        Binding(get: { model.text }, set: { model.edit($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            editor
            languages
            if !hasText, let missingInput {
                inputHint(missingInput)
            }
            if model.enabledProviders.isEmpty {
                HStack {
                    Text("请先开启翻译服务").foregroundStyle(.secondary)
                    Spacer()
                    Button("打开设置", action: openSettings)
                        .controlSize(.small)
                }
                .font(.system(size: 13))
                .padding(10)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(model.enabledProviders) { provider in
                    serviceRow(provider)
                }
            }
        }
        .padding(10)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .onGeometryChange(for: CGSize.self, of: \.size, action: resize)
        .onAppear { editorFocused = startsEditing }
        .onDisappear { speaker?.stopSpeaking(at: .immediate) }
        .onChange(of: model.text) {
            copiedSource = false
            if hasText { missingInput = nil }
            speaker?.stopSpeaking(at: .immediate)
        }
        .onChange(of: model.isTranslating) {
            if model.isTranslating { collapsedProviders.removeAll() }
        }
        .onChange(of: model.enabledProviders) {
            collapsedProviders.formIntersection(model.enabledProviders)
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

    private var header: some View {
        HStack(spacing: 4) {
            iconButton("pin", label: pinned ? "取消置顶" : "置顶浮窗") {
                pinned.toggle()
                setPinned(pinned)
            }
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .accessibilityAddTraits(pinned ? .isSelected : [])

            Text("翻译")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            iconButton("settings-2", label: "设置", action: openSettings)
            iconButton("x", label: "关闭", action: close)
        }
        .foregroundStyle(.secondary)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("输入或粘贴文字")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: editorText)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("原文")
            }
            .font(.system(size: 14))
            .frame(height: 52)

            HStack(spacing: 1) {
                iconButton("volume-2", label: "朗读原文", action: speak)
                    .disabled(!hasText)
                iconButton(copiedSource ? "check" : "copy", label: copiedSource ? "已复制" : "复制原文") {
                    Clipboard.write(model.text)
                    copiedSource = true
                }
                .disabled(!hasText)
                iconButton("clipboard-paste", label: "翻译剪贴板", action: pasteAndTranslate)
                Spacer()
                Button("翻译", action: translate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("翻译（⌘↩）")
                    .disabled(!hasText || model.enabledProviders.isEmpty)
            }
            .padding(.horizontal, 2)
        }
        .padding(7)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(editorFocused ? Color.accentColor.opacity(0.5) : .clear)
                .allowsHitTesting(false)
        }
    }

    private var languages: some View {
        HStack(spacing: 8) {
            languagePicker("原文语言", automatic: "自动检测", selection: $model.source)
            iconButton("arrow-left-right", label: "交换语向") {
                let source = model.source
                model.source = model.target
                model.target = source
            }
            .disabled(model.source == model.target)
            languagePicker("译文语言", automatic: "自动选择", selection: $model.target)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func languagePicker(_ title: String, automatic: String, selection: Binding<Language?>) -> some View {
        Picker(title, selection: selection) {
            Text(automatic).tag(nil as Language?)
            ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }

    private func inputHint(_ issue: MissingInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("提示").font(.caption.weight(.semibold))
            } icon: {
                LucideIcon(name: "lightbulb", size: 13)
            }
            .foregroundStyle(.secondary)
            Text(issue.message)
                .font(.system(size: 13))
            if issue == .selection {
                if showingHelp {
                    Text("检查 Luqri 的辅助功能权限，或先复制文字，再使用「翻译剪贴板」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开辅助功能设置") { Permissions.openAccessibility() }
                        .controlSize(.small)
                } else {
                    Button("如何解决") { showingHelp = true }
                        .controlSize(.small)
                }
            } else {
                Text("复制一段文字，或直接在上方输入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func serviceRow(_ provider: Provider) -> some View {
        let output = model.output(for: provider)
        let expanded = !collapsedProviders.contains(provider) && hasText
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded {
                    collapsedProviders.insert(provider)
                } else {
                    collapsedProviders.remove(provider)
                }
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(name: provider == .apple ? "languages" : "flame", size: 14)
                        .foregroundStyle(Color.accentColor)
                    Text(provider.title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    LucideIcon(name: expanded ? "chevron-down" : "chevron-right", size: 13)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                Divider().padding(.horizontal, 10)
                serviceOutput(output, for: provider)
            }
        }
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: output) {
            if copiedResult == provider { copiedResult = nil }
        }
    }

    private func serviceOutput(_ output: TranslationOutput, for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch output {
            case .translating:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…").foregroundStyle(.secondary)
                }
            case .failed(let error):
                readableOutput(error)
            case .translated(let text):
                readableOutput(text)
                let copied = copiedResult == provider
                iconButton(copied ? "check" : "copy", label: copied ? "已复制" : "复制译文") {
                    Clipboard.write(text)
                    copiedResult = provider
                }
            case .idle:
                Text("按 ⌘↩ 翻译").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readableOutput(_ text: String) -> some View {
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
        .frame(maxHeight: model.enabledProviders.count > 1 ? 110 : 146, alignment: .topLeading)
    }

    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(name: icon, size: 14)
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func translate() {
        collapsedProviders.removeAll()
        model.translate()
    }

    private func pasteAndTranslate() {
        let input = Clipboard.text
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !hasText { missingInput = .clipboard }
            editorFocused = true
            return
        }
        collapsedProviders.removeAll()
        model.begin(with: input)
    }

    private func speak() {
        let synthesizer = speaker ?? AVSpeechSynthesizer()
        speaker = synthesizer
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        let utterance = AVSpeechUtterance(string: model.text)
        let language = model.source?.rawValue ?? NLLanguageRecognizer.dominantLanguage(for: String(model.text.prefix(512)))?.rawValue
        if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        synthesizer.speak(utterance)
    }
}

struct SettingsView: View {
    static let preferredSize = CGSize(width: 466, height: 590)

    @Bindable var model: TranslationModel
    let shortcuts: GlobalShortcuts
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var status = ""
    @State private var hasCredentials = false

    var body: some View {
        Form {
            Section("翻译") {
                Picker("译文语言", selection: $model.target) {
                    Text("自动选择").tag(nil as Language?)
                    ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
                }
                if model.target == nil {
                    Text("自动选择会将中文译为英语，其它语言译为简体中文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("翻译服务") {
                ForEach(Provider.allCases) { provider in
                    Toggle(provider.title, isOn: Binding(
                        get: { model.enabledProviders.contains(provider) },
                        set: { model.setEnabled($0, for: provider) }
                    ))
                }
            }

            Section("火山引擎") {
                credentialField("Access Key ID", text: $accessKey)
                credentialField("Secret Access Key", text: $secretKey)
                HStack {
                    Text(status.isEmpty ? "密钥仅保存在本机" : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasCredentials {
                        Button("移除密钥", role: .destructive, action: removeCredentials)
                    }
                    Button("保存密钥", action: saveCredentials)
                        .disabled(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link("开通与计费", destination: URL(string: "https://docs.volcengine.com/docs/machine-translation/product-billing")!)
            }

            Section("快捷键") {
                ForEach(Command.allCases, id: \.self) { command in
                    LabeledContent(command.title) {
                        if shortcuts.failed.contains(command) {
                            Text("不可用").foregroundStyle(.secondary)
                        }
                        Button(shortcuts.recording == command ? "请按键…" : shortcuts.binding(for: command).label) {
                            shortcuts.beginRecording(command, in: NSApp.keyWindow)
                        }
                        .monospaced()
                        .accessibilityHint("点击录制快捷键，按 Esc 取消")
                    }
                }
                HStack {
                    Text(shortcuts.message ?? (shortcuts.recording == nil ? "点击快捷键按钮修改" : "按 Esc 取消录制"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                    Button("恢复默认") { shortcuts.restoreDefaults() }
                }
            }

            Section("系统权限") {
                LabeledContent("读取选中文字") {
                    Button("辅助功能设置") { Permissions.openAccessibility() }
                }
                LabeledContent("截图识别与翻译") {
                    Button("屏幕录制设置") { Permissions.openScreenCapture() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            do {
                let credentials = try CloudCredentials.load()
                hasCredentials = credentials != nil
                accessKey = credentials?.accessKey ?? ""
                secretKey = credentials?.secretKey ?? ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func credentialField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 7) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                    .accessibilityLabel(title)
                Button {
                    guard let pasted = Clipboard.credentialText() else {
                        status = "剪贴板中没有可粘贴的文字。"
                        return
                    }
                    text.wrappedValue = pasted
                    status = ""
                } label: {
                    LucideIcon(name: "clipboard-paste", size: 13)
                }
                .buttonStyle(.borderless)
                .help("粘贴 \(title)")
                .accessibilityLabel("粘贴 \(title)")
            }
        }
    }

    private func saveCredentials() {
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !secret.isEmpty else { return }
        do {
            try CloudCredentials(accessKey: access, secretKey: secret).save()
            accessKey = access
            secretKey = secret
            hasCredentials = true
            status = "密钥已保存在本机。"
        } catch {
            status = error.localizedDescription
        }
    }

    private func removeCredentials() {
        do {
            try CloudCredentials.remove()
            accessKey = ""
            secretKey = ""
            hasCredentials = false
            status = "密钥已移除。"
        } catch {
            status = error.localizedDescription
        }
    }
}

struct FeedbackView: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(name: icon)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}
