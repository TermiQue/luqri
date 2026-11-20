import AppKit
import ScreenCaptureKit

struct Screenshot: Sendable {
    let image: CGImage
    let anchor: CGPoint
}

@MainActor
final class ScreenshotCapture {
    enum Failure: LocalizedError {
        case permissionDenied, displayUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "需要屏幕录制权限。"
            case .displayUnavailable: "无法截取该显示器，请重新框选。"
            }
        }
    }

    private let overlay = SelectionOverlay()
    private var selectionID: UUID?

    func capture(keepsFocus: Bool = false, maximumPixelDimension: Int? = nil) async throws -> Screenshot? {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw Failure.permissionDenied
        }
        guard let selection = try await selectRegion(keepsFocus: keepsFocus) else { return nil }
        let image = try await Self.captureImage(selection, maximumPixelDimension: maximumPixelDimension)
        try Task.checkCancellation()
        return Screenshot(image: image, anchor: selection.anchor)
    }

    func cancelSelection() {
        selectionID = nil
        overlay.cancel()
    }

    static func restoreFocus(to app: NSRunningApplication?) {
        guard NSApp.isActive, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    private func selectRegion(keepsFocus: Bool) async throws -> ScreenSelection? {
        let id = UUID()
        let selection = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await withCheckedContinuation { continuation in
                cancelSelection()
                selectionID = id
                let previousApp = NSWorkspace.shared.frontmostApplication
                overlay.begin { [weak self] selection in
                    if let self, self.selectionID == id {
                        self.selectionID = nil
                        if !keepsFocus || selection == nil {
                            Self.restoreFocus(to: previousApp)
                        }
                    }
                    continuation.resume(returning: selection)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.selectionID == id else { return }
                self.overlay.cancel()
            }
        }
        try Task.checkCancellation()
        return selection
    }

    private nonisolated static func captureImage(
        _ selection: ScreenSelection, maximumPixelDimension: Int?
    ) async throws -> CGImage {
        let contents = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = contents.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw Failure.displayUnavailable
        }
        try Task.checkCancellation()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApplications = contents.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = selection.rect
        let size = pixelSize(for: selection.rect.size, scale: CGFloat(filter.pointPixelScale), limit: maximumPixelDimension)
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private nonisolated static func pixelSize(
        for size: CGSize, scale: CGFloat, limit: Int?
    ) -> (width: Int, height: Int) {
        let outputScale = limit.map { min(scale, CGFloat($0) / max(size.width, size.height)) } ?? scale
        return (max(1, Int((size.width * outputScale).rounded())), max(1, Int((size.height * outputScale).rounded())))
    }
}

private struct ScreenSelection: Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let anchor: CGPoint
}

@MainActor
private final class SelectionOverlay {
    private var windows: [UtilityPanel] = []
    private var completion: ((ScreenSelection?) -> Void)?
    private var hasSelectionCursor = false

    func begin(completion: @escaping (ScreenSelection?) -> Void) {
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
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        guard let keyWindow = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first else {
            cancel()
            return
        }
        NSApp.activate()
        keyWindow.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
        hasSelectionCursor = true
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ selection: ScreenSelection?) {
        let callback = completion
        completion = nil
        if hasSelectionCursor {
            NSCursor.pop()
            hasSelectionCursor = false
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        callback?(selection)
    }
}

@MainActor
private final class SelectionView: NSView {
    private static let hint = NSAttributedString(
        string: "拖动框选文字   ·   Esc 取消",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black
        ]
    )
    private static let hintSize = hint.size()

    private let hasHint: Bool
    private let onSelection: (CGRect, CGPoint) -> Void
    private var hintTrackingArea: NSTrackingArea?
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hasHint else { return }
        if let hintTrackingArea { removeTrackingArea(hintTrackingArea) }
        let area = NSTrackingArea(
            rect: hintAvoidanceRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hintTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { invalidateHint() }
    override func mouseExited(with event: NSEvent) { invalidateHint() }

    override func draw(_ dirtyRect: CGRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
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
        } else if dirtyRect.intersects(hintBackground), shouldShowHint {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: hintBackground, xRadius: 7, yRadius: 7).fill()
            Self.hint.draw(in: hintFrame)
        }
    }

    private var hintFrame: CGRect {
        let size = Self.hintSize
        return CGRect(x: bounds.midX - size.width / 2, y: 54, width: size.width, height: size.height)
    }

    private var hintBackground: CGRect { hintFrame.insetBy(dx: -14, dy: -8) }
    private var hintAvoidanceRect: CGRect { hintBackground.insetBy(dx: -10, dy: -10) }

    private var shouldShowHint: Bool {
        guard hasHint, start == nil, let window else { return false }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return !hintAvoidanceRect.contains(pointer)
    }

    private func invalidateHint() {
        if hasHint { setNeedsDisplay(hintBackground.insetBy(dx: -1, dy: -1).integral) }
    }

    override func mouseDown(with event: NSEvent) {
        start = location(event)
        setSelection(.zero)
        invalidateHint()
    }

    override func mouseDragged(with event: NSEvent) {
        setSelection(selection(to: location(event)))
    }

    override func mouseUp(with event: NSEvent) {
        let end = location(event)
        let final = selection(to: end)
        start = nil
        guard final.width >= 4, final.height >= 4 else {
            setSelection(.zero)
            invalidateHint()
            return
        }
        onSelection(final.integral.intersection(bounds), end)
    }

    private func selection(to point: CGPoint) -> CGRect {
        guard let start else { return .zero }
        return CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(start.x - point.x), height: abs(start.y - point.y)
        )
    }

    private func setSelection(_ next: CGRect) {
        let previous = selection
        guard previous != next else { return }
        selection = next
        if previous.isEmpty || next.isEmpty {
            invalidateSelectionArea(previous.isEmpty ? next : previous)
            return
        }

        // Only the strips swept by the moving edges and their borders need repainting.
        let envelope = previous.union(next)
        func verticalEdge(from old: CGFloat, to new: CGFloat) {
            guard old != new else { return }
            invalidateSelectionArea(CGRect(x: min(old, new), y: envelope.minY, width: abs(old - new), height: envelope.height))
        }
        func horizontalEdge(from old: CGFloat, to new: CGFloat) {
            guard old != new else { return }
            invalidateSelectionArea(CGRect(x: envelope.minX, y: min(old, new), width: envelope.width, height: abs(old - new)))
        }
        verticalEdge(from: previous.minX, to: next.minX)
        verticalEdge(from: previous.maxX, to: next.maxX)
        horizontalEdge(from: previous.minY, to: next.minY)
        horizontalEdge(from: previous.maxY, to: next.maxY)
    }

    private func invalidateSelectionArea(_ area: CGRect) {
        if !area.isEmpty { setNeedsDisplay(area.insetBy(dx: -1, dy: -1).integral) }
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
}
