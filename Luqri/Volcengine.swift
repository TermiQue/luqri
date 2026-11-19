import CryptoKit
import Foundation
import Security

struct CloudCredentials: Codable, Sendable {
    let accessKey: String
    let secretKey: String

    private static let keychainItem = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.termique.luqri",
        kSecAttrAccount as String: "volcengine.translate"
    ]

    static func load() throws -> Self? {
        var item: [String: Any] = keychainItem
        item[kSecReturnData as String] = true as NSNumber
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try checkKeychain(status)
        guard let data = result as? Data else { throw VolcengineError.keychain(errSecDecode) }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let values = [kSecValueData as String: data]
        let item = Self.keychainItem
        let status = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var newItem: [String: Any] = item
            newItem[kSecValueData as String] = data
            try Self.checkKeychain(SecItemAdd(newItem as CFDictionary, nil))
        } else {
            try Self.checkKeychain(status)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(keychainItem as CFDictionary)
        if status != errSecItemNotFound { try checkKeychain(status) }
    }

    private static func checkKeychain(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw VolcengineError.keychain(status) }
    }
}

enum VolcengineError: LocalizedError {
    case missingCredentials
    case keychain(OSStatus)
    case response(Int)
    case service(String, String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请在设置中填写火山引擎访问密钥。"
        case .keychain(let status): "无法访问钥匙串（\(status)）。"
        case .response(let status): "火山引擎请求失败（HTTP \(status)）。"
        case .service(let code, let message): "火山引擎返回 \(code) · \(message)"
        case .emptyResult: "火山引擎未返回译文。"
        }
    }
}

enum Volcengine {
    private static let host = "translate.volcengineapi.com"
    private static let query = "Action=TranslateText&Version=2020-06-01"
    private static let endpoint = URL(string: "https://\(host)/?\(query)")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private struct RequestBody: Encodable {
        let sourceLanguage: String?
        let targetLanguage: String
        let text: [String]

        enum CodingKeys: String, CodingKey {
            case sourceLanguage = "SourceLanguage"
            case targetLanguage = "TargetLanguage"
            case text = "TextList"
        }
    }

    private struct ResponseBody: Decodable {
        struct Translation: Decodable {
            let Translation: String
            let DetectedSourceLanguage: String?
        }

        struct Metadata: Decodable {
            struct APIError: Decodable {
                let Code: String
                let Message: String
            }
            let Error: APIError?
        }

        let ResponseMetadata: Metadata?
        let TranslationList: [Translation]?
    }

    static func translate(_ job: TranslationJob, credentials: CloudCredentials) async throws -> String {
        var translated = ""
        var source = job.source?.cloudCode
        for chunk in chunks(of: job.text) {
            try Task.checkCancellation()
            let content = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, let range = chunk.range(of: content) else {
                translated += chunk
                continue
            }

            let body = RequestBody(sourceLanguage: source, targetLanguage: job.target.cloudCode, text: [content])
            let payload = try JSONEncoder().encode(body)
            let request = signedRequest(payload: payload, credentials: credentials, date: Date())
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = try? JSONDecoder().decode(ResponseBody.self, from: data)
            if let error = result?.ResponseMetadata?.Error {
                throw VolcengineError.service(error.Code, error.Message)
            }
            guard (200..<300).contains(status) else { throw VolcengineError.response(status) }
            guard let translation = result?.TranslationList?.first, !translation.Translation.isEmpty else {
                throw VolcengineError.emptyResult
            }
            if source == nil { source = translation.DetectedSourceLanguage }
            translated += chunk[..<range.lowerBound] + translation.Translation + chunk[range.upperBound...]
        }
        return translated
    }

    static func signedRequest(payload: Data, credentials: CloudCredentials, date: Date) -> URLRequest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let contentHash = hex(SHA256.hash(data: payload))
        let scope = "\(day)/cn-north-1/translate/request"
        let headers = [
            ("content-type", "application/json"),
            ("host", host),
            ("x-content-sha256", contentHash),
            ("x-date", timestamp)
        ]
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = ["POST", "/", query, canonicalHeaders, signedHeaders, contentHash].joined(separator: "\n")
        let requestHash = hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let stringToSign = ["HMAC-SHA256", timestamp, scope, requestHash].joined(separator: "\n")

        let signingKey = [day, "cn-north-1", "translate", "request"].reduce(Data(credentials.secretKey.utf8)) {
            mac($1, key: $0)
        }
        let signature = hex(mac(stringToSign, key: signingKey))
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    static func chunks(of text: String) -> [Substring] {
        let units = text.utf16
        let limit = 5_000
        var start = units.startIndex
        var chunks: [Substring] = []
        while let ceiling = units.index(start, offsetBy: limit, limitedBy: units.endIndex), ceiling < units.endIndex {
            var end = ceiling
            if (0xDC00...0xDFFF).contains(units[end]) { end = units.index(before: end) }
            let lowerBound = units.index(start, offsetBy: limit / 2)
            if let separator = units[lowerBound..<end].lastIndex(where: { [10, 13, 32, 0x3002, 0xFF01, 0xFF1F].contains($0) }) {
                end = units.index(after: separator)
            }
            chunks.append(text[start..<end])
            start = end
        }
        chunks.append(text[start...])
        return chunks
    }

    private static func mac(_ value: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
