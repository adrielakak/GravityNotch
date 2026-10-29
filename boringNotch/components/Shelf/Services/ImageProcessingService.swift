//
//  ImageProcessingService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-16.
//

import Foundation
import AppKit
import CoreImage
import CoreGraphics
import Vision
import PDFKit
import UniformTypeIdentifiers
import ImageIO

/// Options for image conversion
struct ImageConversionOptions {
    enum ImageFormat {
        case png, jpeg, heic, tiff, bmp
        
        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            case .bmp: return .bmp
            }
        }
        
        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }
    
    let format: ImageFormat
    let compressionQuality: Double // 0.0 to 1.0, only applies to JPEG/HEIC
    let maxDimension: CGFloat? // Max width or height, nil for no scaling
    let removeMetadata: Bool
}

/// Service for processing images (background removal, conversion, PDF creation)
@MainActor
final class ImageProcessingService {
    static let shared = ImageProcessingService()
    
    private init() {}
    private let ciContext = CIContext(options: nil)
    
    // MARK: - Remove Background
    
    /// Removes the background from an image using Vision framework
    func removeBackground(from url: URL) async throws -> URL? {
        guard let inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessingError.invalidImage
        }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        
        try handler.perform([request])
        
        guard let result = request.results?.first else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        
        let output = try await applyMask(mask, to: cgImage)
        
        let processedImage = NSImage(cgImage: output, size: inputImage.size)
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_no_bg.png"
        
        guard let pngData = processedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: pngData),
              let finalData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageProcessingError.saveFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(finalData, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func applyMask(_ mask: CVPixelBuffer, to image: CGImage) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        
        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = maskImage
        filter.backgroundImage = CIImage.empty()
        
        guard let output = filter.outputImage else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let context = CIContext()
        guard let result = context.createCGImage(output, from: output.extent) else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        return result
    }
    
    // MARK: - Convert Image
    
    /// Converts an image with specified options
    func convertImage(from url: URL, options: ImageConversionOptions) async throws -> URL? {
        guard var inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        // Scale image if needed
        if let maxDim = options.maxDimension {
            inputImage = scaleImage(inputImage, maxDimension: maxDim)
        }
        
        // Get image data based on format
        let imageData: Data?
        
        if options.removeMetadata {
            // Create new image without metadata
            guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImageProcessingError.invalidImage
            }
            
            let newImage = NSImage(cgImage: cgImage, size: inputImage.size)
            imageData = try convertToFormat(newImage, format: options.format, quality: options.compressionQuality)
        } else {
            imageData = try convertToFormat(inputImage, format: options.format, quality: options.compressionQuality)
        }
        
        guard let data = imageData else {
            throw ImageProcessingError.conversionFailed
        }
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_converted.\(options.format.fileExtension)"
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(data, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func convertToFormat(_ image: NSImage, format: ImageConversionOptions.ImageFormat, quality: Double) throws -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: quality
            ]
            return bitmap.representation(using: .jpeg, properties: properties)
        case .tiff:
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)
            ]
            return bitmap.representation(using: .tiff, properties: properties)
        case .bmp:
            return bitmap.representation(using: .bmp, properties: [:])
        case .heic:
            // HEIC requires using CIContext
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let ciImage = CIImage(cgImage: cgImage)
            let context = CIContext()
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]
            return try? context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: options)
        }
    }
    
    private func scaleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return image }

        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let srcMax = max(srcCG.width, srcCG.height)
        if CGFloat(srcMax) <= maxDimension {
            return image // no downscaling needed
        }

        let scale = maxDimension / CGFloat(srcMax)

        let ciImage = CIImage(cgImage: srcCG)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = ciImage
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0

        guard let output = lanczos.outputImage else {
            return image
        }

        // Preserve the source color space for exact color matching
        let colorSpace = srcCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

        // Render using the CIContext with matching color space
        guard let dstCG = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }

        return NSImage(cgImage: dstCG, size: NSSize(width: dstCG.width, height: dstCG.height))
    }
    
    // MARK: - Create PDF
    
    /// Creates a PDF from multiple image URLs
    func createPDF(from imageURLs: [URL], outputName: String? = nil) async throws -> URL? {
        guard !imageURLs.isEmpty else {
            throw ImageProcessingError.noImagesProvided
        }
        
        let pdfDocument = PDFDocument()
        
        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }
            
            let pdfPage = PDFPage(image: image)
            if let page = pdfPage {
                pdfDocument.insert(page, at: index)
            }
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        // Create temporary file
        let name = outputName ?? "images_\(Date().timeIntervalSince1970).pdf"
        let pdfName = name.hasSuffix(".pdf") ? name : "\(name).pdf"
        
        guard let pdfData = pdfDocument.dataRepresentation() else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(pdfData, suggestedName: pdfName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    // MARK: - Extract Text (OCR - Droppy Feature)

    /// Checks if a URL is an image or PDF suitable for OCR text extraction
    func isOCRCompatible(_ url: URL) -> Bool {
        if isImageFile(url) { return true }
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return url.pathExtension.lowercased() == "pdf"
        }
        return contentType.conforms(to: .pdf)
    }

    /// Extracts text from an image or PDF using Vision framework (VNRecognizeTextRequest)
    func extractText(from url: URL) async throws -> String {
        if url.pathExtension.lowercased() == "pdf" || ((try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true) {
            if let pdf = PDFDocument(url: url) {
                if let directText = pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines), !directText.isEmpty {
                    return directText
                }
                var pageTexts: [String] = []
                for idx in 0..<min(pdf.pageCount, 10) {
                    if let page = pdf.page(at: idx) {
                        let pageRect = page.bounds(for: .mediaBox)
                        let img = page.thumbnail(of: NSSize(width: pageRect.width * 2, height: pageRect.height * 2), for: .mediaBox)
                        if let recognized = try? await recognizeText(in: img), !recognized.isEmpty {
                            pageTexts.append(recognized)
                        }
                    }
                }
                let combined = pageTexts.joined(separator: "\n\n")
                if !combined.isEmpty { return combined }
            }
        }

        guard let inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        return try await recognizeText(in: inputImage)
    }

    func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessingError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
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
        }
    }

    @MainActor
    func presentOCRResultModal(text: String, sourceName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Text Found"
            alert.informativeText = "No readable text was detected in \"\(sourceName)\"."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Extracted Text (OCR) — Copied to Clipboard"
        alert.informativeText = "From \"\(sourceName)\" (\(trimmed.count) characters):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Save to Shelf (.txt)")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = trimmed
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        let response = alert.runModal()
        let finalString = textView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalString, forType: .string)

        if response == .alertSecondButtonReturn {
            Task { @MainActor in
                let baseName = (sourceName as NSString).deletingPathExtension
                let data = Data(finalString.utf8)
                if let tempURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: "\(baseName)_ocr.txt")),
                   let bookmark = try? Bookmark(url: tempURL) {
                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                    ShelfStateViewModel.shared.add([item])
                }
            }
        }
    }

    // MARK: - Helper Methods
    
    /// Checks if a URL is an image file
    func isImageFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}

// MARK: - Errors

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case backgroundRemovalFailed
    case conversionFailed
    case pdfCreationFailed
    case noImagesProvided
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The file is not a valid image"
        case .backgroundRemovalFailed:
            return "Failed to remove background from image"
        case .conversionFailed:
            return "Failed to convert image format"
        case .pdfCreationFailed:
            return "Failed to create PDF from images"
        case .noImagesProvided:
            return "No images were provided"
        case .saveFailed:
            return "Failed to save processed file"
        }
    }
}
