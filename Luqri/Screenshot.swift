import AppKit
import QuartzCore
import ScreenCaptureKit

@MainActor
final class Screenshot {
    private var image: CGImage?
    let anchor: CGPoint

    init(image: CGImage, anchor: CGPoint) {
        self.image = image
        self.anchor = anchor
    }

    func takeImage() -> CGImage {
        guard let image else { preconditionFailure("A screenshot can only be consumed once.") }
        self.image = nil
        return image
    }
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
        guard AppPermission.screenRecording.isGranted else {
            throw Failure.permissionDenied
        }
        guard let selection = try await selectRegion(keepsFocus: keepsFocus) else { return nil }
        do {
            let image = try await Self.captureImage(selection, maximumPixelDimension: maximumPixelDimension)
            try Task.checkCancellation()
            return Screenshot(image: image, anchor: selection.anchor)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw Failure.permissionDenied
        } catch let error as SCStreamError where error.code == .userStopped {
            throw CancellationError()
        }
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
    static let cursor: NSCursor = {
        let size = CGSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: 5, y: 12))
            cross.line(to: CGPoint(x: 19, y: 12))
            cross.move(to: CGPoint(x: 12, y: 5))
            cross.line(to: CGPoint(x: 12, y: 19))
            cross.lineCapStyle = .round
            NSColor.black.setStroke()
            cross.lineWidth = 4
            cross.stroke()
            NSColor.white.setStroke()
            cross.lineWidth = 2
            cross.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 12, y: 12))
    }()

    private var windows: [UtilityPanel] = []
    private var completion: ((ScreenSelection?) -> Void)?
    private var activationTask: Task<Void, Never>?
    private var hasSelectionCursor = false

    func begin(completion: @escaping (ScreenSelection?) -> Void) {
        self.completion = completion
        if NSApp.isActive {
            show()
            return
        }

        // A global shortcut can arrive while a different app owns the system cursor.
        activationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.allowsRunningApplicationSubstitution = false
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            guard !Task.isCancelled, let self else { return }
            self.activationTask = nil
            self.show()
        }
    }

    private func show() {
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
        Self.cursor.push()
        hasSelectionCursor = true
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ selection: ScreenSelection?) {
        activationTask?.cancel()
        activationTask = nil
        let callback = completion
        completion = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if hasSelectionCursor {
            NSCursor.pop()
            hasSelectionCursor = false
        }
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
    private let topShade = CALayer()
    private let bottomShade = CALayer()
    private let leftShade = CALayer()
    private let rightShade = CALayer()
    private let border = CALayer()
    private let hint = CALayer()
    private let hintText = CATextLayer()
    private var hintTrackingArea: NSTrackingArea?
    private var start: CGPoint?
    private var selection = CGRect.zero

    init(frame: CGRect, hasHint: Bool, onSelection: @escaping (CGRect, CGPoint) -> Void) {
        self.hasHint = hasHint
        self.onSelection = onSelection
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        let shade = NSColor.black.withAlphaComponent(0.29).cgColor
        for layer in [topShade, bottomShade, leftShade, rightShade] {
            layer.backgroundColor = shade
            root.addSublayer(layer)
        }
        border.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        border.borderWidth = 1
        root.addSublayer(border)

        if hasHint {
            hint.backgroundColor = NSColor.white.cgColor
            hint.cornerRadius = 7
            hintText.string = Self.hint
            hintText.alignmentMode = .center
            hint.addSublayer(hintText)
            root.addSublayer(hint)
        }
        layer = root
        wantsLayer = true
        updateLayers()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: SelectionOverlay.cursor)
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        hintText.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hintText.contentsScale = window?.backingScaleFactor ?? 1
        updateHintVisibility()
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

    override func mouseEntered(with event: NSEvent) { updateHintVisibility() }
    override func mouseExited(with event: NSEvent) { updateHintVisibility() }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let opening = selection.intersection(bounds)
        border.isHidden = opening.isEmpty
        if opening.isEmpty {
            topShade.frame = bounds
            bottomShade.frame = .zero
            leftShade.frame = .zero
            rightShade.frame = .zero
        } else {
            topShade.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: opening.minY - bounds.minY)
            bottomShade.frame = CGRect(x: bounds.minX, y: opening.maxY, width: bounds.width, height: bounds.maxY - opening.maxY)
            leftShade.frame = CGRect(x: bounds.minX, y: opening.minY, width: opening.minX - bounds.minX, height: opening.height)
            rightShade.frame = CGRect(x: opening.maxX, y: opening.minY, width: bounds.maxX - opening.maxX, height: opening.height)
            border.frame = opening.insetBy(dx: -0.5, dy: -0.5)
        }
        if hasHint {
            hint.frame = hintBackground
            hintText.frame = CGRect(x: 14, y: 8, width: Self.hintSize.width, height: Self.hintSize.height)
            hint.isHidden = !shouldShowHint
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

    private func updateHintVisibility() {
        guard hasHint else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hint.isHidden = !shouldShowHint
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        SelectionOverlay.cursor.set()
        start = location(event)
        setSelection(.zero)
        updateHintVisibility()
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
            updateHintVisibility()
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
        guard selection != next else { return }
        selection = next
        updateLayers()
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
}
