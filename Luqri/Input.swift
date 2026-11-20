import AppKit
import Carbon
import Observation
import ApplicationServices

enum Command: UInt32, CaseIterable {
    case translate = 1
    case recognize
    case screenshotTranslate

    var title: String {
        switch self {
        case .translate: "划词翻译"
        case .recognize: "OCR 识别"
        case .screenshotTranslate: "OCR 翻译"
        }
    }

    var icon: String {
        switch self {
        case .translate: "languages"
        case .recognize: "scan-text"
        case .screenshotTranslate: "languages"
        }
    }

    var defaultShortcut: Shortcut {
        let (code, symbol): (Int, String) = switch self {
        case .translate: (kVK_ANSI_D, "d")
        case .recognize: (kVK_ANSI_W, "w")
        case .screenshotTranslate: (kVK_ANSI_S, "s")
        }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(optionKey), key: symbol)
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
        [",", "，"].contains(commandKey(for: event) ?? "")
    }

    static func isEscapeEvent(_ event: NSEvent) -> Bool {
        event.keyCode == kVK_Escape && event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
    }

    static func isPasteEvent(_ event: NSEvent) -> Bool {
        commandKey(for: event) == "v"
    }

    static func commandKey(for event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.control, .option, .shift, .command]) == .command else { return nil }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    var isSettingsShortcut: Bool { key == "," && modifiers == UInt32(cmdKey) }

    var isReservedApplicationShortcut: Bool {
        modifierFlags == .command && [",", "a", "c", "h", "m", "q", "v", "w", "x", "z", "\r"].contains(key)
    }

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
    private static let preferencesKey = "customGlobalShortcuts"
    private static let legacyPreferencesKey = "globalShortcuts"
    private static let legacyDefaultKeyCodes: [Command: UInt32] = [
        .translate: UInt32(kVK_ANSI_T), .recognize: UInt32(kVK_ANSI_O), .screenshotTranslate: UInt32(kVK_ANSI_R)
    ]
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
        bindings = Self.defaultBindings
        let custom = defaults.data(forKey: Self.preferencesKey)
        guard let data = custom ?? defaults.data(forKey: Self.legacyPreferencesKey),
              let stored = try? JSONDecoder().decode([UInt32: Shortcut].self, from: data) else { return }
        for command in Command.allCases {
            guard let shortcut = stored[command.rawValue] else { continue }
            if custom == nil, shortcut.keyCode == Self.legacyDefaultKeyCodes[command],
               shortcut.modifiers == UInt32(optionKey | shiftKey) { continue }
            bindings[command] = shortcut
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
        if shortcut.isReservedApplicationShortcut {
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
            let stored = Dictionary(uniqueKeysWithValues: updated.compactMap { command, shortcut in
                shortcut.usesSameKeys(as: command.defaultShortcut) ? nil : (command.rawValue, shortcut)
            })
            if let data = try? JSONEncoder().encode(stored) {
                defaults.set(data, forKey: Self.preferencesKey)
            }
            message = nil
        }
        onChange()
    }

    private func register(_ bindings: [Command: Shortcut]) -> Set<Command> {
        guard handler != nil else { return Set(Command.allCases) }
        var failed = Set<Command>()
        let custom = Command.allCases.filter { command in
            bindings[command]?.usesSameKeys(as: command.defaultShortcut) == false
        }
        for command in custom + Command.allCases.filter({ !custom.contains($0) }) {
            let shortcut = bindings[command] ?? command.defaultShortcut
            guard !shortcut.isReservedApplicationShortcut else {
                failed.insert(command)
                continue
            }
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
    static func read(from pid: pid_t, at point: CGPoint) async -> String? {
        guard !Task.isCancelled else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = ContinuousClock.now + .milliseconds(450)
        var visited: [AXUIElement] = []

        func search(from start: AXUIElement?) -> String? {
            var current = start
            for _ in 0..<12 {
                guard let node = current, !Task.isCancelled, ContinuousClock.now < deadline,
                      !visited.contains(where: { CFEqual($0, node) }) else { break }
                visited.append(node)
                if attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
                if let text = textSelection(in: node) { return text }
                current = element(node, kAXParentAttribute)
            }
            return nil
        }

        if let text = search(from: element(app, kAXFocusedUIElementAttribute)) { return text }
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return search(from: hit)
    }

    private static func textSelection(in element: AXUIElement) -> String? {
        if let text = attribute(element, kAXSelectedTextAttribute) as? String,
           text.hasNonWhitespace { return text }

        if let range = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var selection = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &selection), selection.length > 0,
               let text = string(in: element, attribute: kAXStringForRangeParameterizedAttribute, range: range) {
                return text
            }
        }

        // Browser and rich-text engines can expose the selection as a text marker range.
        if let range = attribute(element, "AXSelectedTextMarkerRange") {
            return string(in: element, attribute: "AXStringForTextMarkerRange", range: range)
        }
        return nil
    }

    private static func string(in element: AXUIElement, attribute: String, range: CFTypeRef) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, range, &value) == .success,
              let text = value as? String, text.hasNonWhitespace else { return nil }
        return text
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

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
