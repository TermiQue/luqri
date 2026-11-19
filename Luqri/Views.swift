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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct TranslationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editorFocused: Bool
    @State private var copied = false

    @Bindable var model: TranslationModel
    let startsEditing: Bool
    let close: () -> Void
    let openSettings: () -> Void

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.46, green: 0.86, blue: 0.77)
            : Color(red: 0.12, green: 0.40, blue: 0.35)
    }

    private var editorText: Binding<String> {
        Binding(get: { model.text }, set: { model.edit($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            languages
            editor
            result
            footer
        }
        .padding(16)
        .frame(width: 436)
        .background(.regularMaterial)
        .tint(accent)
        .onAppear { editorFocused = startsEditing }
        .onChange(of: model.result) { copied = false }
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
        HStack(spacing: 9) {
            LucideIcon(name: "languages", size: 19)
                .foregroundStyle(accent)
            Text("翻译")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: openSettings) {
                LucideIcon(name: "settings-2")
            }
            .help("设置")
            .accessibilityLabel("设置")
            Button(action: close) {
                LucideIcon(name: "x")
            }
            .help("关闭（Esc）")
            .accessibilityLabel("关闭")
        }
        .buttonStyle(.borderless)
    }

    private var languages: some View {
        HStack(spacing: 8) {
            Picker("原文语言", selection: $model.source) {
                Text("检测语言").tag(nil as Language?)
                ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .accessibilityLabel("原文语言")
            LucideIcon(name: "arrow-right", size: 13)
                .foregroundStyle(.secondary)
            Picker("译文语言", selection: $model.target) {
                Text("自动选择").tag(nil as Language?)
                ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .accessibilityLabel("译文语言")
            Spacer(minLength: 5)
            Button {
                model.begin(with: Clipboard.text)
                if model.text.isEmpty { editorFocused = true }
            } label: {
                LucideIcon(name: "clipboard-paste")
            }
            .buttonStyle(.borderless)
            .help("翻译剪贴板")
            .accessibilityLabel("翻译剪贴板")
        }
        .labelsHidden()
        .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("输入或粘贴要翻译的文字")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: editorText)
                .focused($editorFocused)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .accessibilityLabel("原文")
        }
        .font(.system(size: 14))
        .frame(height: 103)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(editorFocused ? accent.opacity(0.6) : .primary.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("译文").font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                if !model.result.isEmpty {
                    Button {
                        Clipboard.write(model.result)
                        copied = true
                    } label: {
                        LucideIcon(name: copied ? "check" : "copy", size: 14)
                    }
                    .buttonStyle(.borderless)
                    .help(copied ? "已复制" : "复制译文")
                    .accessibilityLabel(copied ? "已复制" : "复制译文")
                }
            }
            Group {
                if let error = model.error {
                    ScrollView {
                        Text(error)
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if model.isTranslating {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在翻译…").foregroundStyle(.secondary)
                    }
                } else if !model.result.isEmpty {
                    ScrollView {
                        Text(model.result)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("译文将在这里显示").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(height: 112)
        .background(accent.opacity(colorScheme == .dark ? 0.10 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 2)
                .padding(.vertical, 9)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack {
            Picker("翻译服务", selection: $model.provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("翻译服务")
            .fixedSize()
            Spacer()
            Text("⌘↩").font(.caption.monospaced()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button("翻译") { model.translate() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.regular)
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
