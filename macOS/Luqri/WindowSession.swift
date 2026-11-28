import Foundation

struct ShortcutSnapshot: Codable {
    let bindings: [Command: Shortcut]
    let failed: Set<Command>
    let message: String?
}

enum ShortcutEdit: Codable {
    case suspend, resume, restore
    case assign(Command, Shortcut)
}

enum WindowOperation: Codable {
    case translate(text: String, provider: Provider, source: Language?, target: Language)
    case recognize(UUID)
    case usage(CloudMeter)
}

struct WindowResult: Codable {
    var text: String? = nil
    var used: Decimal? = nil
    var note: String? = nil
    var error: String? = nil
}

enum WindowMessage: Codable {
    case showSettings(UUID)
    case showTranslation(UUID, input: String?, screenshot: UUID?)
    case opened(UUID)
    case closeTranslation
    case discardScreenshot(UUID)
    case closing
    case quit
    case shortcutEdit(ShortcutEdit)
    case shortcuts(ShortcutSnapshot)
    case permissions(Set<AppPermission>)
    case refreshPermissions
    case requestPermission(AppPermission)
    case credentialsChanged(CloudAccount)
    case ocrChanged(OCRProvider)
    case request(UUID, WindowOperation)
    case cancel(UUID)
    case result(UUID, WindowResult)
}

// These endpoints are inherited pipes between the two instances of Luqri.
// Text and credentials never go through command-line arguments or a listening socket.
@MainActor
final class WindowChannel {
    private let input: FileHandle
    private let output: FileHandle
    private let writer = DispatchQueue(label: "com.termique.luqri.window-messages")
    private var receiveTask: Task<Void, Never>?
    private var ended = false

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func start(receive: @escaping (WindowMessage) -> Void, disconnect: @escaping () -> Void) {
        let stream = AsyncStream<Data>.makeStream()
        input.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stream.continuation.finish()
            } else {
                stream.continuation.yield(data)
            }
        }
        receiveTask = Task {
            let decoder = JSONDecoder()
            var buffered = Data()
            for await chunk in stream.stream {
                guard !Task.isCancelled else { return }
                buffered.append(chunk)
                while let newline = buffered.firstIndex(of: 10) {
                    guard let message = try? decoder.decode(WindowMessage.self, from: buffered[..<newline]) else {
                        disconnect()
                        return
                    }
                    buffered.removeSubrange(...newline)
                    receive(message)
                    guard !Task.isCancelled else { return }
                }
            }
            if !Task.isCancelled { disconnect() }
        }
    }

    func send(_ message: WindowMessage) {
        guard !ended else { return }
        writer.async { [output] in
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(10)
            try? output.write(contentsOf: data)
        }
    }

    func close(afterSending completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !ended else { return }
        ended = true
        input.readabilityHandler = nil
        receiveTask?.cancel()
        receiveTask = nil
        try? input.close()
        writer.async { [output] in
            try? output.close()
            if let completion { Task { @MainActor in completion() } }
        }
    }
}

@MainActor
final class WindowProcess {
    static let launchArgument = "--window-session"

    let process: Process
    let channel: WindowChannel
    var opening: [(id: UUID, message: WindowMessage)] = []
    var closing = false
    var mayRetryOpening = true

    init(executable: URL) throws {
        let toWindow = Pipe()
        let toCore = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = [Self.launchArgument]
        process.standardInput = toWindow
        process.standardOutput = toCore
        channel = WindowChannel(input: toCore.fileHandleForReading, output: toWindow.fileHandleForWriting)
        do {
            try process.run()
        } catch {
            channel.close()
            throw error
        }
        try? toCore.fileHandleForWriting.close()
        try? toWindow.fileHandleForReading.close()
    }
}
