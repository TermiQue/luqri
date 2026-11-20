import AppKit
import ApplicationServices
import SwiftUI

@main
@MainActor
enum LuqriApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
enum Permissions {
    static func openAccessibility() {
        open("Privacy_Accessibility")
    }

    static func openScreenCapture() {
        open("Privacy_ScreenCapture")
    }

    private static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TranslationModel()
    private let screenshotCapture = ScreenshotCapture()
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalShortcuts?
    private var applicationKeyMonitor: Any?
    private var translationPanel: UtilityPanel?
    private var translationHasTakenFocus = false
    private var translationPinned = false
    private var settingsWindow: NSWindow?
    private weak var settingsAwaitingFocus: NSWindow?
    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var ocrProgress: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shortcuts = GlobalShortcuts(
            action: { [weak self] command in self?.perform(command) },
            onChange: { [weak self] in self?.refreshMenuShortcuts() }
        )
        self.shortcuts = shortcuts
        shortcuts.install()
        buildApplicationMenu()
        buildMenu()
        applicationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleApplicationKey(event)
        }
    }

    private func handleApplicationKey(_ event: NSEvent) -> NSEvent? {
        guard shortcuts?.recording == nil else { return event }
        if Shortcut.isSettingsEvent(event) {
            if !event.isARepeat { showSettings() }
            return nil
        }
        if let window = settingsWindow, (event.window ?? NSApp.keyWindow) === window {
            if Shortcut.isEscapeEvent(event) {
                if !event.isARepeat { window.performClose(nil) }
                return nil
            }
            if Shortcut.isPasteEvent(event), let editor = window.firstResponder as? NSTextView, editor.isEditable {
                if !event.isARepeat, !Clipboard.pasteCredential(into: editor) { NSSound.beep() }
                return nil
            }
        }
        return event
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.uninstall()
        if let applicationKeyMonitor { NSEvent.removeMonitor(applicationKeyMonitor) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let window = settingsAwaitingFocus {
            settingsAwaitingFocus = nil
            window.makeKeyAndOrderFront(nil)
        }
        if translationPanel?.isKeyWindow == true { translationHasTakenFocus = true }
    }

    func applicationDidResignActive(_ notification: Notification) {
        shortcuts?.cancelRecording()
        dismissUnpinnedTranslation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = settingsWindow else { return true }
        focusSettings(window)
        return false
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = LucideIcon.menuImage("languages", size: 18)
        item.button?.toolTip = "Luqri"
        item.button?.setAccessibilityLabel("Luqri")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in Command.allCases {
            addItem(command.title, icon: command.icon, action: #selector(runCommand(_:)), to: menu) { entry in
                entry.tag = Int(command.rawValue)
            }
        }
        menu.addItem(.separator())
        addItem("设置…", icon: "settings-2", action: #selector(showSettings), to: menu) { item in
            item.keyEquivalent = ","
            item.keyEquivalentModifierMask = .command
        }
        addItem("退出 Luqri", icon: "log-out", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item
        refreshMenuShortcuts()
    }

    private func refreshMenuShortcuts() {
        guard let shortcuts, let menu = statusItem?.menu else { return }
        for item in menu.items {
            guard let command = Command(rawValue: UInt32(item.tag)) else { continue }
            let binding = shortcuts.binding(for: command)
            item.keyEquivalent = shortcuts.failed.contains(command) ? "" : binding.key
            item.keyEquivalentModifierMask = binding.modifierFlags
        }
    }

    private func buildApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Luqri")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func addItem(
        _ title: String, icon: String, action: Selector, to menu: NSMenu,
        configure: (NSMenuItem) -> Void = { _ in }
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = LucideIcon.menuImage(icon, size: 15)
        item.target = self
        configure(item)
        menu.addItem(item)
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        if let command = Command(rawValue: UInt32(sender.tag)) { perform(command) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func perform(_ command: Command) {
        cancelWork()
        switch command {
        case .translate:
            translateSelection()
        case .recognize:
            recognizeScreenshot { [weak self] text, anchor in
                Clipboard.write(text)
                self?.showFeedback("已复制识别文字", icon: "check", at: anchor)
            }
        case .screenshotTranslate:
            recognizeScreenshot(keepsFocus: true) { [weak self] text, _ in
                self?.showTranslation(text, appearance: NSAppearance(named: .aqua))
            }
        }
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        screenshotCapture.cancelSelection()
        stopOCRProgress()
        clearFeedback()
    }

    private func translateSelection() {
        guard AXIsProcessTrusted() else {
            showTranslation(needsSelectionPermission: true)
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            showTranslation()
            return
        }
        let mouse = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let point = CGPoint(x: mouse.x, y: top - mouse.y)
        work = Task(priority: .userInitiated) { [weak self] in
            let text = await SelectedText.read(from: pid, at: point)
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            let selection = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? text : nil
            self.showTranslation(selection)
        }
    }

    private func recognizeScreenshot(keepsFocus: Bool = false, deliver: @escaping (String, CGPoint) -> Void) {
        let previousApp = keepsFocus ? NSWorkspace.shared.frontmostApplication : nil
        closeTranslation()
        let provider = OCRProvider.selected()
        work = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var anchor = NSEvent.mouseLocation
            defer { if !Task.isCancelled { self.work = nil } }
            do {
                guard let screenshot = try await self.screenshotCapture.capture(keepsFocus: keepsFocus) else { return }
                try Task.checkCancellation()
                let recognitionAnchor = screenshot.anchor
                anchor = recognitionAnchor
                self.ocrProgress = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.showFeedback("正在识别文字…", icon: "scan-text", at: recognitionAnchor, autoHide: false)
                }
                let text = try await provider.recognize(screenshot.image)
                try Task.checkCancellation()
                self.stopOCRProgress()
                deliver(text, anchor)
            } catch ScreenshotCapture.Failure.permissionDenied {
                if !Task.isCancelled { self.showScreenRecordingPermission() }
            } catch {
                guard !Task.isCancelled else { return }
                self.stopOCRProgress()
                ScreenshotCapture.restoreFocus(to: previousApp)
                let message = (error as? LocalizedError)?.errorDescription ?? "截图或识别失败，请重新框选。"
                self.showFeedback(message, icon: "x", at: anchor)
            }
        }
    }

    private func showScreenRecordingPermission() {
        let alert = NSAlert()
        alert.messageText = "允许 Luqri 录制屏幕"
        alert.informativeText = "在系统设置中为 Luqri 启用屏幕录制权限，再重试截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { Permissions.openScreenCapture() }
    }

    private func stopOCRProgress() {
        guard let ocrProgress else { return }
        ocrProgress.cancel()
        self.ocrProgress = nil
        clearFeedback()
    }

    private func showTranslation(
        _ input: String? = nil, needsSelectionPermission: Bool = false, appearance: NSAppearance? = nil
    ) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        settingsAwaitingFocus = nil
        closeTranslation()
        let input = input ?? ""
        let hasInput = input.hasNonWhitespace
        let panel = UtilityPanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.appearance = appearance
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.isMovableByWindowBackground = true
        panel.title = "Luqri 翻译"
        panel.onEscape = { [weak self] in self?.closeTranslation() }
        panel.onEditorReturn = { [weak model] in
            guard let model, !model.enabledProviders.isEmpty,
                  model.text.hasNonWhitespace else { return false }
            model.translate()
            return true
        }
        let view = TranslationView(
            needsSelectionPermission: needsSelectionPermission,
            model: model, isPanelKey: { [weak panel] in panel?.isKeyWindow == true },
            close: { [weak self] in self?.closeTranslation() },
            openSettings: { [weak self] in self?.showSettings() },
            setPinned: { [weak self] pinned in self?.translationPinned = pinned },
            resize: { [weak self, weak panel] size in
                Task { @MainActor in
                    guard let self, let panel, self.translationPanel === panel else { return }
                    self.resizeTranslation(panel, contentSize: size)
                }
            }
        )
        let hosting = NSHostingController(rootView: view.clipShape(RoundedRectangle(cornerRadius: TranslationView.cornerRadius)))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        if hasInput { model.begin(with: input) }
        let size = hosting.sizeThatFits(in: CGSize(width: TranslationView.preferredWidth, height: .greatestFiniteMagnitude))
        if let screen {
            panel.setFrame(translationFrame(contentSize: size, screen: screen.frame, visible: screen.visibleFrame), display: false)
        } else {
            panel.setContentSize(size)
            panel.center()
        }
        translationPanel = panel
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func translationFrame(contentSize: CGSize, screen: CGRect, visible: CGRect) -> CGRect {
        let available = visible.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(contentSize.width, available.width), height: min(contentSize.height, available.height))
        let x = (screen.midX - size.width / 2).rounded()
        let y = (screen.midY + screen.height * 0.12 - size.height / 2).rounded()
        return CGRect(
            x: min(max(x, available.minX), available.maxX - size.width),
            y: min(max(y, available.minY), available.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    private func resizeTranslation(_ panel: UtilityPanel, contentSize: CGSize) {
        guard contentSize.height > 0, abs(panel.frame.height - contentSize.height) >= 1 else { return }
        let frame = panel.frame
        let visible = panel.screen?.visibleFrame.insetBy(dx: 8, dy: 8)
        let height = min(contentSize.height, visible?.height ?? contentSize.height)
        let top = min(frame.maxY, visible?.maxY ?? frame.maxY)
        let bottom = max(top - height, visible?.minY ?? top - height)
        guard abs(frame.height - height) >= 1 else { return }
        panel.setFrame(CGRect(x: frame.minX, y: bottom, width: frame.width, height: height), display: true)
    }

    private func closeTranslation() {
        let panel = translationPanel
        translationPanel = nil
        translationHasTakenFocus = false
        translationPinned = false
        panel?.orderOut(nil)
        model.reset()
    }

    private func dismissUnpinnedTranslation() {
        guard translationHasTakenFocus, !translationPinned, translationPanel?.attachedSheet == nil else { return }
        closeTranslation()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, NSApp.isActive else { return }
        if window === translationPanel { translationHasTakenFocus = true }
        if window === settingsAwaitingFocus { settingsAwaitingFocus = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === translationPanel { dismissUnpinnedTranslation() }
    }

    @objc private func showSettings() {
        guard let shortcuts else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            let controller = NSHostingController(rootView: SettingsView(model: model, shortcuts: shortcuts))
            controller.sizingOptions = []
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: SettingsView.preferredSize),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
            )
            window.contentViewController = controller
            window.initialFirstResponder = controller.view
            window.title = "Luqri 设置"
            window.collectionBehavior = [.managed, .primary]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        let frame = screen.map { settingsFrame(for: window, screen: $0.frame, visible: $0.visibleFrame) }
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        focusSettings(window)
        if let frame, window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }

    private func focusSettings(_ window: NSWindow) {
        settingsAwaitingFocus = window
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive, window.isKeyWindow { settingsAwaitingFocus = nil }
    }

    private func settingsFrame(for window: NSWindow, screen: CGRect, visible: CGRect) -> CGRect {
        let preferred = window.frameRect(forContentRect: CGRect(origin: .zero, size: SettingsView.preferredSize)).size
        let size = CGSize(width: min(preferred.width, visible.width), height: min(preferred.height, visible.height))
        return CGRect(
            x: min(max((screen.midX - size.width / 2).rounded(), visible.minX), visible.maxX - size.width),
            y: min(max((screen.midY - size.height / 2).rounded(), visible.minY), visible.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            shortcuts?.cancelRecording()
            settingsAwaitingFocus = nil
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showFeedback(_ message: String, icon: String, at anchor: CGPoint, autoHide: Bool = true) {
        clearFeedback()
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSHostingView(rootView: FeedbackView(icon: icon, message: message))
        panel.contentView = content
        position(panel, contentSize: content.fittingSize, at: anchor)
        feedbackPanel = panel
        panel.orderFrontRegardless()
        guard autoHide else { return }
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.clearFeedback() }
        }
    }

    private func clearFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        feedbackPanel?.orderOut(nil)
        feedbackPanel = nil
    }

    private func position(_ window: NSWindow, contentSize: CGSize, at anchor: CGPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame.insetBy(dx: 8, dy: 8) else {
            window.setContentSize(contentSize)
            window.center()
            return
        }
        let size = CGSize(width: min(contentSize.width, visible.width), height: min(contentSize.height, visible.height))
        let point = CGPoint(
            x: min(max(anchor.x + 10, visible.minX), visible.maxX - size.width),
            y: min(max(anchor.y - size.height - 12, visible.minY), visible.maxY - size.height)
        )
        window.setFrame(CGRect(origin: point, size: size), display: true)
    }
}
