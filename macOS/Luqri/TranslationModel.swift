import Foundation
import NaturalLanguage
import Observation
import Translation

enum Provider: String, CaseIterable, Identifiable, Codable {
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

enum Language: String, CaseIterable, Identifiable, Codable {
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

    private struct SourceInput {
        var text = ""
        var hasText = false
        var status = InputStatus.idle
    }

    private let defaults: UserDefaults
    @ObservationIgnored private let translateCloud: (TranslationJob) async throws -> String

    private var input = SourceInput()
    var text: String { input.text }
    var hasText: Bool { input.hasText }
    var source: Language? {
        didSet { if source != oldValue { changeLanguages() } }
    }
    var target: Language? {
        didSet { if target != oldValue { changeLanguages() } }
    }

    @Observable
    fileprivate final class OutputSlot {
        var value = TranslationOutput.idle
    }

    private var selectedProviders: Set<Provider>
    private let outputs = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, OutputSlot()) })
    @ObservationIgnored private var activeJobs: [Provider: UUID] = [:]
    private(set) var isTranslating = false
    private(set) var appleJob: TranslationJob?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var cloudTasks: [Provider: Task<Void, Never>] = [:]

    var enabledProviders: [Provider] { Provider.allCases.filter(selectedProviders.contains) }
    var isLoadingInput: Bool { input.status == .loading }
    var inputError: String? {
        if case .failed(let message) = input.status { return message }
        return nil
    }

    init(defaults: UserDefaults = .standard, translateCloud: @escaping (TranslationJob) async throws -> String) {
        self.defaults = defaults
        self.translateCloud = translateCloud
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
            if provider == .apple { appleJob = nil }
            outputs[provider]?.value = .idle
            cloudTasks.removeValue(forKey: provider)?.cancel()
            if activeJobs.isEmpty, isTranslating { isTranslating = false }
        }
        defaults.set(enabledProviders.map(\.rawValue), forKey: "enabledTranslationProviders")
    }

    func output(for provider: Provider) -> TranslationOutput {
        outputs[provider]?.value ?? .idle
    }

    func begin(with input: String) {
        edit(input)
        translate()
    }

    func loadInput(_ load: @escaping () async throws -> String) {
        inputTask?.cancel()
        input.status = .loading
        inputTask = Task(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let input = try await load()
                guard let self, !Task.isCancelled else { return }
                self.inputTask = nil
                if self.text == input { self.input.status = .idle }
                self.begin(with: input)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.inputTask = nil
                let message = (error as? LocalizedError)?.errorDescription ?? "无法读取原文，请重试。"
                self.input.status = error is CancellationError ? .idle : .failed(message)
            }
        }
    }

    func translate() {
        guard !selectedProviders.isEmpty,
              !isTranslating || !selectedProviders.allSatisfy({ output(for: $0) != .idle }) else { return }
        guard hasText, let range = CloudText.trimmedRange(in: text[...]) else { return }
        let input = range == text.startIndex..<text.endIndex ? text : String(text[range])
        clearResults()
        let destination = target ?? automaticTarget(for: input)
        isTranslating = true
        for provider in enabledProviders {
            let job = TranslationJob(text: input, provider: provider, source: source, target: destination)
            activeJobs[provider] = job.id
            outputs[provider]?.value = .translating
            if provider == .apple {
                appleJob = job
                continue
            }
            cloudTasks[provider] = Task { [weak self] in
                guard let translateCloud = self?.translateCloud else { return }
                do {
                    let translation = try await translateCloud(job)
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
        inputTask?.cancel()
        inputTask = nil
        clearResults()
        self.input = SourceInput(text: input, hasText: input.hasNonWhitespace)
    }

    func reset() {
        if text.isEmpty {
            inputTask?.cancel()
            inputTask = nil
            if input.status != .idle { input.status = .idle }
        } else {
            edit("")
        }
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
        activeJobs.removeAll()
        if isTranslating { isTranslating = false }
        if appleJob != nil { appleJob = nil }
        for task in cloudTasks.values { task.cancel() }
        cloudTasks.removeAll()
        for slot in outputs.values where slot.value != .idle { slot.value = .idle }
    }

    private func finish(_ job: TranslationJob, with outcome: Result<String, any Error>) {
        guard activeJobs[job.provider] == job.id else { return }
        activeJobs[job.provider] = nil
        if activeJobs.isEmpty { isTranslating = false }
        if job.provider == .apple { appleJob = nil }
        cloudTasks[job.provider] = nil
        switch outcome {
        case .success(let translation):
            outputs[job.provider]?.value = .translated(translation, language: job.target)
        case .failure(let error):
            outputs[job.provider]?.value = .failed(Self.message(for: error))
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
