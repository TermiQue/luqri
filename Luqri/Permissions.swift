import AppKit
import ApplicationServices

@MainActor
enum AppPermission: CaseIterable {
    case accessibility, screenRecording

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .screenRecording: "录屏与系统录音"
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

    func openSettings() {
        let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class PermissionPrompt: NSObject {
    let permission: AppPermission
    let alert = NSAlert()
    var onLater: (() -> Void)?
    var onDismiss: (() -> Void)?

    var window: NSWindow { alert.window }

    init(permission: AppPermission) {
        self.permission = permission
        super.init()
        let bundle = Bundle.main.bundleURL
        let artwork = LuqriApp.loadAppIcon(size: NSSize(width: 48, height: 48)) ?? NSWorkspace.shared.icon(forFile: bundle.path)
        alert.icon = artwork
        switch permission {
        case .accessibility:
            alert.messageText = "划词翻译需要辅助功能权限"
            alert.informativeText = "将 Luqri 拖进辅助功能列表并开启权限，然后重新触发划词翻译。"
        case .screenRecording:
            alert.messageText = "截图需要录屏权限"
            alert.informativeText = "将 Luqri 拖进录屏列表并开启权限，然后重新截图。若 macOS 要求退出，请重新打开 Luqri。"
        }
        let authorize = alert.addButton(withTitle: "前往授权")
        authorize.target = self
        authorize.action = #selector(openSettings)
        let later = alert.addButton(withTitle: "稍后")
        later.target = self
        later.action = #selector(dismiss)
        later.keyEquivalent = "\u{1b}"
        alert.accessoryView = PermissionDragView(bundle: bundle, icon: artwork)
        alert.layout()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        (window as? NSPanel)?.hidesOnDeactivate = false
    }

    func present() {
        if !window.isVisible { window.center() }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    @objc func dismiss() {
        close()
        onDismiss?()
        onLater?()
    }

    @objc private func openSettings() {
        if let frame = window.screen?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: frame.minX + 20, y: window.frame.minY))
        }
        permission.openSettings()
    }
}

@MainActor
private final class PermissionDragView: NSView, NSDraggingSource {
    private let bundle: URL
    private let icon: NSImage

    init(bundle: URL, icon: NSImage) {
        self.bundle = bundle
        self.icon = icon
        super.init(frame: CGRect(x: 0, y: 0, width: 216, height: 38))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let preview = NSImageView(frame: CGRect(x: 8, y: 7, width: 24, height: 24))
        preview.image = icon
        preview.imageScaling = .scaleProportionallyUpOrDown
        addSubview(preview)
        let caption = NSTextField(labelWithString: "拖动 Luqri 到权限列表")
        caption.font = .systemFont(ofSize: 12)
        caption.sizeToFit()
        caption.setFrameOrigin(CGPoint(x: 40, y: (bounds.height - caption.frame.height) / 2))
        addSubview(caption)
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
}
