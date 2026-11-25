import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VolcengineOCR {
    static let maximumImageDimension = 2048

    enum Failure: LocalizedError {
        case cannotEncodeImage, imageTooLarge, invalidResponse

        var errorDescription: String? {
            switch self {
            case .cannotEncodeImage: "无法编码截图，请重新框选。"
            case .imageTooLarge: "截图超过火山引擎 OCR 的大小限制，请缩小选区。"
            case .invalidResponse: "火山引擎 OCR 返回格式异常，请重试。"
            }
        }
    }

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

        let code: Int?
        let status: Int?
        let message: String?
        let data: Page?
        let ResponseMetadata: VolcengineResponseMetadata?
    }

    static func recognize(_ image: consuming CGImage) async throws -> String {
        try Task.checkCancellation()
        guard let credentials = try CloudCredentials.load() else { throw VolcengineError.missingCredentials }
        // Only the encoded request needs to survive the network wait.
        let (request, imageHeight) = try makeRequest(from: consume image, credentials: credentials)
        let (data, status) = try await Volcengine.send(request)
        try Task.checkCancellation()
        return try decode(data, httpStatus: status, imageHeight: imageHeight)
    }

    private static func makeRequest(from image: consuming CGImage, credentials: CloudCredentials) throws -> (URLRequest, Int) {
        try autoreleasepool {
            let prepared = try prepare(image)
            let payload = try formPayload(for: prepared)
            try Task.checkCancellation()
            let request = Volcengine.signedRequest(
                payload: payload, credentials: credentials, date: Date(), operation: .multilingualOCR
            )
            return (request, prepared.height)
        }
    }

    static func decode(_ data: Data, httpStatus: Int, imageHeight: Int) throws -> String {
        let response = try? JSONDecoder().decode(Response.self, from: data)
        if let error = response?.ResponseMetadata?.Error {
            throw VolcengineError.service(error.Code, error.Message)
        }
        if let response, let code = [response.code, response.status].compactMap({ $0 }).first(where: { $0 != 10000 }) {
            throw VolcengineError.service(String(code), response.message ?? "OCR 请求失败。")
        }
        guard (200..<300).contains(httpStatus) else { throw VolcengineError.response(httpStatus) }
        guard let response, response.code == 10000 || response.status == 10000, let page = response.data else {
            throw Failure.invalidResponse
        }

        let lines = page.lines.lazy.compactMap { line -> OCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, bounds: line.bounds(imageHeight: imageHeight))
        }
        let text = OCRLine.paragraphs(from: lines)
        guard !text.isEmpty else { throw OCRFailure.noText }
        return text
    }

    static func prepare(_ image: CGImage) throws -> CGImage {
        let scale = min(1, CGFloat(maximumImageDimension) / CGFloat(max(image.width, image.height)))
        let scaledWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let scaledHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let width = max(256, scaledWidth)
        let height = max(256, scaledHeight)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.cannotEncodeImage }
        let opaque = image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast
        if opaque, width == image.width, height == image.height, image.bitsPerComponent == 8,
           let sourceSpace = image.colorSpace, CFEqual(sourceSpace, colorSpace) {
            return image
        }
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.cannotEncodeImage
        }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(
            x: (width - scaledWidth) / 2, y: (height - scaledHeight) / 2,
            width: scaledWidth, height: scaledHeight
        ))
        guard let prepared = canvas.makeImage() else { throw Failure.cannotEncodeImage }
        return prepared
    }

    static func formPayload(for image: CGImage) throws -> Data {
        for quality in [0.9, 0.72, 0.55] {
            try Task.checkCancellation()
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw Failure.cannotEncodeImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.cannotEncodeImage }
            if let payload = escapedForm((buffer as Data).base64EncodedData()) { return payload }
        }
        throw Failure.imageTooLarge
    }

    private static func escapedForm(_ base64: Data) -> Data? {
        let prefix = "image_base64=".utf8
        let plus = UInt8(ascii: "+"), slash = UInt8(ascii: "/"), equals = UInt8(ascii: "=")
        guard base64.count <= 8_000_000 - prefix.count else { return nil }
        return base64.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            // The Base64 alphabet only has three bytes that need escaping in a form value.
            let reserved = input.reduce(into: 0) { count, byte in
                if byte == plus || byte == slash || byte == equals { count += 1 }
            }
            let length = prefix.count + input.count + 2 * reserved
            guard length <= 8_000_000 else { return nil }
            var payload = Data(count: length)
            payload.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                var index = 0
                for byte in prefix {
                    output[index] = byte
                    index += 1
                }
                for byte in input {
                    let hex: (UInt8, UInt8)
                    switch byte {
                    case plus: hex = (UInt8(ascii: "2"), UInt8(ascii: "B"))
                    case slash: hex = (UInt8(ascii: "2"), UInt8(ascii: "F"))
                    case equals: hex = (UInt8(ascii: "3"), UInt8(ascii: "D"))
                    default:
                        output[index] = byte
                        index += 1
                        continue
                    }
                    output[index] = UInt8(ascii: "%")
                    output[index + 1] = hex.0
                    output[index + 2] = hex.1
                    index += 3
                }
            }
            return payload
        }
    }
}
