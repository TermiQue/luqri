import AppKit
import Darwin
import ImageIO
import SwiftUI

@main
@MainActor
enum LuqriApp {
    static func loadAppIcon(size: NSSize) -> NSImage? {
        guard let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: iconFile, withExtension: nil),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let pixelSize = max(1, Int(ceil(max(size.width, size.height) * 2)))
        var index = 0
        var bestWidth = Int.max
        for candidate in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, candidate, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  width >= pixelSize, width < bestWidth else { continue }
            index = candidate
            bestWidth = width
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: pixelSize] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let application = NSApplication.shared
        let frontend = CommandLine.arguments.dropFirst().first == WindowProcess.launchArgument
        let channel = frontend ? WindowChannel(input: .standardInput, output: .standardOutput) : nil
        let delegate = AppController(frontendChannel: channel)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let frontendChannel: WindowChannel?
    private lazy var model = TranslationModel { [weak self] job in
        guard let self else { throw CancellationError() }
        let reply = try await self.request(.translate(text: job.text, provider: job.provider,
                                                       source: job.source, target: job.target))
        guard let text = reply.text else { throw CloudFailure("翻译服务未返回译文。") }
        return text
    }
    private lazy var screenshotCapture = ScreenshotCapture()
    private lazy var settingsPermissions = SettingsPermissions()
    private lazy var selectedOCR = OCRProvider.selected()
    private var frontendProcess: WindowProcess?
    private var frontendRequests: [UUID: CheckedContinuation<WindowResult, any Error>] = [:]
    private var coreRequests: [UUID: Task<Void, Never>] = [:]
    private var pendingOCR: (id: UUID, provider: OCRProvider, screenshot: Screenshot)?
    private var frontendExiting = false
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalShortcuts?
    private var applicationKeyMonitor: Any?
    private var ocrUsageTracking: Task<Void, Never>?
    private var translationPanel: UtilityPanel?
    private var translationScreenshot: UUID?
    private var translationResize: Task<Void, Never>?
    private var pendingTranslationSize: CGSize?
    private var translationHasTakenFocus = false
    private var translationPinned = false
    private var settingsWindow: NSWindow?
    private weak var settingsAwaitingFocus: NSWindow?
    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var permissionPrompt: PermissionPrompt?

    init(frontendChannel: WindowChannel?) {
        self.frontendChannel = frontendChannel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildApplicationMenu()
        applicationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleApplicationKey(event)
        }

        if let frontendChannel {
            shortcuts = GlobalShortcuts(action: { _ in }, sendEdit: { [weak frontendChannel] edit in
                frontendChannel?.send(.shortcutEdit(edit))
            })
            frontendChannel.start(receive: { [weak self] message in
                self?.handleFrontendMessage(message)
            }, disconnect: { [weak self] in
                self?.exitFrontend()
            })
        } else {
            let shortcuts = GlobalShortcuts(
                action: { [weak self] command in self?.perform(command) },
                onChange: { [weak self] in self?.shortcutsChanged() }
            )
            self.shortcuts = shortcuts
            shortcuts.install()
            buildMenu()
            scheduleOCRUsageTracking()
        }
    }

    private func openFrontend(_ message: WindowMessage, id: UUID) {
        do {
            let session: WindowProcess
            if let frontendProcess {
                session = frontendProcess
            } else {
                guard let executable = Bundle.main.executableURL else {
                    throw CloudFailure("找不到 Luqri 界面程序。")
                }
                session = try WindowProcess(executable: executable)
                frontendProcess = session
                session.channel.start(receive: { [weak self, weak session] message in
                    guard let self, let session, self.frontendProcess === session else { return }
                    self.handleCoreMessage(message, session: session)
                }, disconnect: { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.frontendDisconnected(session)
                })
                if let shortcuts { session.channel.send(.shortcuts(shortcuts.snapshot)) }
                sendPermissionStatus(to: session)
            }
            session.opening.append((id, message))
            if !session.closing { session.channel.send(message) }
        } catch {
            pendingOCR = nil
            showOCRError("无法打开 Luqri 界面。\(error.localizedDescription)", at: NSEvent.mouseLocation)
        }
    }

    private func frontendDisconnected(_ session: WindowProcess) {
        guard frontendProcess === session else { return }
        frontendProcess = nil
        session.channel.close()
        for task in coreRequests.values { task.cancel() }
        coreRequests.removeAll()
        shortcuts?.resumeAfterRemoteRecording()

        if session.closing, session.mayRetryOpening, !session.opening.isEmpty {
            for opening in session.opening { openFrontend(opening.message, id: opening.id) }
            frontendProcess?.mayRetryOpening = false
        } else {
            pendingOCR = nil
            if !session.opening.isEmpty {
                showOCRError("无法打开 Luqri 界面，请重试。", at: NSEvent.mouseLocation)
            }
        }
    }

    private func handleCoreMessage(_ message: WindowMessage, session: WindowProcess) {
        switch message {
        case .opened(let id): session.opening.removeAll { $0.id == id }
        case .closing: session.closing = true
        case .discardScreenshot(let id):
            if pendingOCR?.id == id { pendingOCR = nil }
        case .quit: quit()
        case .shortcutEdit(let edit): shortcuts?.perform(edit)
        case .refreshPermissions: sendPermissionStatus(to: session)
        case .requestPermission(let permission): showPermissionPrompt(permission)
        case .credentialsChanged(let account):
            if account == .volcengine { scheduleOCRUsageTracking() }
        case .ocrChanged(let provider): selectedOCR = provider
        case .request(let id, let operation):
            guard coreRequests[id] == nil else { return }
            coreRequests[id] = Task { [weak self, weak session] in
                guard let self else { return }
                let reply: WindowResult
                do {
                    reply = try await self.perform(operation)
                } catch {
                    reply = WindowResult(error: error.localizedDescription)
                }
                guard !Task.isCancelled, let session, self.frontendProcess === session else { return }
                self.coreRequests[id] = nil
                session.channel.send(.result(id, reply))
            }
        case .cancel(let id): coreRequests.removeValue(forKey: id)?.cancel()
        default: break
        }
    }

    private func perform(_ operation: WindowOperation) async throws -> WindowResult {
        try Task.checkCancellation()
        switch operation {
        case .translate(let text, let provider, let source, let target):
            let job = TranslationJob(text: text, provider: provider, source: source, target: target)
            switch provider {
            case .volcengine: return WindowResult(text: try await Volcengine.translate(job))
            case .aliyun: return WindowResult(text: try await Aliyun.translate(job))
            case .apple: throw CloudFailure("Apple 翻译需要翻译窗口。")
            }
        case .recognize(let id):
            guard let pendingOCR, pendingOCR.id == id else { throw CancellationError() }
            self.pendingOCR = nil
            let text = try await pendingOCR.provider.recognize(pendingOCR.screenshot.takeImage())
            return WindowResult(text: text)
        case .usage(let meter, let forceRefresh):
            let usage = try await meter.read(meter.account.load(), forceRefresh: forceRefresh)
            return WindowResult(used: usage.used, note: usage.note)
        }
    }

    private func handleFrontendMessage(_ message: WindowMessage) {
        guard !frontendExiting else { return }
        switch message {
        case .showSettings(let id):
            showSettings()
            frontendChannel?.send(.opened(id))
        case .showTranslation(let id, let input, let screenshot):
            if let screenshot {
                showTranslation(appearance: NSAppearance(named: .aqua), screenshot: screenshot) { [weak self] in
                    guard let self else { throw CancellationError() }
                    let reply = try await self.request(.recognize(screenshot))
                    guard let text = reply.text else { throw OCRFailure.noText }
                    return text
                }
            } else {
                showTranslation(input)
            }
            frontendChannel?.send(.opened(id))
        case .closeTranslation: closeTranslation()
        case .quit: exitFrontend()
        case .shortcuts(let snapshot): shortcuts?.update(from: snapshot)
        case .permissions(let granted): settingsPermissions.granted = granted
        case .result(let id, let result):
            guard let pending = frontendRequests.removeValue(forKey: id) else { return }
            if let error = result.error { pending.resume(throwing: CloudFailure(error)) }
            else { pending.resume(returning: result) }
        default: break
        }
    }

    private func request(_ operation: WindowOperation) async throws -> WindowResult {
        guard let frontendChannel, !frontendExiting else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                frontendRequests[id] = continuation
                frontendChannel.send(.request(id, operation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let pending = self.frontendRequests.removeValue(forKey: id) else { return }
                pending.resume(throwing: CancellationError())
                self.frontendChannel?.send(.cancel(id))
            }
        }
    }

    private func sendPermissionStatus(to session: WindowProcess) {
        session.channel.send(.permissions(Set(AppPermission.allCases.filter(\.isGranted))))
    }

    private func shortcutsChanged() {
        refreshMenuShortcuts()
        if let shortcuts { frontendProcess?.channel.send(.shortcuts(shortcuts.snapshot)) }
    }

    private func exitFrontendIfIdle() {
        guard frontendChannel != nil, translationPanel == nil, settingsWindow == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.translationPanel == nil, self.settingsWindow == nil else { return }
            self.exitFrontend()
        }
    }

    private func exitFrontend() {
        guard let frontendChannel, !frontendExiting else { return }
        frontendExiting = true
        for continuation in frontendRequests.values { continuation.resume(throwing: CancellationError()) }
        frontendRequests.removeAll()
        frontendChannel.send(.closing)
        frontendChannel.close {
            NSApp.terminate(nil)
        }
    }

    private func scheduleOCRUsageTracking() {
        ocrUsageTracking?.cancel()
        ocrUsageTracking = nil
        guard let credentials = try? CloudAccount.volcengine.load() else { return }
        ocrUsageTracking = Task(priority: .utility) {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                _ = try? await VolcengineOCR.usage.read(credentials)
                try? await clock.sleep(for: .seconds(3_600), tolerance: .seconds(60))
            }
        }
    }

    private func handleApplicationKey(_ event: NSEvent) -> NSEvent? {
        guard shortcuts?.recording == nil else { return event }
        if Shortcut.isSettingsEvent(event) {
            if !event.isARepeat { showSettings() }
            return nil
        }
        let window = event.window ?? NSApp.keyWindow
        if permissionPrompt?.containsWindow(window) == true, Shortcut.isEscapeEvent(event) {
            if !event.isARepeat { permissionPrompt?.dismiss() }
            return nil
        }
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
        ocrUsageTracking?.cancel()
        if let session = frontendProcess {
            session.channel.send(.quit)
            session.channel.close()
        }
        shortcuts?.uninstall()
        if let applicationKeyMonitor { NSEvent.removeMonitor(applicationKeyMonitor) }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if frontendChannel == nil { screenshotCapture.invalidateContentFilter() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let window = settingsAwaitingFocus {
            settingsAwaitingFocus = nil
            window.makeKeyAndOrderFront(nil)
        }
        if let panel = translationPanel, !translationHasTakenFocus {
            panel.makeKeyAndOrderFront(nil)
            if panel.isKeyWindow { translationHasTakenFocus = true }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        shortcuts?.cancelRecording()
        dismissUnpinnedTranslation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if translationPanel != nil, !translationHasTakenFocus { return false }
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
        menu.delegate = self
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let icon = item.representedObject as? String else { continue }
            item.image = LucideIcon.menuImage(icon, size: 15)
            item.representedObject = nil
        }
        menu.delegate = nil
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
        return window === settingsWindow || window === translationPanel || permissionPrompt?.containsWindow(window) == true
    }

    private func closeWindow(_ window: NSWindow?) {
        guard let window else { return }
        if window === translationPanel { closeTranslation() }
        else if window === settingsWindow { window.performClose(nil) }
        else if permissionPrompt?.containsWindow(window) == true { permissionPrompt?.dismiss() }
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
        item.representedObject = icon
        item.target = self
        configure(item)
        menu.addItem(item)
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        if let command = Command(rawValue: UInt32(sender.tag)) { perform(command) }
    }

    @objc private func quit() {
        if let frontendChannel { frontendChannel.send(.quit) }
        else { NSApp.terminate(nil) }
    }

    private func perform(_ command: Command) {
        cancelWork()
        switch command {
        case .translate:
            translateSelection()
        case .recognize:
            captureForOCR { provider, screenshot in
                let text = try await provider.recognize(screenshot.takeImage())
                try Task.checkCancellation()
                Clipboard.write(text)
            }
        case .screenshotTranslate:
            captureForOCR(keepsFocus: true) { [weak self] provider, screenshot in
                guard let self else { return }
                let id = UUID()
                self.pendingOCR = (id, provider, screenshot)
                self.openFrontend(.showTranslation(id, input: nil, screenshot: id), id: id)
            }
        }
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        pendingOCR = nil
        screenshotCapture.cancelSelection()
        clearFeedback()
    }

    private func translateSelection() {
        guard AppPermission.accessibility.isGranted else {
            showPermissionPrompt(.accessibility) { [weak self] in self?.showTranslation() }
            return
        }
        closePermissionPrompt()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier,
              pid != frontendProcess?.process.processIdentifier else {
            showTranslation()
            return
        }
        let mouse = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let point = CGPoint(x: mouse.x, y: top - mouse.y)
        work = Task(priority: .userInitiated) { [weak self] in
            let text: String?
            switch await SelectedText.read(from: pid, at: point) {
            case let .text(selection): text = selection
            case .unavailable: text = await Clipboard.copySelection(from: pid)
            case .protected: text = nil
            }
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            let selection = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? text : nil
            self.showTranslation(selection)
        }
    }

    private func captureForOCR(
        keepsFocus: Bool = false, process: @escaping (OCRProvider, Screenshot) async throws -> Void
    ) {
        guard AppPermission.screenRecording.isGranted else {
            showPermissionPrompt(.screenRecording)
            return
        }
        closePermissionPrompt()
        let previousApp = keepsFocus ? NSWorkspace.shared.frontmostApplication : nil
        frontendProcess?.channel.send(.closeTranslation)
        let provider = selectedOCR
        work = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var anchor = NSEvent.mouseLocation
            defer { if !Task.isCancelled { self.work = nil } }
            do {
                guard let screenshot = try await self.screenshotCapture.capture(
                    keepsFocus: keepsFocus, maximumPixelDimension: provider.maximumCaptureDimension,
                    excluding: self.frontendProcess?.process.processIdentifier
                ) else { return }
                try Task.checkCancellation()
                anchor = screenshot.anchor
                try await process(provider, screenshot)
            } catch ScreenshotCapture.Failure.permissionDenied {
                if !Task.isCancelled { self.showPermissionPrompt(.screenRecording) }
            } catch is CancellationError {
                if !Task.isCancelled { ScreenshotCapture.restoreFocus(to: previousApp) }
            } catch {
                guard !Task.isCancelled else { return }
                ScreenshotCapture.restoreFocus(to: previousApp)
                let message = (error as? LocalizedError)?.errorDescription ?? "截图或识别失败，请重新框选。"
                self.showOCRError(message, at: anchor)
            }
        }
    }

    private func showPermissionPrompt(_ permission: AppPermission, onLater: (() -> Void)? = nil) {
        if let prompt = permissionPrompt, prompt.permission == permission {
            if let onLater { prompt.onLater = onLater }
            prompt.present()
            return
        }
        closePermissionPrompt()
        let prompt = PermissionPrompt(permission: permission)
        prompt.onLater = onLater
        prompt.onDismiss = { [weak self] in self?.permissionPrompt = nil }
        permissionPrompt = prompt
        prompt.present()
    }

    private func closePermissionPrompt() {
        permissionPrompt?.close()
        permissionPrompt = nil
    }

    private func showTranslation(
        _ input: String? = nil, appearance: NSAppearance? = nil, screenshot: UUID? = nil,
        loadInput: (() async throws -> String)? = nil
    ) {
        guard frontendChannel != nil else {
            let id = UUID()
            openFrontend(.showTranslation(id, input: input, screenshot: nil), id: id)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        settingsAwaitingFocus = nil
        closeTranslation(checkForExit: false)
        let panel = UtilityPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.appearance = appearance
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.delegate = self
        panel.title = "Luqri 翻译"
        panel.onEscape = { [weak self] in self?.closeTranslation() }
        panel.onEditorReturn = { [weak model = model] in
            guard let model, !model.enabledProviders.isEmpty,
                  model.hasText else { return false }
            model.translate()
            return true
        }
        let view = TranslationView(
            model: model, availableHeight: screen?.visibleFrame.insetBy(dx: 8, dy: 8).height ?? .greatestFiniteMagnitude,
            focusEditor: { [weak panel] in panel?.focusSourceEditor() },
            close: { [weak self] in self?.closeTranslation() },
            openSettings: { [weak self] in
                guard let self else { return }
                self.showSettings()
                self.closeTranslation()
            },
            setPinned: { [weak self, weak panel] pinned in
                self?.translationPinned = pinned
                panel?.level = pinned ? .floating : .normal
            },
            resize: { [weak self, weak panel] size in
                guard let panel else { return }
                self?.scheduleTranslationResize(panel, size: size)
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
        let size = hosting.sizeThatFits(in: CGSize(width: TranslationView.preferredWidth, height: 0))
        if let screen {
            panel.setFrame(translationFrame(contentSize: size, screen: screen.frame, visible: screen.visibleFrame), display: false)
        } else {
            panel.setContentSize(size)
            panel.center()
        }
        translationPanel = panel
        translationScreenshot = screenshot
        panel.orderFrontRegardless()
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

    private func scheduleTranslationResize(_ panel: UtilityPanel, size: CGSize) {
        if let translationPanel, translationPanel !== panel { return }
        pendingTranslationSize = size
        guard translationResize == nil else { return }
        translationResize = Task { @MainActor [weak self, weak panel] in
            guard !Task.isCancelled, let self else { return }
            self.translationResize = nil
            let size = self.pendingTranslationSize
            self.pendingTranslationSize = nil
            guard let panel, let size, self.translationPanel === panel else { return }
            self.resizeTranslation(panel, contentSize: size)
        }
    }

    private func resizeTranslation(_ panel: UtilityPanel, contentSize: CGSize) {
        guard contentSize.height > 0, abs(panel.frame.height - contentSize.height) >= 1 else { return }
        let frame = panel.frame
        let visible = panel.screen?.visibleFrame.insetBy(dx: 8, dy: 8)
        let height = min(contentSize.height, visible?.height ?? contentSize.height)
        let top = min(frame.maxY, visible?.maxY ?? frame.maxY)
        let bottom = max(top - height, visible?.minY ?? top - height)
        guard abs(frame.height - height) >= 1 else { return }
        panel.setFrame(CGRect(x: frame.minX, y: bottom, width: frame.width, height: height), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func closeTranslation(checkForExit: Bool = true) {
        translationResize?.cancel()
        translationResize = nil
        pendingTranslationSize = nil
        let panel = translationPanel
        translationPanel = nil
        if let translationScreenshot {
            frontendChannel?.send(.discardScreenshot(translationScreenshot))
            self.translationScreenshot = nil
        }
        translationHasTakenFocus = false
        translationPinned = false
        panel?.delegate = nil
        panel?.close()
        panel?.contentViewController = nil
        if panel != nil { model.reset() }
        if checkForExit { exitFrontendIfIdle() }
    }

    private func dismissUnpinnedTranslation() {
        guard translationHasTakenFocus, !translationPinned, translationPanel?.attachedSheet == nil else { return }
        closeTranslation()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === translationPanel { translationHasTakenFocus = true }
        if window === settingsAwaitingFocus, NSApp.isActive { settingsAwaitingFocus = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === translationPanel { dismissUnpinnedTranslation() }
    }

    @objc private func showSettings() {
        guard let frontendChannel else {
            let id = UUID()
            openFrontend(.showSettings(id), id: id)
            return
        }
        guard let shortcuts else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = autoreleasepool {
                let controller = NSHostingController(rootView: SettingsView(
                    model: model, shortcuts: shortcuts,
                    credentialsChanged: { frontendChannel.send(.credentialsChanged($0)) },
                    ocrChanged: { frontendChannel.send(.ocrChanged($0)) },
                    permissions: settingsPermissions,
                    refreshPermissions: { frontendChannel.send(.refreshPermissions) },
                    requestPermission: { frontendChannel.send(.requestPermission($0)) },
                    readUsage: { [weak self] meter, forceRefresh in
                        guard let self else { throw CancellationError() }
                        let reply = try await self.request(.usage(meter, forceRefresh: forceRefresh))
                        guard let used = reply.used else { throw CloudFailure("云服务未返回用量。") }
                        return (used, reply.note)
                    }
                ))
                controller.sizingOptions = []
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: SettingsView.preferredSize),
                    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true
                )
                window.contentViewController = controller
                window.initialFirstResponder = controller.view
                window.title = "Luqri 设置"
                window.collectionBehavior = [.managed, .primary, .moveToActiveSpace]
                window.isReleasedWhenClosed = false
                window.delegate = self
                return window
            }
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
        if NSApp.isActive {
            if window.isKeyWindow { settingsAwaitingFocus = nil }
        } else {
            NSRunningApplication.current.activate()
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
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        shortcuts?.cancelRecording()
        settingsAwaitingFocus = nil
        settingsWindow = nil
        window.delegate = nil
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.contentView = nil
        NSApp.setActivationPolicy(.accessory)
        exitFrontendIfIdle()
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
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let icon = LucideIcon.menuImage("x", size: 16).map(NSImageView.init(image:))
        let content = NSStackView(views: icon.map { [$0, label] } ?? [label])
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.layer?.cornerRadius = 9
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
        feedbackPanel?.close()
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
