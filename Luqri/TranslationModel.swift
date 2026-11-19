import Foundation
import NaturalLanguage
import Observation
import Translation

enum Provider: String, CaseIterable, Identifiable {
    case apple, volcengine

    var id: Self { self }
    var title: String {
        switch self {
        case .apple: "Apple 翻译"
        case .volcengine: "火山引擎"
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

    var cloudCode: String {
        switch self {
        case .simplifiedChinese: "zh"
        case .traditionalChinese: "zh-Hant"
        default: rawValue
        }
    }

    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
}

struct TranslationJob: Identifiable {
    let id = UUID()
    let text: String
    let provider: Provider
    let source: Language?
    let target: Language

    var appleConfiguration: TranslationSession.Configuration {
        .init(source: source?.locale, target: target.locale)
    }
}

@MainActor
@Observable
final class TranslationModel {
    var text = ""
    var source: Language? {
        didSet { if source != oldValue { changeOptions() } }
    }
    var target: Language? {
        didSet { if target != oldValue { changeOptions() } }
    }
    var provider: Provider {
        didSet { if provider != oldValue { changeOptions() } }
    }

    private(set) var result = ""
    private(set) var error: String?
    private(set) var isTranslating = false
    private(set) var appleJob: TranslationJob?
    private var activeID: UUID?
    @ObservationIgnored private var cloudTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .apple
        source = Language(rawValue: defaults.string(forKey: "sourceLanguage") ?? "")
        target = Language(rawValue: defaults.string(forKey: "targetLanguage") ?? "")
    }

    func begin(with input: String) {
        clearResult()
        text = input
        translate()
    }

    func translate() {
        clearResult()
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let destination = target ?? automaticTarget(for: input)
        let job = TranslationJob(text: input, provider: provider, source: source, target: destination)
        activeID = job.id
        isTranslating = true

        switch job.provider {
        case .apple:
            appleJob = job
        case .volcengine:
            cloudTask = Task { [weak self] in
                do {
                    guard let credentials = try CloudCredentials.load() else {
                        throw VolcengineError.missingCredentials
                    }
                    let translation = try await Volcengine.translate(job, credentials: credentials)
                    self?.finish(job, with: .success(translation))
                } catch {
                    self?.finish(job, with: .failure(error))
                }
            }
        }
    }

    nonisolated func appleAction(for job: TranslationJob) -> (TranslationSession) async -> Void {
        { session in
            guard await self.activeID == job.id else { return }
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
        clearResult()
        text = input
    }

    func reset() {
        clearResult()
        text = ""
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

    private func changeOptions() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(source?.rawValue, forKey: "sourceLanguage")
        defaults.set(target?.rawValue, forKey: "targetLanguage")
        clearResult()
    }

    private func clearResult() {
        activeID = nil
        cloudTask?.cancel()
        cloudTask = nil
        appleJob = nil
        isTranslating = false
        result = ""
        error = nil
    }

    private func finish(_ job: TranslationJob, with outcome: Result<String, any Error>) {
        guard activeID == job.id else { return }
        activeID = nil
        cloudTask = nil
        appleJob = nil
        isTranslating = false

        switch outcome {
        case .success(let translation):
            result = translation
        case .failure(let failure):
            if let translationError = failure as? TranslationError {
                switch translationError {
                case .nothingToTranslate, .unsupportedLanguagePairing:
                    error = "当前语言组合无法翻译，请更换原文语言或译文语言。"
                case .unsupportedSourceLanguage, .unsupportedTargetLanguage:
                    error = "Apple 翻译不支持该语言，请更换语言。"
                case .unableToIdentifyLanguage:
                    error = "无法识别原文语言，请手动选择原文语言。"
                default:
                    error = "Apple 翻译未完成。请确认语言已下载，再试一次。"
                }
            } else {
                error = failure.localizedDescription
            }
        }
    }
}
