import AppKit
import ScreenCaptureKit
import Vision

struct ScreenSelection: Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let anchor: CGPoint
}

enum ScreenOCR {
    enum Failure: LocalizedError {
        case displayUnavailable, noText

        var errorDescription: String? {
            switch self {
            case .displayUnavailable: "无法截取该显示器，请重新框选。"
            case .noText: "选区中没有识别到文字。"
            }
        }
    }

    static func recognize(_ selection: ScreenSelection) async throws -> String {
        let image = try await capture(selection)
        try Task.checkCancellation()
        return try recognize(image)
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
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

    private static func capture(_ selection: ScreenSelection) async throws -> CGImage {
        let contents = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = contents.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw Failure.displayUnavailable
        }
        try Task.checkCancellation()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApplications = contents.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.sourceRect = selection.rect
        configuration.width = max(1, Int((selection.rect.width * scale).rounded()))
        configuration.height = max(1, Int((selection.rect.height * scale).rounded()))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

struct OCRLine {
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

@MainActor
final class SelectionOverlay {
    private var windows: [UtilityPanel] = []
    private var completion: ((ScreenSelection?) -> Void)?

    func begin(completion: @escaping (ScreenSelection?) -> Void) {
        cancel()
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let frame = screen.frame
            let panel = UtilityPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.onEscape = { [weak self] in self?.cancel() }
            panel.contentView = SelectionView(
                frame: CGRect(origin: .zero, size: frame.size),
                hasHint: frame.contains(mouse)
            ) { [weak self] rect, point in
                let selection = ScreenSelection(
                    displayID: number.uint32Value, rect: rect,
                    anchor: CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y)
                )
                self?.finish(selection)
            }
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        guard let keyWindow = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first else {
            cancel()
            return
        }
        NSApp.activate()
        keyWindow.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ selection: ScreenSelection?) {
        let callback = completion
        completion = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        callback?(selection)
    }
}

@MainActor
private final class SelectionView: NSView {
    private let hasHint: Bool
    private let onSelection: (CGRect, CGPoint) -> Void
    private var start: CGPoint?
    private var selection = CGRect.zero

    init(frame: CGRect, hasHint: Bool, onSelection: @escaping (CGRect, CGPoint) -> Void) {
        self.hasHint = hasHint
        self.onSelection = onSelection
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: CGRect) {
        let overlay = NSBezierPath(rect: bounds)
        if !selection.isEmpty { overlay.appendRect(selection) }
        overlay.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.29).setFill()
        overlay.fill()

        if !selection.isEmpty {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1
            border.stroke()
        } else if hasHint {
            let hint = NSAttributedString(
                string: "拖动框选文字   ·   Esc 取消",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
            let size = hint.size()
            let frame = CGRect(x: bounds.midX - size.width / 2, y: 54, width: size.width, height: size.height)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: frame.insetBy(dx: -14, dy: -8), xRadius: 7, yRadius: 7).fill()
            hint.draw(in: frame)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = location(event)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(to: location(event))
    }

    override func mouseUp(with event: NSEvent) {
        let end = location(event)
        updateSelection(to: end)
        start = nil
        guard selection.width >= 4, selection.height >= 4 else {
            selection = .zero
            needsDisplay = true
            return
        }
        onSelection(selection.integral.intersection(bounds), end)
    }

    private func updateSelection(to point: CGPoint) {
        guard let start else { return }
        selection = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(start.x - point.x), height: abs(start.y - point.y)
        )
        needsDisplay = true
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
}
