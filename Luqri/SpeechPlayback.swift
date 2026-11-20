import AVFoundation
import NaturalLanguage
import Observation

@MainActor
@Observable
final class SpeechPlayback: NSObject, AVSpeechSynthesizerDelegate {
    enum Item: Equatable {
        case source, translation(Provider)
    }

    private(set) var playing: Item?
    private(set) var error: String?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var utteranceID: ObjectIdentifier?

    func toggle(_ item: Item, text: String, language: Language?) {
        let wasPlaying = playing == item
        stop()
        guard !wasPlaying, text.hasNonWhitespace else { return }
        guard let language = language ?? Self.detectLanguage(text), language == .english || language.isChinese else {
            error = "离线朗读支持中文和英语。"
            return
        }
        guard let voice = Self.localVoice(for: language) else {
            error = "未找到本机的\(language.title)语音，请在系统设置的「朗读与发声」中检查。"
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let engine = AVSpeechSynthesizer()
        engine.delegate = self
        synthesizer = engine
        utteranceID = ObjectIdentifier(utterance)
        playing = item
        engine.speak(utterance)
    }

    func stop() {
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        clearPlayback()
        if error != nil { error = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(ObjectIdentifier(utterance))
    }

    private nonisolated func complete(_ finishedUtterance: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == finishedUtterance else { return }
            self.clearPlayback()
        }
    }

    private func clearPlayback() {
        synthesizer = nil
        utteranceID = nil
        if playing != nil { playing = nil }
    }

    private static func detectLanguage(_ text: String) -> Language? {
        let sample = String(text.prefix(512))
        let bytes = sample.utf8
        if bytes.count <= 16, bytes.allSatisfy({ $0 < 128 }),
           sample.range(of: "[a-zA-Z]", options: .regularExpression) != nil {
            return .english
        }
        if let detected = NLLanguageRecognizer.dominantLanguage(for: sample), detected != .undetermined {
            return Language(rawValue: detected.rawValue)
        }
        if sample.range(of: "\\p{Han}", options: .regularExpression) != nil { return .simplifiedChinese }
        if sample.range(of: "[a-zA-Z]", options: .regularExpression) != nil { return .english }
        return nil
    }

    private static func localVoice(for language: Language) -> AVSpeechSynthesisVoice? {
        let locale = switch language {
        case .english: "en-US"
        case .traditionalChinese: "zh-TW"
        default: "zh-CN"
        }
        let prefix = language.isChinese ? "zh-" : "en-"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.quality == .default && $0.voiceTraits.isEmpty && $0.language.hasPrefix(prefix)
        }
        let matching = voices.filter { $0.language == locale }
        return matching.first { $0.identifier.hasPrefix("com.apple.voice.compact.") }
            ?? matching.first { $0.identifier.hasPrefix("com.apple.voice.super-compact.") }
            ?? matching.first
            ?? voices.first
    }
}
