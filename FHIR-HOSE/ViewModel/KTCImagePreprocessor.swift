//
//  KTCImagePreprocessor.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 3/31/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog
import UIKit
import Vision

/// Preprocesses scanned document images for better OCR accuracy.
/// Full pipeline: Document Segmentation → Perspective Correction → CIDocumentEnhancer → Grayscale → Sharpen
enum KTCImagePreprocessor {

    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC.Preprocess")
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Full preprocessing pipeline: segment, correct perspective, then enhance.
    /// Returns an enhanced CGImage, or the original if preprocessing fails.
    static func preprocess(_ cgImage: CGImage) -> CGImage {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Step 1: Document segmentation + perspective correction
        let corrected = correctPerspective(cgImage) ?? cgImage

        // Step 2: Enhancement pipeline (document enhancer → grayscale → sharpen)
        let enhanced = enhance(corrected)

        let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        logger.info("Full preprocess in \(elapsed)ms (\(cgImage.width)x\(cgImage.height) → \(enhanced.width)x\(enhanced.height))")

        return enhanced
    }

    // MARK: - Document Segmentation + Perspective Correction

    /// Detect the document boundary and apply perspective correction.
    /// Returns nil if no document is detected or correction isn't needed.
    static func correctPerspective(_ cgImage: CGImage) -> CGImage? {
        let t0 = CFAbsoluteTimeGetCurrent()

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.warning("Document segmentation failed: \(error.localizedDescription)")
            return nil
        }

        guard let result = request.results?.first else {
            logger.info("No document detected in image")
            return nil
        }

        let corners = result.boundingBox
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Check if the document already fills most of the image (skip correction)
        let coverage = corners.width * corners.height
        if coverage > 0.85 {
            let coveragePct = String(format: "%.0f", coverage * 100)
            logger.info("Document covers \(coveragePct)% of image — skipping perspective correction")
            return nil
        }

        // Check if we have detailed corner points from the observation
        let topLeft = result.topLeft
        let topRight = result.topRight
        let bottomLeft = result.bottomLeft
        let bottomRight = result.bottomRight

        // Convert normalized Vision coords to pixel coords
        let tl = CGPoint(x: topLeft.x * imgW, y: topLeft.y * imgH)
        let tr = CGPoint(x: topRight.x * imgW, y: topRight.y * imgH)
        let bl = CGPoint(x: bottomLeft.x * imgW, y: bottomLeft.y * imgH)
        let br = CGPoint(x: bottomRight.x * imgW, y: bottomRight.y * imgH)

        // Apply perspective correction
        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomLeft = bl
        filter.bottomRight = br

        guard let output = filter.outputImage else {
            logger.warning("CIPerspectiveCorrection produced no output")
            return nil
        }

        guard let corrected = context.createCGImage(output, from: output.extent) else {
            logger.warning("Failed to render perspective-corrected image")
            return nil
        }

        let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let coveragePct = String(format: "%.0f", coverage * 100)
        logger.info("Perspective corrected in \(elapsed)ms (coverage: \(coveragePct)%, \(corrected.width)x\(corrected.height))")

        return corrected
    }

    // MARK: - Image Enhancement

    /// Enhance a document image for optimal OCR results.
    /// Pipeline: CIDocumentEnhancer → grayscale + contrast → sharpen.
    /// Returns an enhanced CGImage, or the original if enhancement fails.
    static func enhance(_ cgImage: CGImage) -> CGImage {
        let t0 = CFAbsoluteTimeGetCurrent()
        let ciImage = CIImage(cgImage: cgImage)

        // 1. Document enhancement -- background whitening, contrast normalization
        let docEnhancer = CIFilter.documentEnhancer()
        docEnhancer.inputImage = ciImage
        docEnhancer.amount = 1.0

        guard let enhanced = docEnhancer.outputImage else {
            logger.warning("CIDocumentEnhancer failed, falling back to original")
            return cgImage
        }

        // 2. Convert to high-contrast grayscale
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = enhanced
        colorControls.saturation = 0.0
        colorControls.contrast = 1.4
        colorControls.brightness = 0.0

        guard let grayscale = colorControls.outputImage else {
            logger.warning("CIColorControls failed, using document-enhanced image")
            return render(enhanced, size: cgImage) ?? cgImage
        }

        // 3. Sharpen text edges
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = grayscale
        sharpen.sharpness = 0.5
        sharpen.radius = 1.69

        guard let sharpened = sharpen.outputImage else {
            logger.warning("CISharpenLuminance failed, using grayscale image")
            return render(grayscale, size: cgImage) ?? cgImage
        }

        guard let result = render(sharpened, size: cgImage) else {
            logger.warning("Final render failed, returning original")
            return cgImage
        }

        let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        logger.info("Image enhanced in \(elapsed)ms (\(cgImage.width)x\(cgImage.height))")

        return result
    }

    private static func render(_ ciImage: CIImage, size reference: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        return context.createCGImage(ciImage, from: rect)
    }
}
