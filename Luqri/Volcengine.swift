import CryptoKit
import Foundation

struct CloudCredentials: Codable, Sendable {
    let accessKey: String
    let secretKey: String

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Luqri/volcengine.json")

    static func load(from url: URL = file) throws -> Self? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Self.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL = Self.file) throws {
        let data = try JSONEncoder().encode(self)
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(from url: URL = file) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

enum VolcengineError: LocalizedError {
    case missingCredentials
    case response(Int)
    case service(String, String)
    case emptyResult
    case invalidBillingResult

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请在设置中填写火山引擎访问密钥。"
        case .response(let status): "火山引擎请求失败（HTTP \(status)）。"
        case .service(let code, let message): "火山引擎返回 \(code) · \(message)"
        case .emptyResult: "火山引擎未返回译文。"
        case .invalidBillingResult: "火山引擎返回的账单明细无法计算用量。"
        }
    }
}

struct VolcengineResponseMetadata: Decodable {
    struct APIError: Decodable {
        let Code: String
        let Message: String
    }

    let Error: APIError?
}

struct TranslationUsage: Sendable {
    private static let monthlyFreeCharacters: Decimal = 2_000_000
    let usedCharacters: Decimal

    var fractionUsed: Double {
        min(1, max(0, NSDecimalNumber(decimal: usedCharacters / Self.monthlyFreeCharacters).doubleValue))
    }

    var detail: String {
        let format = Decimal.FormatStyle.number.precision(.fractionLength(2))
        let used = (usedCharacters / 10_000).formatted(format)
        let total = (Self.monthlyFreeCharacters / 10_000).formatted(format)
        return "\(used) / \(total) 万字符"
    }
}

enum Volcengine {
    struct Operation: Sendable {
        static let translation = Operation(
            host: "translate.volcengineapi.com", query: "Action=TranslateText&Version=2020-06-01",
            service: "translate", contentType: "application/json"
        )
        static let multilingualOCR = Operation(
            host: "visual.volcengineapi.com", query: "Action=MultiLanguageOCR&Version=2022-08-31",
            service: "cv", contentType: "application/x-www-form-urlencoded"
        )
        static let billingDetails = Operation(
            host: "open.volcengineapi.com", query: "Action=ListBillDetail&Version=2022-01-01",
            service: "billing", contentType: "application/json"
        )

        let host: String
        let query: String
        let service: String
        let contentType: String
        let endpoint: URL

        private init(host: String, query: String, service: String, contentType: String) {
            self.host = host
            self.query = query
            self.service = service
            self.contentType = contentType
            endpoint = URL(string: "https://\(host)/?\(query)")!
        }
    }

    private static let region = "cn-north-1"
    private static let timestampStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, timeSeparator: .omitted, timeZoneSeparator: .omitted
    )
    private static let hexDigits = Array("0123456789abcdef".utf8)
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

        let ResponseMetadata: VolcengineResponseMetadata?
        let TranslationList: [Translation]?
    }

    static func translate(_ job: TranslationJob) async throws -> String {
        try Task.checkCancellation()
        guard let credentials = try CloudCredentials.load() else { throw VolcengineError.missingCredentials }
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
            let (data, status) = try await send(request)
            let result = try? JSONDecoder().decode(ResponseBody.self, from: data)
            if let error = result?.ResponseMetadata?.Error {
                throw VolcengineError.service(error.Code, error.Message)
            }
            guard (200..<300).contains(status) else { throw VolcengineError.response(status) }
            guard let translation = result?.TranslationList?.first, !translation.Translation.isEmpty else {
                throw VolcengineError.emptyResult
            }
            if source == nil { source = translation.DetectedSourceLanguage }
            translated.append(contentsOf: chunk[..<range.lowerBound])
            translated += translation.Translation
            translated.append(contentsOf: chunk[range.upperBound...])
        }
        return translated
    }

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func signedRequest(
        payload: Data, credentials: CloudCredentials, date: Date, operation: Operation = .translation
    ) -> URLRequest {
        let timestamp = date.formatted(timestampStyle)
        let day = String(timestamp.prefix(8))
        let contentHash = hex(SHA256.hash(data: payload))
        let scopeParts = [day, region, operation.service, "request"]
        let scope = scopeParts.joined(separator: "/")
        let headers = [
            ("content-type", operation.contentType),
            ("host", operation.host),
            ("x-content-sha256", contentHash),
            ("x-date", timestamp)
        ]
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = ["POST", "/", operation.query, canonicalHeaders, signedHeaders, contentHash].joined(separator: "\n")
        let requestHash = hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let stringToSign = ["HMAC-SHA256", timestamp, scope, requestHash].joined(separator: "\n")

        let signingKey = scopeParts.reduce(Data(credentials.secretKey.utf8)) {
            mac($1, key: $0)
        }
        let signature = hex(mac(stringToSign, key: signingKey))
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: operation.endpoint)
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
        var utf8: [UInt8] = []
        utf8.reserveCapacity(64)
        for byte in bytes {
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }
}

extension Volcengine {
    private struct BillingRequest: Encodable {
        let BillPeriod: String
        let GroupTerm = 0
        let GroupPeriod = 1
        let IgnoreZero = 0
        let Limit: Int
        let Offset: Int
    }

    private struct BillingResponse: Decodable {
        struct Page: Decodable {
            let List: [BillingRow]?
        }

        let ResponseMetadata: VolcengineResponseMetadata?
        let Result: Page?
    }

    private struct BillingRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case ProductZh, Product, Element, ConfigName, Unit, Count
        }

        let characters: Decimal

        init(from decoder: Decoder) throws {
            characters = try Self.translationCharacters(in: decoder.container(keyedBy: CodingKeys.self))
        }

        private static func translationCharacters(in row: KeyedDecodingContainer<CodingKeys>) throws -> Decimal {
            func label(_ field: CodingKeys) throws -> String {
                try row.decodeIfPresent(String.self, forKey: field)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            let productName = try label(.ProductZh)
            let product = try label(.Product)
            let element = try label(.Element)
            let configuration = try label(.ConfigName)
            let unit = try label(.Unit)
            let multiplier: Decimal? = switch unit {
            case "字符", "字符数": 1
            case "千字符", "千字符数": 1_000
            case "万字符", "万字符数": 10_000
            case "百万字符", "百万字符数": 1_000_000
            case "" where element == "百万字符数": 1_000_000
            default: nil
            }

            let products = [productName, product]
            let labels = products + [element, configuration]
            let textTranslation = /文本翻译|text[\s_-]*translation|TranslateText/.ignoresCase()
            guard (products + [configuration]).contains("机器翻译接口服务")
                    || labels.contains(where: { $0.contains(textTranslation) })
                    || (products.contains("机器翻译") && (element == "百万字符数" || multiplier != nil)) else {
                return 0
            }

            guard row.contains(.Count), try !row.decodeNil(forKey: .Count) else { return 0 }
            let count: Decimal?
            if let value = try? label(.Count) {
                guard !value.isEmpty, value != "-" else { return 0 }
                count = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
            } else {
                count = try? row.decode(Decimal.self, forKey: .Count)
            }
            guard let count, let multiplier else { throw VolcengineError.invalidBillingResult }
            return count * multiplier
        }
    }

    private static let billingMonth = Date.VerbatimFormatStyle(
        format: "\(year: .padded(4))-\(month: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
        calendar: Calendar(identifier: .gregorian)
    )

    static func translationUsage(
        credentials: CloudCredentials, now: Date = .now,
        sendRequest: @Sendable (URLRequest) async throws -> (Data, Int) = send
    ) async throws -> TranslationUsage {
        let month = now.formatted(billingMonth)
        let pageSize = 100
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var offset = 0
        var usedCharacters: Decimal = 0
        while true {
            try Task.checkCancellation()
            let body = BillingRequest(BillPeriod: month, Limit: pageSize, Offset: offset)
            let request = signedRequest(
                payload: try encoder.encode(body), credentials: credentials, date: .now, operation: .billingDetails
            )
            let (data, status) = try await sendRequest(request)
            let response = try? decoder.decode(BillingResponse.self, from: data)
            if let error = response?.ResponseMetadata?.Error {
                throw VolcengineError.service(error.Code, error.Message)
            }
            guard (200..<300).contains(status) else { throw VolcengineError.response(status) }
            guard let result = response?.Result else {
                throw VolcengineError.invalidBillingResult
            }
            let rows = result.List ?? []
            for row in rows { usedCharacters += row.characters }
            if rows.count < pageSize { return TranslationUsage(usedCharacters: max(0, usedCharacters)) }
            offset += rows.count
        }
    }
}
