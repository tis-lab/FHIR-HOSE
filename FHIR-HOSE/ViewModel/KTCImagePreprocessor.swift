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

/// Preprocesses scanned document images for better OCR accuracy.
/// Pipeline: CIDocumentEnhancer -> CIColorControls (grayscale + contrast) -> CISharpenLuminance
enum KTCImagePreprocessor {

    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC.Preprocess")
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Enhance a scanned document image for optimal OCR results.
    /// Returns an enhanced CGImage, or the original if preprocessing fails.
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
        logger.info("Image preprocessed in \(elapsed)ms (\(cgImage.width)x\(cgImage.height))")

        return result
    }

    private static func render(_ ciImage: CIImage, size reference: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        return context.createCGImage(ciImage, from: rect)
    }
}
