import AppKit
import Carbon
import ApplicationServices

enum Command: UInt32, CaseIterable {
    case translate = 1
    case recognize
    case screenshotTranslate

    var title: String {
        switch self {
        case .translate: "划词翻译"
        case .recognize: "截图识别并复制"
        case .screenshotTranslate: "截图翻译"
        }
    }

    var icon: String {
        switch self {
        case .translate: "languages"
        case .recognize: "scan-text"
        case .screenshotTranslate: "languages"
        }
    }

    var key: String {
        switch self {
        case .translate: "t"
        case .recognize: "o"
        case .screenshotTranslate: "r"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .translate: UInt32(kVK_ANSI_T)
        case .recognize: UInt32(kVK_ANSI_O)
        case .screenshotTranslate: UInt32(kVK_ANSI_R)
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
    static func read(from pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.18)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }

        var current = focused
        for _ in 0..<3 {
            if let subrole = attribute(current, kAXSubroleAttribute) as? String,
               subrole == kAXSecureTextFieldSubrole { return nil }
            if let text = attribute(current, kAXSelectedTextAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }

            if let range = attribute(current, kAXSelectedTextRangeAttribute),
               CFGetTypeID(range) == AXValueGetTypeID() {
                var selection = CFRange()
                if AXValueGetValue(range as! AXValue, .cfRange, &selection), selection.length > 0 {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyParameterizedAttributeValue(
                        current, kAXStringForRangeParameterizedAttribute as CFString, range, &value
                    )
                    if status == .success, let text = value as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                }
            }
            guard let parent = element(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
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

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
