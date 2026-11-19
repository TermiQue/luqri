import Foundation
import Vision

enum ScreenOCR {
    enum Failure: LocalizedError {
        case noText

        var errorDescription: String? { "选区中没有识别到文字。" }
    }

    static func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let cancellation = RequestCancellation(request: request)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try VNImageRequestHandler(cgImage: image).perform([request])
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        let lines = request.results?.compactMap { observation -> OCRLine? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return OCRLine(text: text, bounds: VNImageRectForNormalizedRect(observation.boundingBox, image.width, image.height))
        } ?? []
        let text = OCRLine.paragraphs(from: lines)
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    // Vision supports aborting an in-flight request. Only cancel() crosses executors.
    private struct RequestCancellation: @unchecked Sendable {
        let request: VNRequest
        func cancel() { request.cancel() }
    }
}

private struct OCRLine {
    let text: String
    let bounds: CGRect

    static func paragraphs(from lines: [Self]) -> String {
        guard let first = lines.first else { return "" }
        var text = first.text
        for (previous, next) in zip(lines, lines.dropFirst()) {
            text += separator(between: previous, and: next)
            text += next.text
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
