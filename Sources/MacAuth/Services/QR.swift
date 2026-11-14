import AppKit
import CoreImage
import CoreMedia
import ImageIO
import Vision

enum QRDecoder {
    /// QR payloads found in an image (QR only, no other barcode types).
    nonisolated static func payloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return unique(request.results?.compactMap(\.payloadStringValue) ?? [])
    }

    nonisolated static func payloads(in sampleBuffer: CMSampleBuffer) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return unique(request.results?.compactMap(\.payloadStringValue) ?? [])
    }

    /// Reads an image file without copying or keeping it.
    nonisolated static func payloads(at url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return payloads(in: image)
    }

    nonisolated static func payloads(in nsImage: NSImage) -> [String] {
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        return payloads(in: cg)
    }

    private nonisolated static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum QRGenerator {
    /// A QR code with quiet zone, drawn crisp (nearest neighbour) at about `size` points.
    static func image(for text: String, size: CGFloat = 300) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let modules = context.createCGImage(output, from: output.extent) else { return nil }
        let count = modules.width
        let quiet = 4
        let scale = max(1, Int(size) / (count + 2 * quiet))
        let side = (count + 2 * quiet) * scale
        guard let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: side, height: side))
        cg.interpolationQuality = .none
        cg.draw(modules, in: CGRect(x: quiet * scale, y: quiet * scale, width: count * scale, height: count * scale))
        guard let result = cg.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: side, height: side))
    }
}
