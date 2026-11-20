import AppKit
import Carbon
import Observation
import ApplicationServices
import OSLog

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
    enum Result {
        case text(String), unavailable, protected
    }

    static func read(from pid: pid_t, at point: CGPoint) async -> Result {
        guard !Task.isCancelled else { return .protected }
        var query = SelectionQuery(pid: pid)
        if let selection = query.read(at: point) { return .text(selection) }
        return query.encounteredSecureField ? .protected : .unavailable
    }
}

private struct SelectionQuery {
    private static let messageTimeout: Float = 0.15
    private static let selectionAttributes = [
        kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXSelectedTextRangesAttribute, "AXSelectedTextMarkerRange"
    ]

    let pid: pid_t
    private let deadline = ContinuousClock.now + .milliseconds(450)
    private var visited: Set<AXUIElement> = []
    private(set) var encounteredSecureField = false

    init(pid: pid_t) { self.pid = pid }

    private var canQuery: Bool { !Task.isCancelled && ContinuousClock.now < deadline }

    mutating func read(at point: CGPoint) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messageTimeout)
        let system = AXUIElementCreateSystemWide()
        let focus = element(app, kAXFocusedUIElementAttribute)
        if let focus {
            guard !isSecure(focus) else { return nil }
            visited.insert(focus)
            if let text = textSelection(in: focus) { return text }
        }

        let systemFocus = element(system, kAXFocusedUIElementAttribute)
        if let systemFocus, visited.insert(systemFocus).inserted {
            guard !isSecure(systemFocus) else { return nil }
            if let text = textSelection(in: systemFocus) { return text }
        }

        let hit = element(at: point, in: app) ?? element(at: point, in: system)
        if let hit {
            guard !isSecure(hit) else { return nil }
            if visited.insert(hit).inserted, let text = textSelection(in: hit) { return text }
        }

        // Probe the hit path and focus path together, so an unrelated focus chain
        // cannot use the whole time available for reading the pointer's selection.
        var parents = [hit, focus, systemFocus].compactMap { $0 }.map { element($0, kAXParentAttribute) }
        for _ in 0..<10 {
            guard canQuery, parents.contains(where: { $0 != nil }) else { break }
            for index in parents.indices {
                guard let parent = parents[index], visited.insert(parent).inserted, !isSecure(parent) else {
                    parents[index] = nil
                    continue
                }
                if let text = textSelection(in: parent) { return text }
                parents[index] = element(parent, kAXParentAttribute)
            }
        }

        let window = element(app, kAXFocusedWindowAttribute)
        if let window, let text = probe(element(window, kAXFocusedUIElementAttribute)) ?? probe(window) { return text }
        for anchor in [focus, systemFocus, hit].compactMap({ $0 }) {
            for peer in elements(anchor, kAXSharedTextUIElementsAttribute, limit: 6) {
                if let text = probe(peer) { return text }
            }
        }
        for anchor in [hit, window].compactMap({ $0 }) {
            if let text = searchContents(of: anchor, at: point, depth: 3) { return text }
        }
        return nil
    }

    private mutating func probe(_ element: AXUIElement?) -> String? {
        guard canQuery, let element, visited.insert(element).inserted, !isSecure(element) else { return nil }
        return textSelection(in: element)
    }

    private mutating func searchContents(of parent: AXUIElement, at point: CGPoint, depth: Int) -> String? {
        guard canQuery, depth > 0, !isSecure(parent) else { return nil }
        var checked: Set<AXUIElement> = []
        for name in [kAXContentsAttribute, kAXChildrenAttribute] {
            for child in elements(parent, name, limit: 8)
            where checked.insert(child).inserted && contains(point, in: child) {
                if let text = probe(child) ?? searchContents(of: child, at: point, depth: depth - 1) { return text }
            }
        }
        return nil
    }

    private mutating func isSecure(_ element: AXUIElement) -> Bool {
        guard attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole else { return false }
        encounteredSecureField = true
        return true
    }

    private func textSelection(in element: AXUIElement) -> String? {
        let selection = attributes(Self.selectionAttributes, in: element)
        let direct = plainText(selection[0])
        let reportedRanges = selection[2] as? [AnyObject] ?? []
        let ranges = (reportedRanges.count <= 32 ? reportedRanges : []).compactMap { value in
            selectedRange(value).map { (value, $0) }
        }
        if ranges.count > 1, let text = text(for: ranges, in: element) { return text }
        if let direct, direct.hasNonWhitespace { return direct }

        // Some document views publish their selection only as a text marker range.
        if let marker = selection[3], let text = plainText(parameter(element, "AXStringForTextMarkerRange", marker)),
           text.hasNonWhitespace { return text }
        if ranges.count == 1, let text = text(for: ranges, in: element) { return text }
        if let value = selection[1], let range = selectedRange(value) {
            return text(for: [(value, range)], in: element)
        }
        return nil
    }

    private func text(for ranges: [(AnyObject, NSRange)], in element: AXUIElement) -> String? {
        var storage: NSString?
        var parts: [String] = []
        for (value, range) in ranges {
            let rangedText = plainText(parameter(element, kAXStringForRangeParameterizedAttribute, value))
                ?? plainText(parameter(element, kAXAttributedStringForRangeParameterizedAttribute, value))
            if let rangedText, !rangedText.isEmpty {
                parts.append(rangedText)
                continue
            }

            // Only slice AXValue when the element reports a real selection range.
            if storage == nil { storage = plainText(attribute(element, kAXValueAttribute)).map { $0 as NSString } }
            let end = NSMaxRange(range)
            let lowSurrogates: ClosedRange<UInt16> = 0xDC00...0xDFFF
            guard let storage, end <= storage.length,
                  !lowSurrogates.contains(storage.character(at: range.location)),
                  end == storage.length || !lowSurrogates.contains(storage.character(at: end)) else { return nil }
            parts.append(storage.substring(with: range))
        }
        let result = parts.joined(separator: "\n")
        return result.hasNonWhitespace ? result : nil
    }

    private func selectedRange(_ value: AnyObject) -> NSRange? {
        guard let range: CFRange = unpack(value, type: .cfRange, into: CFRange()),
              range.location >= 0, range.length > 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func contains(_ point: CGPoint, in element: AXUIElement) -> Bool {
        let geometry = attributes([kAXPositionAttribute, kAXSizeAttribute], in: element)
        guard let origin = unpack(geometry[0], type: .cgPoint, into: CGPoint.zero),
              let size = unpack(geometry[1], type: .cgSize, into: CGSize.zero) else { return false }
        return CGRect(origin: origin, size: size).contains(point)
    }

    private func unpack<T>(_ value: AnyObject?, type: AXValueType, into initial: T) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = initial
        let success = withUnsafeMutablePointer(to: &result) { AXValueGetValue(value as! AXValue, type, $0) }
        return success ? result : nil
    }

    private func plainText(_ value: AnyObject?) -> String? {
        (value as? String) ?? (value as? NSAttributedString)?.string
    }

    private func attributes(_ names: [String], in element: AXUIElement) -> [AnyObject?] {
        var values: CFArray?
        if canQuery,
           AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
           let returned = values as? [AnyObject], returned.count == names.count {
            return returned.map { value in
                let type = CFGetTypeID(value)
                if type == CFNullGetTypeID() || (type == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError) {
                    return nil
                }
                return value
            }
        }
        return names.map { attribute(element, $0) }
    }

    private func parameter(_ element: AXUIElement, _ name: String, _ argument: AnyObject) -> AnyObject? {
        guard canQuery else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
        return status == .success ? value : nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        guard canQuery else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }

    private func element(_ object: AXUIElement, _ name: String) -> AXUIElement? {
        ownedElement(attribute(object, name))
    }

    private func element(at point: CGPoint, in root: AXUIElement) -> AXUIElement? {
        guard canQuery else { return nil }
        var result: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &result)
        return status == .success ? ownedElement(result) : nil
    }

    private func elements(_ object: AXUIElement, _ name: String, limit: Int) -> [AXUIElement] {
        guard canQuery else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(object, name as CFString, 0, limit, &values) == .success,
              let values = values as? [AnyObject] else { return [] }
        return values.compactMap { ownedElement($0) }
    }

    private func ownedElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, Self.messageTimeout)
        return element
    }
}

@MainActor
enum Clipboard {
    private static var selectionCopy: Task<String?, Never>?
    fileprivate static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static var text: String { NSPasteboard.general.string(forType: .string) ?? "" }

    static func copySelection(from pid: pid_t) async -> String? {
        let tracing = QQSelectionTrace.isActive
        while let selectionCopy {
            _ = await selectionCopy.value
            guard !Task.isCancelled else { return nil }
        }
        guard !Task.isCancelled, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == pid, CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            if tracing { QQSelectionTrace.log("key event skipped (cancelled, focus, secure input or permission)") }
            return nil
        }

        let pasteboard = NSPasteboard.general
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            if tracing { QQSelectionTrace.log("clipboard access denied") }
            return nil
        }
        guard let snapshot = PasteboardSnapshot(pasteboard) else {
            if tracing { QQSelectionTrace.log("could not snapshot previous clipboard") }
            return nil
        }
        let usesSessionCopy = app.bundleIdentifier == "com.tencent.qq"

        // Once the key has been sent, finish restoring the clipboard even if the
        // caller cancels the translation or starts a different command.
        let copy = Task<String?, Never> {
            defer { selectionCopy = nil }
            guard pasteboard.changeCount == snapshot.changeCount, !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                if tracing { QQSelectionTrace.log("clipboard or focus changed before posting") }
                return nil
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            let originalInput = usesSessionCopy ? hardwareInputCounts() : nil
            if tracing { QQSelectionTrace.log("posting Command-C") }
            if usesSessionCopy {
                // QQ's message view is hosted in a separate renderer. Route the
                // shortcut through the frontmost window's normal keyboard path.
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            } else {
                down.postToPid(pid)
                up.postToPid(pid)
            }

            let deadline = ContinuousClock.now + .milliseconds(usesSessionCopy ? 600 : 350)
            // QQ can publish one copy in several pasteboard updates. Measure
            // the quiet period after the last update instead of counting writes.
            var observedCount: Int?
            var lastChange = ContinuousClock.now
            @MainActor func inputUnchanged() -> Bool {
                guard let originalInput else { return true }
                return originalInput == hardwareInputCounts()
            }
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(15))
                let count = pasteboard.changeCount
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !IsSecureEventInputEnabled() else {
                    if tracing { QQSelectionTrace.log("focus or secure input changed while waiting") }
                    return nil
                }
                if count == snapshot.changeCount { continue }
                let changes = count - snapshot.changeCount
                guard changes > 0, usesSessionCopy || changes == 1 else {
                    if tracing { QQSelectionTrace.log("clipboard change count advanced by \(changes)") }
                    return nil
                }
                guard inputUnchanged() else {
                    if tracing { QQSelectionTrace.log("intervening hardware input") }
                    return nil
                }
                guard let types = pasteboard.types, !types.isEmpty else { continue }
                if observedCount != count {
                    if tracing {
                        QQSelectionTrace.log("clipboard updated (changes=\(changes), plain=\(types.contains(.string)), rtf=\(types.contains(.rtf)), html=\(types.contains(.html)), file=\(types.contains(.fileURL)), concealed=\(types.contains(concealed)))")
                    }
                    observedCount = count
                    lastChange = .now
                }
                guard !types.contains(concealed) else { return nil }
                if usesSessionCopy, lastChange.duration(to: .now) < .milliseconds(35) { continue }
                let copied = selectionText(from: pasteboard, types: types, acceptsRichText: usesSessionCopy)
                if usesSessionCopy, copied == nil { continue }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      inputUnchanged(), snapshot.restore(to: pasteboard, replacing: count) else {
                    if tracing { QQSelectionTrace.log("clipboard restore failed") }
                    return nil
                }
                if tracing { QQSelectionTrace.log(copied == nil ? "clipboard had no usable text" : "clipboard text recovered") }
                return copied
            }
            if let observedCount, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               !IsSecureEventInputEnabled(), inputUnchanged() {
                _ = snapshot.restore(to: pasteboard, replacing: observedCount)
            }
            if tracing { QQSelectionTrace.log(observedCount == nil ? "copy timed out without data" : "copy timed out without usable text") }
            return nil
        }
        selectionCopy = copy
        return await copy.value
    }

    private static func hardwareInputCounts() -> [UInt32] {
        let events: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return events.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    private static func selectionText(
        from pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType], acceptsRichText: Bool
    ) -> String? {
        if !acceptsRichText {
            guard !types.contains(.fileURL),
                  let text = pasteboard.string(forType: .string), text.hasNonWhitespace else { return nil }
            return text
        }
        let parts = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            guard !item.types.contains(.fileURL) else { return nil }
            if let text = item.string(forType: .string), text.hasNonWhitespace { return text }
            guard let rtf = item.data(forType: .rtf), rtf.count <= 1024 * 1024,
                  let text = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string,
                  text.hasNonWhitespace else { return nil }
            return text
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

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

@MainActor
enum QQSelectionTrace {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--trace-qq-selection")
    private static let logger = Logger(subsystem: "com.termique.luqri", category: "qq-selection")

    static var isActive: Bool {
        enabled && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.qq"
    }

    static func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
}

@MainActor
private struct PasteboardSnapshot {
    private static let unsafeTypes: Set<NSPasteboard.PasteboardType> = [
        Clipboard.concealed, .init("org.nspasteboard.TransientType"), .init("com.apple.pasteboard.promised-file-url"),
        .init("com.apple.pasteboard.promised-file-content-type")
    ]

    let changeCount: Int
    private let items: [NSPasteboardItem]

    init?(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        guard let types = pasteboard.types,
              let originals = pasteboard.pasteboardItems ?? (types.isEmpty ? [] : nil) else { return nil }
        var copies: [NSPasteboardItem] = []
        var remainingBytes = 8 * 1024 * 1024
        for original in originals {
            let types = original.types
            guard !types.isEmpty, Self.unsafeTypes.isDisjoint(with: types) else { return nil }
            let copy = NSPasteboardItem()
            for type in types {
                guard let data = original.data(forType: type), data.count <= remainingBytes,
                      copy.setData(data, forType: type) else { return nil }
                remainingBytes -= data.count
            }
            copies.append(copy)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        items = copies
    }

    func restore(to pasteboard: NSPasteboard, replacing count: Int) -> Bool {
        guard pasteboard.changeCount == count else { return false }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }
}
