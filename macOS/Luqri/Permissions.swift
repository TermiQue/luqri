import AppKit
import ApplicationServices

@MainActor
enum AppPermission: CaseIterable {
    case accessibility, screenRecording

    var title: String {
        switch self {
        case .accessibility:
            if #available(macOS 27.3, *) { return "辅助功能" }
            if #available(macOS 27.0, *) { return "设备控制和数据访问" }
            return "辅助功能"
        case .screenRecording:
            if #available(macOS 27.0, *) { return "录屏与系统录音" }
            return "屏幕与系统音频录制"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: "读取选中文字"
        case .screenRecording: "截图识别与翻译"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    @discardableResult
    func openSettings() -> Bool {
        let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
final class PermissionPrompt: NSObject, NSWindowDelegate {
    let permission: AppPermission
    let alert = NSAlert()
    var onLater: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var dragPanel: NSPanel?
    private var placementTask: Task<Void, Never>?

    var window: NSWindow { alert.window }

    init(permission: AppPermission) {
        self.permission = permission
        super.init()
        let bundle = Bundle.main.bundleURL
        let artwork = LuqriApp.loadAppIcon(size: NSSize(width: 48, height: 48)) ?? NSWorkspace.shared.icon(forFile: bundle.path)
        alert.icon = artwork
        switch permission {
        case .accessibility:
            alert.messageText = "划词翻译需要「\(permission.title)」权限"
            alert.informativeText = "请在系统设置中拖入当前版本的 Luqri 并开启开关。若更新后列表里已有 Luqri，请先移除旧条目。授权后请重新触发划词翻译。"
        case .screenRecording:
            alert.messageText = "截图需要「\(permission.title)」权限"
            alert.informativeText = "请将 Luqri 加入上方「\(permission.title)」列表并开启开关。「仅系统录音」无法用于截图。若 macOS 要求退出，请重新打开 Luqri。"
        }
        let authorize = alert.addButton(withTitle: "前往授权")
        authorize.target = self
        authorize.action = #selector(openSettings)
        let later = alert.addButton(withTitle: "稍后")
        later.target = self
        later.action = #selector(dismiss)
        later.keyEquivalent = "\u{1b}"
        alert.layout()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        (window as? NSPanel)?.hidesOnDeactivate = false
    }

    func present() {
        if let dragPanel {
            dragPanel.orderFrontRegardless()
            return
        }
        guard placementTask == nil else { return }
        if !window.isVisible { window.center() }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        placementTask?.cancel()
        placementTask = nil
        dragPanel?.delegate = nil
        dragPanel?.orderOut(nil)
        dragPanel = nil
        window.orderOut(nil)
    }

    func containsWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        return candidate === window || candidate === dragPanel
    }

    @objc func dismiss() {
        let fallback = window.isVisible ? onLater : nil
        close()
        onDismiss?()
        fallback?()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === dragPanel { dismiss() }
    }

    @objc private func openSettings() {
        let screen = window.screen
        guard permission.openSettings() else { return }
        window.orderOut(nil)
        placementTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if let frame = Self.systemSettingsFrame() {
                    self.showDragPanel(at: frame, fallbackScreen: screen)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.showDragPanel(at: nil, fallbackScreen: screen)
        }
    }

    private func showDragPanel(at settingsFrame: CGRect?, fallbackScreen: NSScreen?) {
        placementTask = nil
        let dragView = PermissionDragView(bundle: Bundle.main.bundleURL, icon: alert.icon ?? NSApp.applicationIconImage,
                                          permission: permission) { [weak self] point in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences",
                  let frame = Self.systemSettingsFrame() ?? settingsFrame, frame.contains(point) else { return }
            self?.dismiss()
        }
        let padding: CGFloat = 10
        let content = NSView(frame: CGRect(x: 0, y: 0, width: dragView.bounds.width + padding * 2,
                                           height: dragView.bounds.height + padding * 2))
        dragView.setFrameOrigin(CGPoint(x: padding, y: padding))
        content.addSubview(dragView)
        let panel = NSPanel(contentRect: content.bounds, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "拖动 Luqri 授权"
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = content
        panel.delegate = self
        let targetScreen = settingsFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        }
        if let visible = (targetScreen ?? fallbackScreen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(Self.dragPanelOrigin(size: panel.frame.size, settingsFrame: settingsFrame, visible: visible))
        } else {
            panel.center()
        }
        dragPanel = panel
        panel.orderFrontRegardless()
    }

    private static func dragPanelOrigin(size: CGSize, settingsFrame: CGRect?, visible: CGRect) -> CGPoint {
        let margin: CGFloat = 8
        let x = (settingsFrame?.midX ?? visible.midX) - size.width / 2
        let y = (settingsFrame?.minY ?? visible.minY) + margin
        return CGPoint(
            x: min(max(x, visible.minX + margin), visible.maxX - size.width - margin),
            y: min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        )
    }

    private static func systemSettingsFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.systempreferences",
              let top = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 300, rect.height >= 300 else { continue }
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

@MainActor
private final class PermissionDragView: NSView, NSDraggingSource {
    private let bundle: URL
    private let icon: NSImage
    private let onAcceptedDrop: (NSPoint) -> Void

    init(bundle: URL, icon: NSImage, permission: AppPermission, onAcceptedDrop: @escaping (NSPoint) -> Void) {
        self.bundle = bundle
        self.icon = icon
        self.onAcceptedDrop = onAcceptedDrop
        super.init(frame: CGRect(x: 0, y: 0, width: 292, height: 50))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let preview = NSImageView(frame: CGRect(x: 8, y: 13, width: 24, height: 24))
        preview.image = icon
        preview.imageScaling = .scaleProportionallyUpOrDown
        addSubview(preview)
        let note = permission == .screenRecording ? "请选择上方列表，避开「仅系统录音」" : "添加后请开启 Luqri 的开关"
        let caption = NSTextField(wrappingLabelWithString: "拖到「\(permission.title)」\n\(note)")
        caption.font = .systemFont(ofSize: 11)
        caption.frame = CGRect(x: 40, y: 6, width: 222, height: 34)
        addSubview(caption)
        let arrow = NSImageView(frame: CGRect(x: 266, y: 17, width: 16, height: 16))
        arrow.image = LucideIcon.menuImage("arrow-up", size: 16)
        arrow.contentTintColor = .controlAccentColor
        addSubview(arrow)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point).map { _ in self } }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: bundle as NSURL)
        item.setDraggingFrame(CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        window?.ignoresMouseEvents = true
        window?.alphaValue = 0
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        window?.ignoresMouseEvents = false
        window?.alphaValue = 1
        if operation.contains(.copy) { onAcceptedDrop(screenPoint) }
    }
}
