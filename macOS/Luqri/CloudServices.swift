import Foundation

enum CloudAccount: String, CaseIterable, Identifiable, Codable {
    case volcengine, aliyun

    var id: Self { self }
    var title: String { self == .volcengine ? "火山引擎" : "阿里云" }
    var file: URL { CloudCredentials.directory.appendingPathComponent(rawValue + ".json") }

    func load() throws -> CloudCredentials {
        guard let credentials = try CloudCredentials.load(from: file) else {
            throw CloudFailure("请在设置中填写\(title)访问密钥。")
        }
        return credentials
    }
}

struct CloudFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CloudRejected: LocalizedError {
    let error: any LocalizedError
    var errorDescription: String? { error.errorDescription }
}

struct CloudCredentials: Codable, Equatable, Sendable {
    let accessKey: String
    let secretKey: String

    static let directory = URL.applicationSupportDirectory.appendingPathComponent("Luqri", isDirectory: true)

    static func load(from url: URL) throws -> Self? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Self.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL) throws {
        try Self.write(JSONEncoder().encode(self), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(from url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

enum CloudHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum CloudDigest {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(64)
        for byte in bytes {
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }
}

enum CloudText {
    static func chunks(of text: String, limit: Int) -> some Sequence<Substring> {
        let units = text.utf16
        return sequence(state: Optional(units.startIndex)) { start -> Substring? in
            guard let first = start else { return nil }
            guard let ceiling = units.index(first, offsetBy: limit, limitedBy: units.endIndex), ceiling < units.endIndex else {
                start = nil
                return text[first...]
            }

            var end = ceiling
            if (0xDC00...0xDFFF).contains(units[end]) { end = units.index(before: end) }
            let lowerBound = units.index(first, offsetBy: limit / 2)
            if let separator = units[lowerBound..<end].lastIndex(where: isBoundary) {
                end = units.index(after: separator)
            }
            start = end
            return text[first..<end]
        }
    }

    static func trimmedRange(in text: Substring) -> Range<String.Index>? {
        let scalars = text.unicodeScalars
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard let start = scalars.firstIndex(where: { !whitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !whitespace.contains($0) }) else { return nil }
        return start..<scalars.index(after: last)
    }

    private static func isBoundary(_ unit: UInt16) -> Bool {
        switch unit {
        case 10, 13, 32, 0x3002, 0xFF01, 0xFF1F: true
        default: false
        }
    }
}
