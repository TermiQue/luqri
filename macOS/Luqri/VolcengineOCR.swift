import CoreGraphics
import Foundation

enum VolcengineOCR {
    static let usage = VolcengineOCRUsage(query: auditCalls)

    private struct Response: Decodable {
        struct Page: Decodable {
            struct Line: Decodable {
                let text: String
                let rect: [[Double]]?

                func bounds(imageHeight: Int) -> CGRect {
                    guard let rect, rect.count == 4 else { return .zero }
                    var left = Double.infinity, right = -Double.infinity
                    var top = Double.infinity, bottom = -Double.infinity
                    for point in rect {
                        guard point.count == 2 else { return .zero }
                        left = min(left, point[0])
                        right = max(right, point[0])
                        top = min(top, point[1])
                        bottom = max(bottom, point[1])
                    }
                    return CGRect(x: left, y: Double(imageHeight) - bottom, width: right - left, height: bottom - top)
                }
            }

            let lines: [Line]

            enum CodingKeys: String, CodingKey {
                case lines = "ocr_infos"
            }
        }

        let request_id: String?
        let code: Int?
        let status: Int?
        let message: String?
        let data: Page?
        let ResponseMetadata: VolcengineResponseMetadata?
    }

    static func recognize(_ image: consuming CGImage) async throws -> String {
        try Task.checkCancellation()
        let credentials = try CloudAccount.volcengine.load()
        let (payload, imageHeight) = try encode(consume image)
        let text = try await usage.send(credentials) {
            let request = Volcengine.signedRequest(
                payload: payload, credentials: credentials, date: .now, operation: .multilingualOCR
            )
            // Keep an in-flight response when the caller dismisses the window so its request ID can be recorded.
            let (data, status) = try await Task.detached { try await CloudHTTP.send(request) }.value
            return try decode(data, httpStatus: status, imageHeight: imageHeight)
        }
        guard !text.isEmpty else { throw OCRFailure.noText }
        return text
    }

    private static func encode(_ image: consuming CGImage) throws -> (Data, Int) {
        try autoreleasepool {
            let prepared = try CloudOCRImage.prepare(image)
            return (try formPayload(for: prepared), prepared.height)
        }
    }

    static func decode(_ data: Data, httpStatus: Int, imageHeight: Int) throws -> (id: String?, text: String) {
        let response = try? JSONDecoder().decode(Response.self, from: data)
        try Volcengine.validateResponse(httpStatus, metadata: response?.ResponseMetadata)
        if let response, let code = [response.code, response.status].compactMap({ $0 }).first(where: { $0 != 10000 }) {
            throw VolcengineError.service(String(code), response.message ?? "OCR 请求失败。")
        }
        guard let response, response.code == 10000 || response.status == 10000, let page = response.data else {
            throw CloudFailure("火山引擎 OCR 返回格式异常，请重试。")
        }

        let lines = page.lines.lazy.compactMap { line -> OCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, bounds: line.bounds(imageHeight: imageHeight))
        }
        return (response.request_id, OCRLine.paragraphs(from: lines))
    }

    private struct AuditQuery: Encodable {
        struct Condition: Encodable {
            let LookupConditionKey: String
            let LookupConditionValue: String
        }

        let StartTime: Int
        let EndTime: Int
        let MaxResults = 100
        let NextToken: String?
        let LookupConditions = [
            Condition(LookupConditionKey: "EventName", LookupConditionValue: "MultiLanguageOCR"),
            Condition(LookupConditionKey: "EventSource", LookupConditionValue: "cv")
        ]
    }

    private struct AuditResponse: Decodable {
        struct Page: Decodable {
            struct Event: Decodable {
                let EventName: String?
                let EventSource: String?
                let RequestID: String?
                let ErrorCode: String?
                let EventDetail: String?
            }

            let Trails: [Event]?
            let NextToken: String?
        }

        let Result: Page?
        let ResponseMetadata: VolcengineResponseMetadata?
    }

    private struct AuditDetail: Decodable {
        let ErrorCode: String?
    }

    private static func auditCalls(_ credentials: CloudCredentials, _ begin: Date, _ end: Date) async throws -> Set<String> {
        let startTime = Int(begin.timeIntervalSince1970), endTime = Int(end.timeIntervalSince1970)
        guard startTime < endTime else { return [] }
        var cursor: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        while true {
            try Task.checkCancellation()
            let query = AuditQuery(StartTime: startTime, EndTime: endTime, NextToken: cursor)
            let request = Volcengine.signedRequest(payload: try JSONEncoder().encode(query), credentials: credentials,
                                                   date: .now, operation: .ocrAudit)
            let (data, status) = try await CloudHTTP.send(request)
            let response = try? JSONDecoder().decode(AuditResponse.self, from: data)
            try Volcengine.validateResponse(status, metadata: response?.ResponseMetadata)
            guard let page = response?.Result, page.Trails != nil || (page.NextToken ?? "").isEmpty else {
                throw CloudFailure("火山引擎返回的 OCR 审计结果格式异常。")
            }
            for event in page.Trails ?? [] where event.EventName == "MultiLanguageOCR" && event.EventSource == "cv" {
                if let error = event.ErrorCode, !error.isEmpty { continue }
                if let encoded = event.EventDetail,
                   let detail = try? JSONDecoder().decode(AuditDetail.self, from: Data(encoded.utf8)),
                   let error = detail.ErrorCode, !error.isEmpty { continue }
                guard let id = event.RequestID, !id.isEmpty else {
                    throw CloudFailure("火山引擎 OCR 审计事件缺少请求编号。")
                }
                ids.insert(id)
            }
            guard let next = page.NextToken, !next.isEmpty else { return ids }
            guard cursors.insert(next).inserted else { throw CloudFailure("火山引擎 OCR 审计返回重复分页。") }
            cursor = next
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func formPayload(for image: CGImage) throws -> Data {
        for quality in CloudOCRImage.jpegQualities {
            if let payload = escapedForm(try CloudOCRImage.jpeg(image, quality: quality)) { return payload }
        }
        throw CloudFailure("截图超过火山引擎 OCR 的大小限制，请缩小选区。")
    }

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let formPrefix = Array("image_base64=".utf8)
    private static let maximumFormBytes = 8_000_000

    private static func escapedForm(_ jpeg: Data) -> Data? {
        guard jpeg.count <= (maximumFormBytes - formPrefix.count) / 4 * 3 else { return nil }
        let base64Length = 4 * ((jpeg.count + 2) / 3)
        guard !jpeg.isEmpty else { return Data(formPrefix) }

        return jpeg.withUnsafeBytes { rawInput -> Data? in
            let input = rawInput.bindMemory(to: UInt8.self).baseAddress!
            let tail = jpeg.count % 3
            let end = jpeg.count - tail
            var escapes = 0
            for offset in stride(from: 0, to: end, by: 3) {
                let (a, b, c, d) = sextets(input[offset], input[offset + 1], input[offset + 2])
                escapes += (a >= 62 ? 1 : 0) + (b >= 62 ? 1 : 0) + (c >= 62 ? 1 : 0) + (d >= 62 ? 1 : 0)
            }
            if tail > 0 {
                let (a, b, c, _) = sextets(input[end], tail == 2 ? input[end + 1] : 0, 0)
                let padding = 3 - tail
                escapes += padding + (a >= 62 ? 1 : 0) + (b >= 62 ? 1 : 0) + (tail == 2 && c >= 62 ? 1 : 0)
            }

            let length = formPrefix.count + base64Length + 2 * escapes
            guard length <= maximumFormBytes else { return nil }
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawOutput in
                var output = rawOutput.bindMemory(to: UInt8.self).baseAddress!
                formPrefix.withUnsafeBufferPointer {
                    output.update(from: $0.baseAddress!, count: $0.count)
                }
                output += formPrefix.count
                base64Alphabet.withUnsafeBufferPointer { table in
                    let alphabet = table.baseAddress!
                    for offset in stride(from: 0, to: end, by: 3) {
                        let (a, b, c, d) = sextets(input[offset], input[offset + 1], input[offset + 2])
                        emit(a, alphabet: alphabet, to: &output)
                        emit(b, alphabet: alphabet, to: &output)
                        emit(c, alphabet: alphabet, to: &output)
                        emit(d, alphabet: alphabet, to: &output)
                    }
                    if tail > 0 {
                        let (a, b, c, _) = sextets(input[end], tail == 2 ? input[end + 1] : 0, 0)
                        emit(a, alphabet: alphabet, to: &output)
                        emit(b, alphabet: alphabet, to: &output)
                        if tail == 2 { emit(c, alphabet: alphabet, to: &output) }
                        else { emitPadding(to: &output) }
                        emitPadding(to: &output)
                    }
                }
                assert(output == rawOutput.bindMemory(to: UInt8.self).baseAddress! + length)
            }
            return data
        }
    }

    @inline(__always)
    private static func sextets(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> (Int, Int, Int, Int) {
        (Int(a >> 2), Int((a & 3) << 4 | b >> 4), Int((b & 15) << 2 | c >> 6), Int(c & 63))
    }

    @inline(__always)
    private static func emit(_ value: Int, alphabet: UnsafePointer<UInt8>, to output: inout UnsafeMutablePointer<UInt8>) {
        if value < 62 {
            output.pointee = alphabet[value]
            output += 1
        } else {
            output[0] = UInt8(ascii: "%")
            output[1] = UInt8(ascii: "2")
            output[2] = value == 62 ? UInt8(ascii: "B") : UInt8(ascii: "F")
            output += 3
        }
    }

    private static func emitPadding(to output: inout UnsafeMutablePointer<UInt8>) {
        output[0] = UInt8(ascii: "%")
        output[1] = UInt8(ascii: "3")
        output[2] = UInt8(ascii: "D")
        output += 3
    }
}
