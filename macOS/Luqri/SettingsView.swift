import AppKit
import SwiftUI

struct SettingsView: View {
    static let preferredSize = CGSize(width: 466, height: 590)

    @Bindable var model: TranslationModel
    let shortcuts: GlobalShortcuts
    let credentialsChanged: (CloudAccount) -> Void
    let requestPermission: (AppPermission) -> Void
    @AppStorage(OCRProvider.preferenceKey) private var ocrProvider = OCRProvider.appleVision
    @State private var account = CloudAccount.volcengine
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var drafts: [CloudAccount: CloudCredentials] = [:]
    @State private var status = ""
    @State private var hasCredentials = false
    @State private var grantedPermissions: Set<AppPermission> = []
    @State private var usageVersions: [CloudAccount: Int] = [:]

    var body: some View {
        Form {
            Section("翻译服务") {
                Picker("原文语言", selection: $model.source) {
                    Text("自动检测").tag(nil as Language?)
                    ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Picker("译文语言", selection: $model.target) {
                    Text("自动选择").tag(nil as Language?)
                    ForEach(Language.allCases) { Text($0.title).tag(Optional($0)) }
                }
                ForEach(Provider.allCases) { provider in
                    let enabled = model.enabledProviders.contains(provider)
                    LabeledContent {
                        HStack(spacing: 11) {
                            if enabled, let meter = provider.meter { usageRing(meter) }
                            Toggle(provider.title, isOn: Binding(
                                get: { model.enabledProviders.contains(provider) },
                                set: { model.setEnabled($0, for: provider) }
                            ))
                            .labelsHidden()
                        }
                        .frame(minHeight: provider.meter == nil ? nil : 22)
                    } label: {
                        HStack(spacing: 10) {
                            Text(provider.title)
                            if enabled, let meter = provider.meter { billingLink(meter) }
                        }
                    }
                }
            }

            Section("OCR 服务") {
                LabeledContent {
                    HStack(spacing: 6) {
                        if let meter = ocrProvider.meter { usageRing(meter) }
                        Picker("识别服务", selection: $ocrProvider) {
                            ForEach(OCRProvider.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("识别服务")
                        if let meter = ocrProvider.meter { billingLink(meter) }
                    }
                }
            }

            Section("访问密钥") {
                Picker("服务商", selection: $account) {
                    ForEach(CloudAccount.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                credentialField("Access Key ID", text: $accessKey)
                credentialField(account == .aliyun ? "AccessKey Secret" : "Secret Access Key", text: $secretKey)
                HStack {
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasCredentials {
                        Button("移除密钥", role: .destructive, action: removeCredentials)
                    }
                    Button("保存密钥", action: saveCredentials)
                        .disabled(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
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
                    if let message = shortcuts.message ?? (shortcuts.recording == nil ? nil : "按 Esc 取消录制") {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Spacer()
                    Button("恢复默认") { shortcuts.restoreDefaults() }
                }
            }

            Section("系统权限") {
                ForEach(AppPermission.allCases, id: \.self) { permission in
                    let granted = grantedPermissions.contains(permission)
                    LabeledContent(permission.title) {
                        Text(granted ? "已授权" : "未授权")
                            .foregroundStyle(.secondary)
                        Button(granted ? "管理…" : "授权…") {
                            if permission.isGranted { permission.openSettings() }
                            else { requestPermission(permission) }
                        }
                            .accessibilityLabel("\(granted ? "管理" : "授权")\(permission.title)")
                    }
                    .help(permission.purpose)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onAppear {
            refreshPermissions()
            loadCredentials()
        }
        .onChange(of: account) { previous, _ in
            drafts[previous] = CloudCredentials(accessKey: accessKey, secretKey: secretKey)
            loadCredentials()
        }
    }

    private func refreshPermissions() {
        grantedPermissions = Set(AppPermission.allCases.filter(\.isGranted))
    }

    private func usageRing(_ meter: CloudMeter) -> some View {
        CloudUsageRing(meter: meter)
            .id(UsageIdentity(meter: meter, version: usageVersions[meter.account, default: 0]))
    }

    private struct UsageIdentity: Hashable {
        let meter: CloudMeter
        let version: Int
    }

    private func billingLink(_ meter: CloudMeter) -> some View {
        let destination = switch meter {
        case .volcengineTranslation: "https://docs.volcengine.com/docs/machine-translation/product-billing"
        case .aliyunTranslation: "https://help.aliyun.com/zh/machine-translation/product-overview/pricing-of-machine-translation-general-purpose-edition"
        case .volcengineOCR: "https://docs.volcengine.com/docs/large-model-of-image-generation/ability-to-introduce-1"
        case .aliyunOCR: "https://ocr.console.aliyun.com/overview"
        }
        return Link(destination: URL(string: destination)!) {
            Text(meter == .aliyunOCR ? "开通服务" : "开通与计费")
                .font(.caption)
                .underline()
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(meter.account.title)服务开通")
    }

    private func credentialField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 7) {
                SecureField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 130)
                    .accessibilityLabel(title)
                Button {
                    status = Clipboard.writeCredential(text.wrappedValue) ? "已复制密钥。" : "无法写入剪贴板，请重试。"
                } label: {
                    LucideIcon(name: "copy", size: 13)
                }
                .buttonStyle(.borderless)
                .help("复制 \(title)")
                .accessibilityLabel("复制 \(title)")
                .disabled(!text.wrappedValue.hasNonWhitespace)
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

    private func loadCredentials() {
        status = ""
        do {
            let saved = try CloudCredentials.load(from: account.file)
            let fields = drafts[account] ?? saved
            hasCredentials = saved != nil
            accessKey = fields?.accessKey ?? ""
            secretKey = fields?.secretKey ?? ""
        } catch {
            accessKey = ""
            secretKey = ""
            hasCredentials = true
            status = "无法读取密钥。\(error.localizedDescription)"
        }
    }

    private func saveCredentials() {
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !secret.isEmpty else { return }
        do {
            try CloudCredentials(accessKey: access, secretKey: secret).save(to: account.file)
            accessKey = access
            secretKey = secret
            hasCredentials = true
            status = "密钥已保存在本机。"
            drafts[account] = nil
            usageVersions[account, default: 0] += 1
            credentialsChanged(account)
        } catch {
            status = error.localizedDescription
        }
    }

    private func removeCredentials() {
        do {
            try CloudCredentials.remove(from: account.file)
            accessKey = ""
            secretKey = ""
            hasCredentials = false
            status = "密钥已移除。"
            drafts[account] = nil
            usageVersions[account, default: 0] += 1
            credentialsChanged(account)
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct CloudUsageRing: View {
    private static let hoverWidth: CGFloat = 22

    let meter: CloudMeter
    @State private var used: Decimal?
    @State private var detail = "正在查询用量…"
    @State private var loading = true
    @State private var hovered = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 3.5)
            if let used {
                let fraction = NSDecimalNumber(decimal: used / meter.limit).doubleValue
                Circle()
                    .inset(by: 1.75)
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: Self.hoverWidth, height: 22)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .overlay(alignment: .trailing) {
            if hovered {
                Group {
                    if loading {
                        UsageLoadingDots()
                    } else {
                        Text(detail)
                            .font(.caption)
                            .lineLimit(4)
                            .frame(maxWidth: 240, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .fixedSize()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                .offset(x: -(Self.hoverWidth + 6))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .zIndex(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.title)
        .accessibilityValue(detail)
        .task { await refresh() }
    }

    private func refresh() async {
        defer { loading = false }
        do {
            let credentials = try meter.account.load()
            let usage = try await meter.read(credentials)
            try Task.checkCancellation()
            used = usage.used
            detail = [meter.detail(usage.used), usage.note].compactMap { $0 }.joined(separator: "\n")
        } catch {
            guard !Task.isCancelled else { return }
            detail = error.localizedDescription
        }
    }
}

private struct UsageLoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: reduceMotion)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(.secondary)
                        .frame(width: 4, height: 4)
                        .opacity(reduceMotion || index == phase ? 1 : 0.35)
                }
            }
        }
    }
}
