import CoreGraphics
import CryptoKit
import Foundation

enum Aliyun {
    private struct Operation: Equatable {
        let host: String
        let action: String
        let version: String

        static let translation = Self(host: "mt.aliyuncs.com", action: "TranslateGeneral", version: "2018-10-12")
        static let report = Self(host: "mt.aliyuncs.com", action: "GetTranslateReport", version: "2018-10-12")
        static let ocr = Self(host: "ocr-api.cn-hangzhou.aliyuncs.com", action: "RecognizeAllText", version: "2021-07-07")
        static let audit = Self(host: "actiontrail.cn-hangzhou.aliyuncs.com", action: "LookupEvents", version: "2020-07-06")
    }

    private struct Envelope<Value: Decodable>: Decodable {
        enum CodingKeys: String, CodingKey { case data = "Data" }
        let code: String?
        let data: Value?

        init(from decoder: Decoder) throws {
            let status = try Status(from: decoder)
            code = status.code
            if let code, !code.isEmpty, code != "200", code != "Success" { throw rejection(status, code: code) }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let encoded = try? values.decode(String.self, forKey: .data) {
                data = try JSONDecoder().decode(Value.self, from: Data(encoded.utf8))
            } else {
                data = try values.decodeIfPresent(Value.self, forKey: .data)
            }
        }
    }

    private struct Translation: Decodable, Sendable { let Translated: String }

    private struct Report: Decodable {
        struct Row: Decodable {
            enum CodingKeys: String, CodingKey { case total }
            let total: Decimal

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let number = try? values.decode(Decimal.self, forKey: .total) {
                    total = number
                } else {
                    let text = try values.decode(String.self, forKey: .total)
                    guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                        throw CloudFailure("阿里云返回的翻译报表无法计算用量。")
                    }
                    total = number
                }
                guard total >= 0 else { throw CloudFailure("阿里云返回的翻译报表无法计算用量。") }
            }
        }

        let result: [Row]
    }

    private struct OCRResult: Decodable, Sendable {
        struct SubImage: Decodable, Sendable {
            struct Blocks: Decodable, Sendable {
                struct Block: Decodable, Sendable {
                    struct Point: Decodable, Sendable { let X: Double; let Y: Double }
                    let BlockContent: String?
                    let BlockPoints: [Point]?

                    func line(imageHeight: Int) -> OCRLine? {
                        let text = BlockContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty else { return nil }
                        guard let points = BlockPoints, points.count == 4 else {
                            return OCRLine(text: text, bounds: .zero)
                        }
                        let x = points.map(\.X), y = points.map(\.Y)
                        let left = x.min()!, bottom = y.max()!
                        return OCRLine(text: text, bounds: CGRect(
                            x: left, y: Double(imageHeight) - bottom,
                            width: x.max()! - left, height: bottom - y.min()!
                        ))
                    }
                }

                let BlockDetails: [Block]?
            }

            let BlockInfo: Blocks?
        }

        let Content: String?
        let SubImages: [SubImage]?
    }

    private struct AuditPage: Decodable {
        struct Event: Decodable {
            let eventName: String?
            let errorCode: String?
            let requestId: String?
            let eventId: String?
        }

        let Events: [Event]
        let NextToken: String?
    }

    static let translationQuota = MonthlyQuota(.aliyunTranslation, query: queryTranslationUsage)
    static let ocrQuota = MonthlyQuota(.aliyunOCR, query: queryOCRUsage)
    private static let algorithm = "ACS3-HMAC-SHA256"
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func translate(_ job: TranslationJob) async throws -> String {
        let credentials = try CloudAccount.aliyun.load()
        let source = job.source.map(languageCode) ?? "auto"
        let target = languageCode(job.target)
        if (source == "zh-tw" && target != "zh" && target != "zh-tw")
            || (target == "zh-tw" && source != "zh" && source != "zh-tw") {
            let simplified = try await translate(job.text, from: source, to: "zh", credentials: credentials)
            return try await translate(simplified, from: "zh", to: target, credentials: credentials)
        }
        return try await translate(job.text, from: source, to: target, credentials: credentials)
    }

    private static func languageCode(_ language: Language) -> String {
        language == .traditionalChinese ? "zh-tw" : language.cloudCode
    }

    private static func translate(_ text: String, from source: String, to target: String,
                                  credentials: CloudCredentials) async throws -> String {
        guard source != target else { return text }
        var result = ""
        for chunk in CloudText.chunks(of: text, limit: 4_999) {
            try Task.checkCancellation()
            guard let range = CloudText.trimmedRange(in: chunk) else {
                result += chunk
                continue
            }
            let content = String(chunk[range])
            let body = Data(parameters([
                "FormatType": "text", "Scene": "general", "SourceLanguage": source,
                "TargetLanguage": target, "SourceText": content
            ]).utf8)
            let translation = try await translationQuota.send(credentials, amount: content.utf16.count) {
                let data = try await send(.translation, body: body, contentType: "application/x-www-form-urlencoded",
                                          credentials: credentials)
                let value: Translation = try decode(data, requiresCode: true)
                guard !value.Translated.isEmpty else { throw CloudFailure("阿里云未返回译文。") }
                return value.Translated
            }
            result += chunk[..<range.lowerBound]
            result += translation
            result += chunk[range.upperBound...]
        }
        return result
    }

    static func recognize(_ image: consuming CGImage) async throws -> String {
        let credentials = try CloudAccount.aliyun.load()
        let (body, height) = try encodeImage(consume image)
        let result: OCRResult = try await ocrQuota.send(credentials, amount: 1) {
            let data = try await send(.ocr, query: [
                "Type": "MultiLang", "MultiLanConfig": #"{"Languages":"chn,eng,ja,kor,lading,rus,tai,mys,idn,viet,ukr"}"#,
                "OutputCoordinate": "points", "OutputOricoord": "true"
            ], body: body, contentType: "application/octet-stream", credentials: credentials)
            return try decode(data)
        }
        try Task.checkCancellation()
        let lines = (result.SubImages ?? []).lazy
            .flatMap { $0.BlockInfo?.BlockDetails ?? [] }
            .compactMap { $0.line(imageHeight: height) }
        let paragraphs = OCRLine.paragraphs(from: lines)
        let text = paragraphs.isEmpty ? (result.Content ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : paragraphs
        guard !text.isEmpty else { throw OCRFailure.noText }
        return text
    }

    private static func encodeImage(_ image: consuming CGImage) throws -> (Data, Int) {
        try autoreleasepool {
            let prepared = try CloudOCRImage.prepare(image)
            for quality in CloudOCRImage.jpegQualities {
                let jpeg = try CloudOCRImage.jpeg(prepared, quality: quality)
                if jpeg.count <= 10_000_000 { return (jpeg, prepared.height) }
            }
            throw CloudFailure("截图超过阿里云 OCR 的大小限制，请缩小选区。")
        }
    }

    private static func queryTranslationUsage(_ credentials: CloudCredentials, _ now: Date) async throws -> Decimal {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = CloudBilling.zone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let data = try await send(.report, query: [
            "ApiName": "translate_standard", "Group": "day",
            "BeginTime": format.string(from: CloudBilling.monthStart(at: now)),
            "EndTime": format.string(from: now)
        ], credentials: credentials)
        let report: Report = try decode(data, requiresCode: true)
        return report.result.reduce(0) { $0 + $1.total }
    }

    private static func queryOCRUsage(_ credentials: CloudCredentials, _ now: Date) async throws -> Decimal {
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        var begin = CloudBilling.monthStart(at: now)
        var ids = Set<String>()
        while begin < end {
            let until = min(begin.addingTimeInterval(30 * 86_400), end)
            try await addOCREvents(from: begin, to: until, credentials: credentials, ids: &ids)
            if until == end { break }
            // Overlap the boundary because the provider may exclude the end second.
            begin = until.addingTimeInterval(-1)
            try await Task.sleep(for: .seconds(1))
        }
        return Decimal(ids.count)
    }

    private static func addOCREvents(from begin: Date, to end: Date, credentials: CloudCredentials,
                                     ids: inout Set<String>) async throws {
        var query = [
            "StartTime": begin.ISO8601Format(), "EndTime": end.ISO8601Format(), "MaxResults": "50",
            "LookupAttribute.1.Key": "EventName", "LookupAttribute.1.Value": Operation.ocr.action
        ]
        var cursors = Set<String>()
        while true {
            let data = try await send(.audit, query: query, credentials: credentials)
            let page = try JSONDecoder().decode(AuditPage.self, from: data)
            for event in page.Events where event.eventName == Operation.ocr.action && (event.errorCode ?? "").isEmpty {
                guard let id = event.requestId ?? event.eventId, !id.isEmpty else {
                    throw CloudFailure("阿里云 OCR 审计事件缺少请求编号。")
                }
                ids.insert(id)
            }
            guard let cursor = page.NextToken, !cursor.isEmpty else { return }
            guard cursors.insert(cursor).inserted else { throw CloudFailure("阿里云 OCR 审计返回重复分页。") }
            query["NextToken"] = cursor
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func decode<Value: Decodable>(_ body: Data, requiresCode: Bool = false) throws -> Value {
        let response = try JSONDecoder().decode(Envelope<Value>.self, from: body)
        guard (!requiresCode || response.code == "200"), let data = response.data else {
            throw CloudFailure("阿里云返回格式异常，请重试。")
        }
        return data
    }

    private struct Status: Decodable {
        enum CodingKeys: String, CodingKey { case code = "Code", message = "Message" }
        let code: String?
        let message: String?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? values.decode(String.self, forKey: .code))
                ?? (try? values.decode(Int.self, forKey: .code)).map(String.init)
            message = try values.decodeIfPresent(String.self, forKey: .message)
        }
    }

    private static func rejection(_ status: Status, code: String) -> CloudRejected {
        let message = code.caseInsensitiveCompare("ocrServiceNotOpen") == .orderedSame
            ? "阿里云 OCR 统一识别尚未开通。请在文字识别控制台的「服务管理与开通」中开通此服务。"
            : "阿里云返回 \(code) · \(status.message ?? "请求失败。")"
        return CloudRejected(error: CloudFailure(message))
    }

    private static func send(_ operation: Operation, query: [String: String] = [:], body: Data = Data(),
                             contentType: String? = nil, credentials: CloudCredentials) async throws -> Data {
        try Task.checkCancellation()
        let request = signedRequest(operation, query: parameters(query), body: body, contentType: contentType,
                                    credentials: credentials)
        let (data, status) = try await CloudHTTP.send(request)
        guard !(200..<300).contains(status) else { return data }
        if let detail = try? JSONDecoder().decode(Status.self, from: data), let code = detail.code, !code.isEmpty {
            if operation == .audit, ["NoPermission", "Forbidden", "NotAuthorized"].contains(code) {
                throw CloudFailure("请为当前 RAM 用户授予 actiontrail:LookupEvents 只读权限。")
            }
            throw rejection(detail, code: code)
        }
        let error = CloudFailure("阿里云请求失败（HTTP \(status)）。")
        if (400..<500).contains(status) { throw CloudRejected(error: error) }
        throw error
    }

    private static func parameters(_ values: [String: String]) -> String {
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
        return values.map { (encode($0.key), encode($0.value)) }.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private static func signedRequest(_ operation: Operation, query: String, body: Data, contentType: String?,
                                      credentials: CloudCredentials) -> URLRequest {
        let hash = CloudDigest.hex(SHA256.hash(data: body))
        var headers = [
            "host": operation.host,
            "x-acs-action": operation.action,
            "x-acs-content-sha256": hash,
            "x-acs-date": Date.now.ISO8601Format(),
            "x-acs-signature-nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "x-acs-version": operation.version
        ]
        headers["content-type"] = contentType
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = ["POST", "/", query, canonicalHeaders, signedHeaders, hash].joined(separator: "\n")
        let digest = CloudDigest.hex(SHA256.hash(data: Data(canonical.utf8)))
        let key = SymmetricKey(data: Data(credentials.secretKey.utf8))
        let signature = CloudDigest.hex(HMAC<SHA256>.authenticationCode(for: Data("\(algorithm)\n\(digest)".utf8), using: key))

        let suffix = query.isEmpty ? "" : "?\(query)"
        var request = URLRequest(url: URL(string: "https://\(operation.host)/\(suffix)")!)
        request.httpMethod = "POST"
        if contentType != nil { request.httpBody = body }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(algorithm) Credential=\(credentials.accessKey),SignedHeaders=\(signedHeaders),Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }
}
