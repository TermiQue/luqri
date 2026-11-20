import AppKit
import ApplicationServices
import SwiftUI

@main
@MainActor
enum LuqriApp {
    static let bundledIcon: NSImage? = {
        guard let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: iconFile, withExtension: nil) else { return nil }
        return NSImage(contentsOf: url)
    }()

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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
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
        let window = event.window ?? NSApp.keyWindow
        if let key = Shortcut.commandKey(for: event) {
            switch key {
            case "w" where canClose(window):
                if !event.isARepeat { closeWindow(window) }
                return nil
            case "m" where window != nil && window === settingsWindow:
                if !event.isARepeat { window?.performMiniaturize(nil) }
                return nil
            case "h":
                if !event.isARepeat { NSApp.hide(nil) }
                return nil
            case "q":
                if !event.isARepeat { quit() }
                return nil
            default: break
            }
        }
        if let window, window === settingsWindow {
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
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
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
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Luqri", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        appMenu.addItem(withTitle: "退出 Luqri", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭", action: #selector(closeFrontWindow), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

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

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(minimizeSettings), keyEquivalent: "m").target = self
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let window = NSApp.keyWindow
        switch menuItem.action {
        case #selector(closeFrontWindow): return canClose(window)
        case #selector(minimizeSettings): return window != nil && window === settingsWindow
        default: return true
        }
    }

    private func canClose(_ window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        return window === settingsWindow || window === translationPanel
    }

    private func closeWindow(_ window: NSWindow?) {
        guard let window else { return }
        if window === translationPanel { closeTranslation() }
        else if window === settingsWindow { window.performClose(nil) }
    }

    @objc private func closeFrontWindow() { closeWindow(NSApp.keyWindow) }

    @objc private func minimizeSettings() {
        if let window = NSApp.keyWindow, window === settingsWindow { window.performMiniaturize(nil) }
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
            captureForOCR { provider, screenshot in
                let text = try await provider.recognize(screenshot.image)
                try Task.checkCancellation()
                Clipboard.write(text)
            }
        case .screenshotTranslate:
            captureForOCR(keepsFocus: true) { [weak self] provider, screenshot in
                self?.showTranslation(appearance: NSAppearance(named: .aqua)) {
                    try await provider.recognize(screenshot.image)
                }
            }
        }
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        screenshotCapture.cancelSelection()
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

    private func captureForOCR(
        keepsFocus: Bool = false, process: @escaping (OCRProvider, Screenshot) async throws -> Void
    ) {
        let previousApp = keepsFocus ? NSWorkspace.shared.frontmostApplication : nil
        closeTranslation()
        let provider = OCRProvider.selected()
        work = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var anchor = NSEvent.mouseLocation
            defer { if !Task.isCancelled { self.work = nil } }
            do {
                guard let screenshot = try await self.screenshotCapture.capture(
                    keepsFocus: keepsFocus, maximumPixelDimension: provider.maximumCaptureDimension
                ) else { return }
                try Task.checkCancellation()
                anchor = screenshot.anchor
                try await process(provider, screenshot)
            } catch ScreenshotCapture.Failure.permissionDenied {
                if !Task.isCancelled { self.showScreenRecordingPermission() }
            } catch {
                guard !Task.isCancelled else { return }
                ScreenshotCapture.restoreFocus(to: previousApp)
                let message = (error as? LocalizedError)?.errorDescription ?? "截图或识别失败，请重新框选。"
                self.showOCRError(message, at: anchor)
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

    private func showTranslation(
        _ input: String? = nil, needsSelectionPermission: Bool = false, appearance: NSAppearance? = nil,
        loadInput: (() async throws -> String)? = nil
    ) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        settingsAwaitingFocus = nil
        closeTranslation()
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
            model: model, focusEditor: { [weak panel] in panel?.focusSourceEditor() },
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
        if let loadInput {
            model.loadInput(loadInput)
        } else if let input, input.hasNonWhitespace {
            model.begin(with: input)
        }
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
        panel?.contentViewController = nil
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
            window.collectionBehavior = [.managed, .primary, .moveToActiveSpace]
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
        if NSApp.activationPolicy() != .regular, NSApp.setActivationPolicy(.regular) {
            let tile = NSApp.dockTile
            let icon = NSImageView(frame: CGRect(origin: .zero, size: tile.size))
            if let artwork = LuqriApp.bundledIcon { NSApp.applicationIconImage = artwork }
            icon.image = NSApp.applicationIconImage
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.autoresizingMask = [.width, .height]
            tile.contentView = icon
            tile.display()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive {
            if window.isKeyWindow { settingsAwaitingFocus = nil }
        } else {
            // A status menu action may run while another application still owns activation.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
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
            settingsAwaitingFocus = nil
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
            NSApp.dockTile.contentView = nil
            NSApp.applicationIconImage = nil
        }
    }

    private func showOCRError(_ message: String, at anchor: CGPoint) {
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
        let content = NSHostingView(rootView: OCRErrorView(message: message))
        panel.contentView = content
        position(panel, contentSize: content.fittingSize, at: anchor)
        feedbackPanel = panel
        panel.orderFrontRegardless()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.clearFeedback() }
        }
    }

    private func clearFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        feedbackPanel?.orderOut(nil)
        feedbackPanel?.contentView = nil
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
