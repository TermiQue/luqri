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
    private var settingsWindow: NSWindow?
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

    func applicationDidResignActive(_ notification: Notification) {
        shortcuts?.cancelRecording()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = LucideIcon.menuImage("languages", size: 18)
        item.button?.toolTip = "Luqri"
        item.button?.setAccessibilityLabel("Luqri")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in Command.allCases {
            if command == .clipboardTranslate { menu.addItem(.separator()) }
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
            recognizeScreenshot { [weak self] text, anchor in
                self?.showTranslation(text, at: anchor)
            }
        case .clipboardTranslate:
            showTranslation(Clipboard.text, showEmptyClipboardHint: true)
        case .inputTranslate:
            showTranslation()
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
        let anchor = NSEvent.mouseLocation
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            showTranslation(at: anchor)
            return
        }
        work = Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { SelectedText.read(from: pid) }.value
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            let selection = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? text : nil
            self.showTranslation(selection, at: anchor)
        }
    }

    private func recognizeScreenshot(deliver: @escaping (String, CGPoint) -> Void) {
        closeTranslation()
        work = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var anchor = NSEvent.mouseLocation
            defer { if !Task.isCancelled { self.work = nil } }
            do {
                guard let screenshot = try await self.screenshotCapture.capture() else { return }
                try Task.checkCancellation()
                let recognitionAnchor = screenshot.anchor
                anchor = recognitionAnchor
                self.ocrProgress = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.showFeedback("正在识别文字…", icon: "scan-text", at: recognitionAnchor, autoHide: false)
                }
                let text = try await ScreenOCR.recognize(screenshot.image)
                try Task.checkCancellation()
                self.stopOCRProgress()
                deliver(text, anchor)
            } catch ScreenshotCapture.Failure.permissionDenied {
                if !Task.isCancelled { self.showScreenRecordingPermission() }
            } catch {
                guard !Task.isCancelled else { return }
                self.stopOCRProgress()
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
        _ input: String? = nil, at anchor: CGPoint = NSEvent.mouseLocation, showEmptyClipboardHint: Bool = false
    ) {
        closeTranslation()
        let input = input ?? ""
        let hasInput = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let panel = UtilityPanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.title = "Luqri 翻译"
        panel.onEscape = { [weak self] in self?.closeTranslation() }
        panel.onEditorReturn = { [weak model] in
            guard let model, !model.enabledProviders.isEmpty,
                  !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            model.translate()
            return true
        }
        let view = TranslationView(
            showEmptyClipboardHint: !hasInput && showEmptyClipboardHint,
            model: model, startsEditing: !hasInput,
            close: { [weak self] in self?.closeTranslation() },
            openSettings: { [weak self] in self?.showSettings() },
            setPinned: { [weak panel] pinned in panel?.hidesOnDeactivate = !pinned },
            resize: { [weak self, weak panel] size in
                Task { @MainActor in
                    guard let self, let panel, self.translationPanel === panel else { return }
                    self.resizeTranslation(panel, contentSize: size)
                }
            }
        )
        let hosting = NSHostingController(rootView: view.clipShape(RoundedRectangle(cornerRadius: 13)))
        panel.contentViewController = hosting
        model.begin(with: hasInput ? input : "")
        hosting.view.layoutSubtreeIfNeeded()
        position(panel, contentSize: hosting.view.fittingSize, at: anchor)
        translationPanel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
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
        translationPanel?.orderOut(nil)
        translationPanel = nil
        model.reset()
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
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.contentViewController = controller
            window.title = "Luqri 设置"
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let frame, window.frame != frame {
            window.setFrame(frame, display: true)
        }
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
            settingsWindow = nil
        }
    }

    private func showFeedback(_ message: String, icon: String, at anchor: CGPoint, autoHide: Bool = true) {
        clearFeedback()
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
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
