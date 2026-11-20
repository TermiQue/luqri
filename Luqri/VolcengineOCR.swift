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
                    guard let rect, rect.count == 4, rect.allSatisfy({ $0.count == 2 }) else { return .zero }
                    let xs = rect.map { $0[0] }
                    let ys = rect.map { $0[1] }
                    let left = xs.min()!, right = xs.max()!
                    let top = ys.min()!, bottom = ys.max()!
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

    static func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        guard let credentials = try CloudCredentials.load() else { throw VolcengineError.missingCredentials }
        let (request, imageHeight) = try autoreleasepool {
            let prepared = try prepare(image)
            let payload = try formPayload(for: prepared)
            try Task.checkCancellation()
            let request = Volcengine.signedRequest(
                payload: payload, credentials: credentials, date: Date(), operation: .multilingualOCR
            )
            return (request, prepared.height)
        }
        let (data, status) = try await Volcengine.send(request)
        try Task.checkCancellation()
        return try decode(data, httpStatus: status, imageHeight: imageHeight)
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

        let lines = page.lines.compactMap { line -> OCRLine? in
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

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
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
        let prefix = "image_base64="
        for quality in [0.9, 0.72, 0.55] {
            try Task.checkCancellation()
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw Failure.cannotEncodeImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  let encoded = (buffer as Data).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw Failure.cannotEncodeImage
            }
            if prefix.utf8.count + encoded.utf8.count <= 8_000_000 {
                var payload = Data(prefix.utf8)
                payload.append(contentsOf: encoded.utf8)
                return payload
            }
        }
        throw Failure.imageTooLarge
    }
}
