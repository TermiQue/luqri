import AppKit
import Carbon
import Observation
import ApplicationServices

enum Command: UInt32, CaseIterable, Codable {
    case translate = 1
    case recognize
    case screenshotTranslate
    case clipboardTranslate
    case inputTranslate

    var title: String {
        switch self {
        case .translate: "划词翻译"
        case .recognize: "截图识别并复制"
        case .screenshotTranslate: "截图翻译"
        case .clipboardTranslate: "翻译剪贴板"
        case .inputTranslate: "输入文字翻译"
        }
    }

    var icon: String {
        switch self {
        case .translate: "languages"
        case .recognize: "scan-text"
        case .screenshotTranslate: "languages"
        case .clipboardTranslate: "clipboard-paste"
        case .inputTranslate: "keyboard"
        }
    }

    var key: String {
        switch self {
        case .translate: "t"
        case .recognize: "o"
        case .screenshotTranslate: "r"
        case .clipboardTranslate: "v"
        case .inputTranslate: "a"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .translate: UInt32(kVK_ANSI_T)
        case .recognize: UInt32(kVK_ANSI_O)
        case .screenshotTranslate: UInt32(kVK_ANSI_R)
        case .clipboardTranslate: UInt32(kVK_ANSI_V)
        case .inputTranslate: UInt32(kVK_ANSI_A)
        }
    }

    var defaultShortcut: Shortcut {
        Shortcut(keyCode: keyCode, modifiers: UInt32(optionKey | shiftKey), key: key)
    }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let unshifted = flags.contains(.shift) ? event.characters(byApplyingModifiers: []) : nil
        let characters = Self.isSettingsEvent(event) ? "," : unshifted ?? event.charactersIgnoringModifiers
        guard let key = characters?.lowercased(), key.count == 1, event.keyCode != kVK_Escape else { return nil }
        var modifiers = UInt32(0)
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
    }

    static func isSettingsEvent(_ event: NSEvent) -> Bool {
        hasCommandOnly(event) && [",", "，"].contains(event.charactersIgnoringModifiers ?? "")
    }

    static func isPasteEvent(_ event: NSEvent) -> Bool {
        hasCommandOnly(event) && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private static func hasCommandOnly(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.control, .option, .shift, .command]) == .command
    }

    var isSettingsShortcut: Bool { key == "," && modifiers == UInt32(cmdKey) }

    func usesSameKeys(as other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var label: String {
        let flags = modifierFlags
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix + keyLabel
    }

    private var keyLabel: String {
        switch key {
        case " ": return "空格"
        case "\t": return "⇥"
        case "\r", "\u{3}": return "↩"
        case "\u{7f}": return "⌫"
        case "\u{f700}": return "↑"
        case "\u{f701}": return "↓"
        case "\u{f702}": return "←"
        case "\u{f703}": return "→"
        default:
            if let value = key.unicodeScalars.first?.value, (0xF704...0xF726).contains(value) {
                return "F\(value - 0xF703)"
            }
            return key.uppercased()
        }
    }
}

@MainActor
@Observable
final class GlobalShortcuts {
    private static let signature: OSType = 0x4C555152
    private static let preferencesKey = "globalShortcuts"
    private static let defaultBindings = Dictionary(uniqueKeysWithValues: Command.allCases.map { ($0, $0.defaultShortcut) })

    private let defaults: UserDefaults
    private let action: (Command) -> Void
    private let onChange: () -> Void
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var references: [EventHotKeyRef] = []
    @ObservationIgnored private var recorder: Any?
    private var bindings: [Command: Shortcut]
    private(set) var failed = Set<Command>()
    private(set) var recording: Command?
    private(set) var message: String?

    init(defaults: UserDefaults = .standard, action: @escaping (Command) -> Void, onChange: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.action = action
        self.onChange = onChange
        if let data = defaults.data(forKey: Self.preferencesKey),
           let stored = try? JSONDecoder().decode([Command: Shortcut].self, from: data) {
            bindings = Self.defaultBindings.merging(stored) { _, new in new }
        } else {
            bindings = Self.defaultBindings
        }
    }

    func binding(for command: Command) -> Shortcut {
        bindings[command] ?? command.defaultShortcut
    }

    func install() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard result == noErr, let command = Command(rawValue: identifier.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                return MainActor.assumeIsolated {
                    guard identifier.signature == GlobalShortcuts.signature else { return OSStatus(eventNotHandledErr) }
                    let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                    if shortcuts.recording == nil { shortcuts.action(command) }
                    return noErr
                }
            },
            1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        failed = status == noErr ? register(bindings) : Set(Command.allCases)
    }

    func beginRecording(_ command: Command, in window: NSWindow?) {
        guard let window else { return }
        if recording == command {
            cancelRecording()
            return
        }
        stopRecording()
        unregister()
        recording = command
        message = nil
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if event.isARepeat { return nil }
            if event.keyCode == kVK_Escape {
                self.cancelRecording()
            } else if let shortcut = Shortcut(event: event) {
                self.assign(shortcut, to: command)
            } else {
                self.message = "请按住 ⌘、⌥ 或 ⌃，再按一个键。"
            }
            return nil
        }
        if recorder == nil {
            cancelRecording()
            message = "无法录制快捷键，请重试。"
        }
    }

    func cancelRecording() {
        guard recording != nil else { return }
        stopRecording()
        failed = register(bindings)
        message = nil
        onChange()
    }

    func assign(_ shortcut: Shortcut, to command: Command) {
        if shortcut.isSettingsShortcut {
            message = "⌘, 已用于打开设置，请选用其他组合。"
            return
        }
        if shortcut.modifierFlags == .command && ["a", "c", "v", "x", "z", "\r"].contains(shortcut.key) {
            message = "该组合用于应用内操作，请选用其他组合。"
            return
        }
        if let other = Command.allCases.first(where: { $0 != command && binding(for: $0).usesSameKeys(as: shortcut) }) {
            message = "该组合已用于「\(other.title)」。"
            return
        }
        var updated = bindings
        updated[command] = shortcut
        apply(updated, checking: [command])
    }

    func restoreDefaults() {
        apply(Self.defaultBindings, checking: Set(Command.allCases))
    }

    func uninstall() {
        stopRecording()
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func apply(_ updated: [Command: Shortcut], checking required: Set<Command>) {
        stopRecording()
        unregister()
        let conflicts = register(updated)
        if let conflict = Command.allCases.first(where: { conflicts.contains($0) && (required.contains($0) || !failed.contains($0)) }) {
            unregister()
            failed = register(bindings)
            message = "「\(conflict.title)」的快捷键不可用，已保留原设置。"
        } else {
            bindings = updated
            failed = conflicts
            if let data = try? JSONEncoder().encode(updated) {
                defaults.set(data, forKey: Self.preferencesKey)
            }
            message = nil
        }
        onChange()
    }

    private func register(_ bindings: [Command: Shortcut]) -> Set<Command> {
        guard handler != nil else { return Set(Command.allCases) }
        var failed = Set<Command>()
        for command in Command.allCases {
            let shortcut = bindings[command] ?? command.defaultShortcut
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.rawValue)
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                             GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if result == noErr, let reference { references.append(reference) }
            else { failed.insert(command) }
        }
        return failed
    }

    private func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = nil
    }
}

enum SelectedText {
    enum Lookup: Sendable {
        case text(String), tryCopy, unavailable
    }

    static func read(from pid: pid_t) -> Lookup {
        guard AXIsProcessTrusted() else { return .unavailable }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.18)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return .tryCopy }

        var current = focused
        var hasEmptyRange = false
        for depth in 0..<4 {
            if let subrole = attribute(current, kAXSubroleAttribute) as? String,
               subrole == kAXSecureTextFieldSubrole { return .unavailable }
            if let text = attribute(current, kAXSelectedTextAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }

            if let range = attribute(current, kAXSelectedTextRangeAttribute),
               CFGetTypeID(range) == AXValueGetTypeID() {
                var selection = CFRange()
                if AXValueGetValue(range as! AXValue, .cfRange, &selection), selection.length == 0, depth == 0 {
                    hasEmptyRange = true
                }
                if selection.length > 0 {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyParameterizedAttributeValue(
                        current, kAXStringForRangeParameterizedAttribute as CFString, range, &value
                    )
                    if status == .success, let text = value as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
                }
            }
            guard let parent = element(current, kAXParentAttribute) else { break }
            current = parent
        }
        return hasEmptyRange ? .unavailable : .tryCopy
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

@MainActor
enum Clipboard {
    private static var selectionCopy: Task<String?, Never>?

    static var text: String { NSPasteboard.general.string(forType: .string) ?? "" }

    static func credentialText(from pasteboard: NSPasteboard = .general) -> String? {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func pasteCredential(into editor: NSTextView, from pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = credentialText(from: pasteboard) else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    static func textAfterSelectionCopy() async -> String {
        _ = await selectionCopy?.value
        return text
    }

    static func copySelection(from pid: pid_t) async -> String? {
        while let selectionCopy { _ = await selectionCopy.value }
        guard !Task.isCancelled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return nil }

        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot(pasteboard) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let copy = Task<String?, Never> {
            defer { selectionCopy = nil }
            guard pasteboard.changeCount == snapshot.changeCount,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            down.postToPid(pid)
            up.postToPid(pid)
            let deadline = ContinuousClock.now + .milliseconds(240)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(15))
                let count = pasteboard.changeCount
                guard count != snapshot.changeCount else { continue }
                guard count == snapshot.changeCount + 1,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
                let copied = pasteboard.string(forType: .string)
                guard pasteboard.changeCount == count else { return nil }
                snapshot.restore(to: pasteboard, replacing: count)
                guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return copied
            }
            return nil
        }
        selectionCopy = copy
        return await copy.value
    }

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

@MainActor
struct PasteboardSnapshot {
    let changeCount: Int
    private let items: [NSPasteboardItem]

    init?(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        var bytes = 0
        var copies: [NSPasteboardItem] = []
        let transientTypes: Set<NSPasteboard.PasteboardType> = [
            .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
            .init("org.nspasteboard.AutoGeneratedType"), .init("com.apple.pasteboard.promised-file-url"),
            .init("com.apple.pasteboard.promised-file-content-type")
        ]
        for original in pasteboard.pasteboardItems ?? [] {
            let types = original.types
            guard !types.isEmpty, transientTypes.isDisjoint(with: types) else { return nil }
            let copy = NSPasteboardItem()
            for type in types {
                guard let data = original.data(forType: type), data.count <= 8 * 1024 * 1024 - bytes,
                      copy.setData(data, forType: type) else { return nil }
                bytes += data.count
            }
            copies.append(copy)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        items = copies
    }

    func restore(to pasteboard: NSPasteboard, replacing count: Int) {
        guard pasteboard.changeCount == count else { return }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
