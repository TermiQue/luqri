import AppKit
import Carbon
import ApplicationServices

enum Command: UInt32, CaseIterable {
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

    var shortcut: String { "⌥⇧" + key.uppercased() }
}

@MainActor
final class GlobalShortcuts {
    private static let signature: OSType = 0x4C555152
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private let action: (Command) -> Void

    init(action: @escaping (Command) -> Void) {
        self.action = action
    }

    func install() -> Set<Command> {
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
                    Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue().action(command)
                    return noErr
                }
            },
            1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else { return Set(Command.allCases) }

        var failed = Set<Command>()
        for command in Command.allCases {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.rawValue)
            let result = RegisterEventHotKey(
                command.keyCode, UInt32(optionKey | shiftKey), id,
                GetApplicationEventTarget(), 0, &reference
            )
            if result == noErr, let reference {
                references.append(reference)
            } else {
                failed.insert(command)
            }
        }
        return failed
    }

    func uninstall() {
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        references.removeAll()
        handler = nil
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
