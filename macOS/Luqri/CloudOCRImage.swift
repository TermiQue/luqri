import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CloudOCRImage {
    static let maximumDimension = 2048
    static let jpegQualities = [0.9, 0.72, 0.55]

    static func prepare(_ image: CGImage) throws -> CGImage {
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(image.width, image.height)))
        let scaledWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let scaledHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let width = max(256, scaledWidth)
        let height = max(256, scaledHeight)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw CloudFailure("无法编码截图，请重新框选。") }
        let opaque = image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast
        if opaque, width == image.width, height == image.height, image.bitsPerComponent == 8,
           let sourceSpace = image.colorSpace, CFEqual(sourceSpace, colorSpace) {
            return image
        }
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CloudFailure("无法编码截图，请重新框选。")
        }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(
            x: (width - scaledWidth) / 2, y: (height - scaledHeight) / 2,
            width: scaledWidth, height: scaledHeight
        ))
        guard let prepared = canvas.makeImage() else { throw CloudFailure("无法编码截图，请重新框选。") }
        return prepared
    }

    static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        try Task.checkCancellation()
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CloudFailure("无法编码截图，请重新框选。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CloudFailure("无法编码截图，请重新框选。") }
        return buffer as Data
    }
}
