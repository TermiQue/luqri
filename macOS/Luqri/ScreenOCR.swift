import Foundation
import os
import Vision

enum OCRProvider: String, CaseIterable, Identifiable, Codable {
    case appleVision, volcengine, aliyun

    static let preferenceKey = "ocrProvider"
    var id: Self { self }

    var title: String {
        switch self {
        case .appleVision: "Apple"
        case .volcengine: "火山引擎"
        case .aliyun: "阿里云"
        }
    }

    var meter: CloudMeter? {
        switch self {
        case .appleVision: nil
        case .volcengine: .volcengineOCR
        case .aliyun: .aliyunOCR
        }
    }

    var maximumCaptureDimension: Int? {
        meter == nil ? nil : CloudOCRImage.maximumDimension
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .appleVision
    }

    func recognize(_ image: consuming CGImage) async throws -> String {
        switch self {
        case .appleVision: try await ScreenOCR.recognize(consume image)
        case .volcengine: try await VolcengineOCR.recognize(consume image)
        case .aliyun: try await Aliyun.recognize(consume image)
        }
    }
}

enum OCRFailure: LocalizedError {
    case noText

    var errorDescription: String? { "选区中没有识别到文字。" }
}

enum ScreenOCR {
    private static let jobs = SerialWorkQueue()
    private static let worker = DispatchQueue(label: "com.termique.luqri.vision", qos: .userInitiated)

    static func recognize(_ image: CGImage) async throws -> String {
        try await jobs.run {
            let recognition = Recognition()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let text = try await withCheckedThrowingContinuation { continuation in
                    worker.async {
                        continuation.resume(with: Result { try recognition.perform(on: image) })
                    }
                }
                try Task.checkCancellation()
                return text
            } onCancel: {
                recognition.cancel()
            }
        }
    }

    // Vision permits cancellation from another thread. Processing and results stay on the worker.
    private final class Recognition: @unchecked Sendable {
        private let request = VNRecognizeTextRequest()
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init() {
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
        }

        func cancel() {
            cancelled.withLock { $0 = true }
            request.cancel()
        }

        func perform(on image: CGImage) throws -> String {
            try autoreleasepool {
                do {
                    try checkCancellation()
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    try checkCancellation()
                    throw error
                }
                let width = image.width, height = image.height
                let lines = (request.results ?? []).lazy.compactMap { observation -> OCRLine? in
                    guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return OCRLine(text: text, bounds: VNImageRectForNormalizedRect(observation.boundingBox, width, height))
                }
                let text = OCRLine.paragraphs(from: lines)
                try checkCancellation()
                guard !text.isEmpty else { throw OCRFailure.noText }
                return text
            }
        }

        private func checkCancellation() throws {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        }
    }
}

struct OCRLine {
    let text: String
    let bounds: CGRect

    static func paragraphs(from lines: some Sequence<Self>) -> String {
        var iterator = lines.makeIterator()
        guard var previous = iterator.next() else { return "" }
        var text = previous.text
        while let next = iterator.next() {
            text += separator(between: previous, and: next)
            text += next.text
            previous = next
        }
        return text
    }

    private static func separator(between previous: Self, and next: Self) -> String {
        // The Vision bounding boxes have their vertical origin at the bottom.
        let height = max(previous.bounds.height, next.bounds.height)
        guard height > 0 else { return "\n" }
        let advance = previous.bounds.midY - next.bounds.midY
        let leading = next.bounds.minX - previous.bounds.minX
        let gap = previous.bounds.minY - next.bounds.maxY
        if advance < -height * 0.5 || gap > height * 0.9 { return "\n\n" }

        let aligned = abs(leading) < height * 0.45
        let continuesLine = advance > height * 0.55 && advance < height * 1.85
            && previous.bounds.width >= height * 5
            && previous.bounds.maxX >= next.bounds.maxX - height * 0.6
            && min(previous.bounds.height, next.bounds.height) >= height * 0.75
        guard aligned, continuesLine, !isListItem(previous.text), !isListItem(next.text),
              let last = previous.text.last, let first = next.text.first else { return "\n" }
        if ":：".contains(last) { return "\n" }
        if isEastAsian(last) && isEastAsian(first) || "，。！？、；：）】》」』".contains(first) { return "" }
        return " "
    }

    private static func isListItem(_ text: String) -> Bool {
        text.hasPrefix("•") || text.hasPrefix("・") || text.hasPrefix("- ") ||
            (text.first?.isNumber == true && text.prefix(5).contains { ".、)）".contains($0) })
    }

    private static func isEastAsian(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x3000...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
        default: return false
        }
    }
}
