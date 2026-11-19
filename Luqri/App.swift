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
    private let overlay = SelectionOverlay()
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalShortcuts?
    private var failedShortcuts = Set<Command>()
    private var translationPanel: UtilityPanel?
    private var settingsWindow: NSWindow?
    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var ocrProgress: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shortcuts = GlobalShortcuts { [weak self] command in self?.perform(command) }
        failedShortcuts = shortcuts.install()
        self.shortcuts = shortcuts
        buildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.uninstall()
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
                if !failedShortcuts.contains(command) {
                    entry.keyEquivalent = command.key
                    entry.keyEquivalentModifierMask = [.option, .shift]
                }
            }
        }
        menu.addItem(.separator())
        addItem("设置…", icon: "settings-2", action: #selector(showSettings), to: menu)
        addItem("退出 Luqri", icon: "log-out", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item
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
        case .recognize, .screenshotTranslate:
            startOCR(translate: command == .screenshotTranslate)
        case .clipboardTranslate:
            let anchor = NSEvent.mouseLocation
            work = Task { [weak self] in
                let text = await Clipboard.textAfterSelectionCopy()
                guard let self, !Task.isCancelled else { return }
                self.work = nil
                self.showTranslation(text, at: anchor, missingInput: .clipboard)
            }
        case .inputTranslate:
            showTranslation("", at: NSEvent.mouseLocation)
        }
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        stopOCRProgress()
        overlay.cancel()
        clearFeedback()
    }

    private func translateSelection() {
        let mouse = NSEvent.mouseLocation
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        work = Task { [weak self] in
            var selection = ""
            if let pid, pid != ProcessInfo.processInfo.processIdentifier {
                let lookup = await Task.detached(priority: .userInitiated) { SelectedText.read(from: pid) }.value
                guard !Task.isCancelled else { return }
                switch lookup {
                case .text(let text): selection = text
                case .tryCopy: selection = await Clipboard.copySelection(from: pid) ?? ""
                case .unavailable: break
                }
                guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            self.showTranslation(selection, at: mouse, missingInput: .selection)
        }
    }

    private func startOCR(translate: Bool) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        closeTranslation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "允许 Luqri 录制屏幕"
            alert.informativeText = "在系统设置中为 Luqri 启用屏幕录制权限，再重试截图。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { Permissions.openScreenCapture() }
            return
        }
        overlay.begin { [weak self] selection in
            guard let self else { return }
            if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate()
            }
            guard let selection else { return }
            self.ocrProgress = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.showFeedback("正在识别文字…", icon: "scan-text", at: selection.anchor, autoHide: false)
            }
            self.work = Task(priority: .userInitiated) { [weak self] in
                do {
                    let text = try await ScreenOCR.recognize(selection)
                    guard let self, !Task.isCancelled else { return }
                    self.work = nil
                    self.stopOCRProgress()
                    if translate {
                        self.showTranslation(text, at: selection.anchor)
                    } else {
                        Clipboard.write(text)
                        self.showFeedback("已复制识别文字", icon: "check", at: selection.anchor)
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.work = nil
                    self.stopOCRProgress()
                    let message = (error as? ScreenOCR.Failure)?.errorDescription ?? "截图或识别失败，请重新框选。"
                    self.showFeedback(message, icon: "x", at: selection.anchor)
                }
            }
        }
    }

    private func stopOCRProgress() {
        guard let ocrProgress else { return }
        ocrProgress.cancel()
        self.ocrProgress = nil
        clearFeedback()
    }

    private func showTranslation(_ input: String, at anchor: CGPoint, missingInput: MissingInput? = nil) {
        closeTranslation()
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
            guard let model, !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            model.translate()
            return true
        }
        let view = TranslationView(
            missingInput: hasInput ? nil : missingInput,
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
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = SettingsView(model: model, failedShortcuts: failedShortcuts)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled, .closable]
        window.title = "Luqri 设置"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
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
