import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Protocol defining multimodal and OCR image/diagram ingestion for documents.
public protocol MultiModalIngestionProvider: Sendable {
    func extractText(from imageData: Data) async throws -> String
    func extractText(from imageURL: URL) async throws -> String
}

/// On-device OCR document and image processor leveraging Apple's Vision Framework.
public struct OCRDocumentProcessor: MultiModalIngestionProvider {
    public static let maximumImageDimension = 8_192
    public static let maximumImagePixels = 16 * 1024 * 1024

    public init() {}

    public func extractText(from imageURL: URL) async throws -> String {
        try DocumentInputLimits.validate(fileURL: imageURL)
        let data = try Data(contentsOf: imageURL)
        return try await extractText(from: data)
    }

    public func extractText(from imageData: Data) async throws -> String {
        guard imageData.count <= DocumentInputLimits.maxBytes else {
            throw ArchonMemoryError.inputTooLarge(maxBytes: DocumentInputLimits.maxBytes)
        }
        #if canImport(Vision) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            return "Error: Unable to decode image buffer for OCR extraction."
        }

        guard width > 0,
              height > 0,
              width <= Int64(Self.maximumImageDimension),
              height <= Int64(Self.maximumImageDimension),
              width <= Int64(Self.maximumImagePixels) / height else {
            throw ArchonMemoryError.documentLoadFailed(
                "Image dimensions exceed the OCR safety limits of \(Self.maximumImageDimension) pixels per side and \(Self.maximumImagePixels) total pixels."
            )
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumImageDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
        ) else {
            return "Error: Unable to decode image buffer for OCR extraction."
        }

        guard cgImage.width > 0,
              cgImage.height > 0,
              Int64(cgImage.width) <= Int64(Self.maximumImagePixels) / Int64(cgImage.height) else {
            throw ArchonMemoryError.documentLoadFailed("Decoded image dimensions exceed the OCR pixel safety limit.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let marker = "\n[output truncated]"
                let contentLimit = max(0, DocumentInputLimits.maxBytes - marker.utf8.count)
                var output = Data()
                var truncated = false
                for line in observations.compactMap({ $0.topCandidates(1).first?.string }) {
                    let separator = output.isEmpty ? Data() : Data([10])
                    let remaining = contentLimit - output.count - separator.count
                    guard remaining > 0 else {
                        truncated = true
                        break
                    }

                    output.append(separator)
                    let lineData = Data(line.utf8)
                    if lineData.count <= remaining {
                        output.append(lineData)
                    } else {
                        output.append(lineData.prefix(remaining))
                        truncated = true
                        break
                    }
                }
                let result = String(decoding: output, as: UTF8.self)
                continuation.resume(
                    returning: truncated ? result + marker : result
                )
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #else
        return "Vision framework is unavailable on this target architecture."
        #endif
    }
}
