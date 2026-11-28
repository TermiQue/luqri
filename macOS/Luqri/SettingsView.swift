import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class SettingsPermissions {
    var granted = Set<AppPermission>()
}

struct SettingsView: View {
    static let preferredSize = CGSize(width: 466, height: 590)

    @Bindable var model: TranslationModel
    let shortcuts: GlobalShortcuts
    let credentialsChanged: (CloudAccount) -> Void
    let ocrChanged: (OCRProvider) -> Void
    let permissions: SettingsPermissions
    let refreshPermissions: () -> Void
    let requestPermission: (AppPermission) -> Void
    let readUsage: (CloudMeter, Bool) async throws -> (used: Decimal, note: String?)
    @AppStorage(OCRProvider.preferenceKey) private var ocrProvider = OCRProvider.appleVision
    @State private var account = CloudAccount.volcengine
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var drafts: [CloudAccount: CloudCredentials] = [:]
    @State private var status = ""
    @State private var hasCredentials = false
    @State private var usageVersions: [CloudAccount: Int] = [:]
    @State private var usage = SettingsUsage()

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
                    let title = provider == .apple ? "Apple" : provider.title
                    let enabled = model.enabledProviders.contains(provider)
                    LabeledContent {
                        HStack(spacing: 11) {
                            if enabled, let meter = provider.meter { usageRing(meter) }
                            Toggle(title, isOn: Binding(
                                get: { model.enabledProviders.contains(provider) },
                                set: { model.setEnabled($0, for: provider) }
                            ))
                            .labelsHidden()
                        }
                        .frame(minHeight: provider.meter == nil ? nil : 22)
                    } label: {
                        HStack(spacing: 10) {
                            Text(title)
                            if let meter = provider.meter { serviceLinks(meter) }
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
                        if let meter = ocrProvider.meter { serviceLinks(meter) }
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
                    let granted = permissions.granted.contains(permission)
                    LabeledContent(permission.title) {
                        Text(granted ? "已授权" : "未授权")
                            .foregroundStyle(.secondary)
                        Button(granted ? "管理…" : "授权…") {
                            if granted { permission.openSettings() }
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
        .onChange(of: ocrProvider) { _, provider in ocrChanged(provider) }
        .onChange(of: account) { previous, _ in
            drafts[previous] = CloudCredentials(accessKey: accessKey, secretKey: secretKey)
            loadCredentials()
        }
    }

    private func usageRing(_ meter: CloudMeter) -> some View {
        CloudUsageRing(meter: meter, usage: usage, readUsage: readUsage)
            .id(UsageIdentity(meter: meter, version: usageVersions[meter.account, default: 0]))
    }

    private struct UsageIdentity: Hashable {
        let meter: CloudMeter
        let version: Int
    }

    private func serviceLinks(_ meter: CloudMeter) -> some View {
        let destinations: (activation: String, billing: String) = switch meter {
        case .volcengineTranslation: (
            "https://console.volcengine.com/translate",
            "https://docs.volcengine.com/docs/machine-translation/product-billing?lang=zh"
        )
        case .aliyunTranslation: (
            "https://mt.console.aliyun.com/service",
            "https://help.aliyun.com/zh/machine-translation/product-overview/pricing-of-machine-translation-general-purpose-edition"
        )
        case .volcengineOCR: (
            "https://console.volcengine.com/ai/ability/info/78",
            "https://docs.volcengine.com/docs/large-model-of-image-generation/ability-to-introduce-1?lang=zh"
        )
        case .aliyunOCR: (
            "https://ocr.console.aliyun.com/overview",
            "https://help.aliyun.com/zh/ocr/product-overview/pay-as-you-go"
        )
        }

        return HStack(spacing: 8) {
            serviceLink("开通", destination: destinations.activation, service: meter.title)
            serviceLink("计费", destination: destinations.billing, service: meter.title)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func serviceLink(_ title: String, destination: String, service: String) -> some View {
        Link(destination: URL(string: destination)!) {
            Text(title)
                .font(.caption)
                .underline()
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(service)\(title)")
    }

    private func credentialField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 7) {
                SecureField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
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
            usage.invalidate(account)
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
            usage.invalidate(account)
            usageVersions[account, default: 0] += 1
            credentialsChanged(account)
        } catch {
            status = error.localizedDescription
        }
    }
}

@MainActor
@Observable
private final class SettingsUsage {
    typealias Read = (CloudMeter, Bool) async throws -> (used: Decimal, note: String?)

    struct Entry {
        var cached: CloudUsageSnapshot?
        var live: Decimal?
        var note: String?
        var querying = false
    }

    private(set) var entries: [CloudMeter: Entry] = [:]
    private var attempted: Set<CloudMeter> = []
    @ObservationIgnored private var tasks: [CloudMeter: Task<Void, Never>] = [:]

    deinit {
        for task in tasks.values { task.cancel() }
    }

    func show(_ meter: CloudMeter, read: @escaping Read) {
        guard entries[meter] == nil else { return }
        if let credentials = try? meter.account.load() {
            let cached = try? meter.cachedUsage(credentials)
            entries[meter] = Entry(cached: cached)
            if cached?.needsRefresh(at: .now) != false {
                start(meter, force: false, read: read)
            }
        } else {
            entries[meter] = Entry(note: "请在设置中填写\(meter.account.title)访问密钥。")
        }
    }

    func request(_ meter: CloudMeter, read: @escaping Read) {
        guard !attempted.contains(meter) else { return }
        do {
            let credentials = try meter.account.load()
            if entries[meter] == nil {
                entries[meter] = Entry(cached: try? meter.cachedUsage(credentials))
            }
        } catch {
            entries[meter, default: Entry()].note = error.localizedDescription
            return
        }
        start(meter, force: true, read: read)
    }

    private func start(_ meter: CloudMeter, force: Bool, read: @escaping Read) {
        guard attempted.insert(meter).inserted else { return }
        entries[meter, default: Entry()].querying = true
        entries[meter]?.note = nil
        tasks[meter] = Task { [weak self] in
            do {
                let result = try await read(meter, force)
                try Task.checkCancellation()
                if result.note == nil {
                    self?.entries[meter]?.live = result.used
                } else {
                    self?.entries[meter]?.cached = CloudUsageSnapshot(used: result.used, checkedAt: nil)
                }
                self?.entries[meter]?.note = result.note
            } catch {
                guard !Task.isCancelled else { return }
                self?.entries[meter]?.note = error.localizedDescription
            }
            self?.entries[meter]?.querying = false
            self?.tasks[meter] = nil
        }
    }

    func invalidate(_ account: CloudAccount) {
        for meter in entries.keys.filter({ $0.account == account }) {
            tasks.removeValue(forKey: meter)?.cancel()
            entries[meter] = nil
        }
    }
}

private struct CloudUsageRing: View {
    private static let hoverWidth: CGFloat = 22

    let meter: CloudMeter
    let usage: SettingsUsage
    let readUsage: SettingsUsage.Read
    @State private var hovered = false

    var body: some View {
        let entry = usage.entries[meter]
        let used = entry?.live ?? (hovered ? nil : entry?.cached?.used)
        let status = entry?.querying == true ? "正在查询用量…" : entry?.note
        let detail = [used.map(meter.detail), status].compactMap { $0 }.joined(separator: "\n")
        Button {
            usage.request(meter, read: readUsage)
        } label: {
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
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hovered = hovering
            if hovering { usage.request(meter, read: readUsage) }
        }
        .overlay(alignment: .trailing) {
            if hovered {
                Text(detail.isEmpty ? "悬停或按下以查询用量。" : detail)
                    .font(.caption)
                    .lineLimit(4)
                    .frame(maxWidth: 240, alignment: .leading)
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
        .onAppear { usage.show(meter, read: readUsage) }
    }
}
