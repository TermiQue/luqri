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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
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
    @State private var collapsed = false
    @State private var showingHelp = false
    @State private var copiedSource = false
    @State private var copiedResult = false
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
            ForEach(Provider.allCases) { provider in
                serviceRow(provider)
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
        .onChange(of: model.result) { copiedResult = false }
        .onChange(of: model.provider) { collapsed = false }
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
                    .disabled(!hasText)
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
                    Text("检查 Luqri 的辅助功能权限，或先复制文字，再点击输入框下方的剪贴板按钮。")
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
        let selected = model.provider == provider
        let expanded = selected && !collapsed && hasText
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if selected {
                    collapsed.toggle()
                } else {
                    collapsed = false
                    model.provider = provider
                }
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(name: provider == .apple ? "languages" : "flame", size: 14)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(provider.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
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
                serviceOutput
            }
        }
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var serviceOutput: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isTranslating {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…").foregroundStyle(.secondary)
                }
            } else if let error = model.error {
                readableOutput(error)
            } else if !model.result.isEmpty {
                readableOutput(model.result)
                iconButton(copiedResult ? "check" : "copy", label: copiedResult ? "已复制" : "复制译文") {
                    Clipboard.write(model.result)
                    copiedResult = true
                }
            } else {
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
        .frame(maxHeight: 146, alignment: .topLeading)
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
        collapsed = false
        model.translate()
    }

    private func pasteAndTranslate() {
        let input = Clipboard.text
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !hasText { missingInput = .clipboard }
            editorFocused = true
            return
        }
        collapsed = false
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
    @Bindable var model: TranslationModel
    let failedShortcuts: Set<Command>
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var status = ""
    @State private var hasCredentials = false

    var body: some View {
        Form {
            Section("翻译") {
                Picker("默认服务", selection: $model.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("自动选择译文语言", value: "中文 → 英语，其它 → 简体中文")
            }

            Section("火山引擎") {
                TextField("Access Key ID", text: $accessKey)
                SecureField("Secret Access Key", text: $secretKey)
                HStack {
                    Text(status.isEmpty ? "密钥保存在 macOS 钥匙串" : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasCredentials {
                        Button("移除密钥", role: .destructive, action: removeCredentials)
                    }
                    Button("保存密钥", action: saveCredentials)
                        .disabled(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link("开通与计费", destination: URL(string: "https://docs.volcengine.com/docs/machine-translation/product-billing")!)
            }

            Section("快捷键") {
                ForEach(Command.allCases, id: \.self) { command in
                    LabeledContent(command.title) {
                        Text(command.shortcut + (failedShortcuts.contains(command) ? " · 注册失败" : ""))
                            .monospaced()
                    }
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
        .frame(width: 466, height: 590)
        .onAppear {
            do {
                let credentials = try CloudCredentials.load()
                hasCredentials = credentials != nil
                accessKey = credentials?.accessKey ?? ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func saveCredentials() {
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !secret.isEmpty else {
                if let existing = try CloudCredentials.load(), existing.accessKey == access {
                    status = "密钥已保存。"
                } else {
                    status = "请输入 Secret Access Key。"
                }
                return
            }
            try CloudCredentials(accessKey: access, secretKey: secret).save()
            secretKey = ""
            hasCredentials = true
            status = "密钥已保存。"
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
