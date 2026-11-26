import CryptoKit
import Foundation

enum VolcengineError: LocalizedError {
    case response(Int)
    case service(String, String)
    case emptyResult
    case invalidBillingResult

    var errorDescription: String? {
        switch self {
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

enum Volcengine {
    static let translationQuota = MonthlyQuota(.volcengineTranslation, query: queryTranslationUsage)

    struct Operation: Sendable {
        static let translation = Operation(
            host: "translate.volcengineapi.com", query: "Action=TranslateText&Version=2020-06-01",
            service: "translate", contentType: "application/json"
        )
        static let multilingualOCR = Operation(
            host: "visual.volcengineapi.com", query: "Action=MultiLanguageOCR&Version=2022-08-31",
            service: "cv", contentType: "application/x-www-form-urlencoded"
        )
        static let ocrAudit = Operation(
            host: "open.volcengineapi.com", query: "Action=LookupEvents&Version=2021-09-01",
            service: "cloud_trail", contentType: "application/json"
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
        let credentials = try CloudAccount.volcengine.load()
        let encoder = JSONEncoder()
        var translated = ""
        var source = job.source?.cloudCode
        for chunk in CloudText.chunks(of: job.text, limit: 5_000) {
            try Task.checkCancellation()
            guard let range = CloudText.trimmedRange(in: chunk) else {
                translated += chunk
                continue
            }

            let content = String(chunk[range])
            let body = RequestBody(sourceLanguage: source, targetLanguage: job.target.cloudCode, text: [content])
            let payload = try encoder.encode(body)
            let translation = try await translationQuota.send(credentials, amount: content.utf16.count) {
                let request = signedRequest(payload: payload, credentials: credentials, date: .now)
                let (data, status) = try await CloudHTTP.send(request)
                let result = try? JSONDecoder().decode(ResponseBody.self, from: data)
                try validateResponse(status, metadata: result?.ResponseMetadata)
                guard let translation = result?.TranslationList?.first, !translation.Translation.isEmpty else {
                    throw VolcengineError.emptyResult
                }
                return translation
            }
            if source == nil { source = translation.DetectedSourceLanguage }
            translated.append(contentsOf: chunk[..<range.lowerBound])
            translated += translation.Translation
            translated.append(contentsOf: chunk[range.upperBound...])
        }
        return translated
    }

    static func validateResponse(_ status: Int, metadata: VolcengineResponseMetadata?) throws {
        if let error = metadata?.Error {
            throw CloudRejected(error: VolcengineError.service(error.Code, error.Message))
        }
        guard (200..<300).contains(status) else {
            let error = VolcengineError.response(status)
            if (400..<500).contains(status) { throw CloudRejected(error: error) }
            throw error
        }
    }

    static func signedRequest(
        payload: Data, credentials: CloudCredentials, date: Date, operation: Operation = .translation
    ) -> URLRequest {
        let timestamp = date.formatted(timestampStyle)
        let day = String(timestamp.prefix(8))
        let contentHash = CloudDigest.hex(SHA256.hash(data: payload))
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
        let requestHash = CloudDigest.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let stringToSign = ["HMAC-SHA256", timestamp, scope, requestHash].joined(separator: "\n")

        let signingKey = scopeParts.reduce(Data(credentials.secretKey.utf8)) {
            mac($1, key: $0)
        }
        let signature = CloudDigest.hex(mac(stringToSign, key: signingKey))
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: operation.endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func mac(_ value: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
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

    private static func queryTranslationUsage(credentials: CloudCredentials, now: Date) async throws -> Decimal {
        let month = CloudBilling.period(at: now)
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
            let (data, status) = try await CloudHTTP.send(request)
            let response = try? decoder.decode(BillingResponse.self, from: data)
            try validateResponse(status, metadata: response?.ResponseMetadata)
            guard let result = response?.Result else {
                throw VolcengineError.invalidBillingResult
            }
            let rows = result.List ?? []
            for row in rows { usedCharacters += row.characters }
            if rows.count < pageSize { return max(0, usedCharacters) }
            offset += rows.count
        }
    }
}
