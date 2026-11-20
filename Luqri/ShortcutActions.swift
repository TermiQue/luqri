import AppIntents
import AppKit

struct TranslateSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "划词翻译"
    static let description = IntentDescription("在 Luqri 浮窗翻译提供的文字或当前应用选中的文字。")

    @Parameter(title: "原文")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("翻译 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runLuqriShortcut(.translate, text: text)
        return .result()
    }
}

struct RecognizeScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "OCR 识别"
    static let description = IntentDescription("框选屏幕区域，识别文字并复制到剪贴板。")
    static let openAppWhenRun = true

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runLuqriShortcut(.recognize)
        return .result()
    }
}

struct TranslateScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "OCR 翻译"
    static let description = IntentDescription("框选屏幕区域，在 Luqri 浮窗识别并翻译文字。")
    static let openAppWhenRun = true

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runLuqriShortcut(.screenshotTranslate)
        return .result()
    }
}

@MainActor
private func runLuqriShortcut(_ command: Command, text: String? = nil) async throws {
    guard let controller = NSApp?.delegate as? AppController else { throw ShortcutActionError.appUnavailable }
    try Task.checkCancellation()
    await controller.runShortcut(command, text: text)
    try Task.checkCancellation()
}

private enum ShortcutActionError: LocalizedError {
    case appUnavailable

    var errorDescription: String? { "无法启动 Luqri，请打开应用后重试。" }
}
