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
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    private static func capture(_ selection: ScreenSelection) async throws -> CGImage {
        if #available(macOS 15.2, *) {
            let origin = CGDisplayBounds(selection.displayID).origin
            return try await SCScreenshotManager.captureImage(
                in: selection.rect.offsetBy(dx: origin.x, dy: origin.y)
            )
        }
        let contents = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = contents.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw Failure.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.sourceRect = selection.rect
        configuration.width = max(1, Int((selection.rect.width * scale).rounded()))
        configuration.height = max(1, Int((selection.rect.height * scale).rounded()))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
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
