import Foundation
import NaturalLanguage
import Observation
import Translation

enum Provider: String, CaseIterable, Identifiable {
    case apple, volcengine, aliyun

    var id: Self { self }
    var meter: CloudMeter? {
        switch self {
        case .apple: nil
        case .volcengine: .volcengineTranslation
        case .aliyun: .aliyunTranslation
        }
    }

    var title: String {
        switch self {
        case .apple: "Apple 翻译"
        case .volcengine: "火山引擎"
        case .aliyun: "阿里云"
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"

    var id: Self { self }

    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        case .french: "法语"
        case .german: "德语"
        case .spanish: "西班牙语"
        case .italian: "意大利语"
        case .portuguese: "葡萄牙语"
        case .russian: "俄语"
        case .arabic: "阿拉伯语"
        }
    }

    var locale: Locale.Language { Locale.Language(identifier: rawValue) }

    var cloudCode: String { self == .simplifiedChinese ? "zh" : rawValue }

    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
}

struct TranslationJob: Sendable {
    let id = UUID()
    let text: String
    let provider: Provider
    let source: Language?
    let target: Language

    var appleConfiguration: TranslationSession.Configuration {
        .init(source: source?.locale, target: target.locale)
    }
}

enum TranslationOutput: Equatable {
    case idle, translating, translated(String, language: Language), failed(String)
}

@MainActor
@Observable
final class TranslationModel {
    private enum InputStatus: Equatable {
        case idle, loading, failed(String)
    }

    private let defaults: UserDefaults

    private(set) var text = ""
    private(set) var hasText = false
    var source: Language? {
        didSet { if source != oldValue { changeLanguages() } }
    }
    var target: Language? {
        didSet { if target != oldValue { changeLanguages() } }
    }

    private var selectedProviders: Set<Provider>
    private var outputs: [Provider: TranslationOutput] = [:]
    private var activeJobs: [Provider: TranslationJob] = [:]
    private var inputStatus = InputStatus.idle
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var cloudTasks: [Provider: Task<Void, Never>] = [:]

    var enabledProviders: [Provider] { Provider.allCases.filter(selectedProviders.contains) }
    var isLoadingInput: Bool { inputStatus == .loading }
    var inputError: String? {
        if case .failed(let message) = inputStatus { return message }
        return nil
    }
    var isTranslating: Bool { !activeJobs.isEmpty }
    var appleJob: TranslationJob? { activeJobs[.apple] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let enabled = defaults.stringArray(forKey: "enabledTranslationProviders") {
            selectedProviders = Set(enabled.compactMap(Provider.init(rawValue:)))
        } else {
            selectedProviders = [Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .apple]
        }
        source = Language(rawValue: defaults.string(forKey: "sourceLanguage") ?? "")
        target = Language(rawValue: defaults.string(forKey: "targetLanguage") ?? "")
    }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        guard selectedProviders.contains(provider) != enabled else { return }
        if enabled {
            selectedProviders.insert(provider)
        } else {
            selectedProviders.remove(provider)
            activeJobs[provider] = nil
            outputs[provider] = nil
            cloudTasks.removeValue(forKey: provider)?.cancel()
        }
        defaults.set(enabledProviders.map(\.rawValue), forKey: "enabledTranslationProviders")
    }

    func output(for provider: Provider) -> TranslationOutput {
        outputs[provider] ?? .idle
    }

    func begin(with input: String) {
        edit(input)
        translate()
    }

    func loadInput(_ load: @escaping () async throws -> String) {
        inputTask?.cancel()
        inputStatus = .loading
        inputTask = Task(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let input = try await load()
                guard let self, !Task.isCancelled else { return }
                self.inputTask = nil
                self.inputStatus = .idle
                self.begin(with: input)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.inputTask = nil
                let message = (error as? LocalizedError)?.errorDescription ?? "无法读取原文，请重试。"
                self.inputStatus = error is CancellationError ? .idle : .failed(message)
            }
        }
    }

    func translate() {
        guard !selectedProviders.isEmpty,
              !isTranslating || !selectedProviders.allSatisfy({ outputs[$0] != nil }) else { return }
        guard hasText, let range = CloudText.trimmedRange(in: text[...]) else { return }
        let input = range == text.startIndex..<text.endIndex ? text : String(text[range])
        clearResults()
        let destination = target ?? automaticTarget(for: input)
        for provider in enabledProviders {
            let job = TranslationJob(text: input, provider: provider, source: source, target: destination)
            activeJobs[provider] = job
            outputs[provider] = .translating
            let translate: @Sendable (TranslationJob) async throws -> String
            switch provider {
            case .apple: continue
            case .volcengine: translate = Volcengine.translate
            case .aliyun: translate = Aliyun.translate
            }
            cloudTasks[provider] = Task { [weak self] in
                do {
                    let translation = try await translate(job)
                    self?.finish(job, with: .success(translation))
                } catch {
                    self?.finish(job, with: .failure(error))
                }
            }
        }
    }

    nonisolated func appleAction(for job: TranslationJob) -> (TranslationSession) async -> Void {
        { session in
            guard await self.appleJob?.id == job.id, !Task.isCancelled else { return }
            do {
                let response = try await session.translate(job.text)
                await self.finish(job, with: .success(response.targetText))
            } catch {
                await self.finish(job, with: .failure(error))
            }
        }
    }

    func edit(_ input: String) {
        guard text != input else { return }
        cancelInputLoad()
        clearResults()
        text = input
        let nonWhitespace = input.hasNonWhitespace
        if hasText != nonWhitespace { hasText = nonWhitespace }
    }

    func reset() {
        cancelInputLoad()
        edit("")
    }

    private func cancelInputLoad() {
        guard inputStatus != .idle else { return }
        inputTask?.cancel()
        inputTask = nil
        inputStatus = .idle
    }

    private func automaticTarget(for input: String) -> Language {
        if let source { return source.isChinese ? .english : .simplifiedChinese }
        let sample = String(input.prefix(512))
        let detected = NLLanguageRecognizer.dominantLanguage(for: sample)
        if detected == .simplifiedChinese || detected == .traditionalChinese { return .english }
        if detected == nil, sample.range(of: "\\p{Han}", options: .regularExpression) != nil {
            return .english
        }
        return .simplifiedChinese
    }

    private func changeLanguages() {
        defaults.set(source?.rawValue, forKey: "sourceLanguage")
        defaults.set(target?.rawValue, forKey: "targetLanguage")
        clearResults()
    }

    private func clearResults() {
        guard !outputs.isEmpty else { return }
        activeJobs.removeAll()
        for task in cloudTasks.values { task.cancel() }
        cloudTasks.removeAll()
        outputs.removeAll()
    }

    private func finish(_ job: TranslationJob, with outcome: Result<String, any Error>) {
        guard activeJobs[job.provider]?.id == job.id else { return }
        activeJobs[job.provider] = nil
        cloudTasks[job.provider] = nil
        switch outcome {
        case .success(let translation):
            outputs[job.provider] = .translated(translation, language: job.target)
        case .failure(let error):
            outputs[job.provider] = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        guard let translationError = error as? TranslationError else { return error.localizedDescription }
        switch translationError {
        case .nothingToTranslate, .unsupportedLanguagePairing:
            return "当前语言组合无法翻译，请更换原文语言或译文语言。"
        case .unsupportedSourceLanguage, .unsupportedTargetLanguage:
            return "Apple 翻译不支持该语言，请更换语言。"
        case .unableToIdentifyLanguage:
            return "无法识别原文语言，请手动选择原文语言。"
        default:
            return "Apple 翻译未完成。请确认语言已下载，再试一次。"
        }
    }
}

extension String {
    var hasNonWhitespace: Bool {
        let whitespace = CharacterSet.whitespacesAndNewlines
        return unicodeScalars.contains { !whitespace.contains($0) }
    }
}
