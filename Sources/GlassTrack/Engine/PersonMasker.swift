import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Writes COLMAP feature masks that hide people, using Apple's on-device person segmentation.
///
/// COLMAP reads `<mask_path>/<image name>.png`; black pixels are ignored during feature
/// extraction. People are dilated a little so their outlines (and motion blur) are covered too.
enum PersonMasker {
    struct Result {
        var written: Int
        var framesWithPeople: Int
    }

    static func makeMasks(imagesDir: URL, masksDir: URL,
                          progress: @escaping @MainActor (Double, String) -> Void) async throws -> Result {
        let fm = FileManager.default
        try? fm.removeItem(at: masksDir)
        try fm.createDirectory(at: masksDir, withIntermediateDirectories: true)
        let images = (try fm.contentsOfDirectory(atPath: imagesDir.path))
            .filter { ["jpg", "jpeg", "png", "tif", "tiff"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !images.isEmpty else { return Result(written: 0, framesWithPeople: 0) }

        let context = CIContext(options: [.cacheIntermediates: false])
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        var done = 0, withPeople = 0

        try await withThrowingTaskGroup(of: Bool.self) { group in
            var next = 0
            func enqueue() {
                guard next < images.count else { return }
                let name = images[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return try mask(image: imagesDir.appendingPathComponent(name),
                                    output: masksDir.appendingPathComponent(name + ".png"),
                                    context: context)
                }
            }
            for _ in 0..<width { enqueue() }
            while let found = try await group.next() {
                done += 1
                if found { withPeople += 1 }
                if done % 4 == 0 || done == images.count {
                    let d = done, p = withPeople
                    await progress(Double(d) / Double(images.count), "\(d) of \(images.count) frames · people in \(p)")
                }
                enqueue()
            }
        }
        return Result(written: done, framesWithPeople: withPeople)
    }

    /// Returns true when a person was found in the frame.
    private static func mask(image url: URL, output: URL, context: CIContext) throws -> Bool {
        guard let source = CIImage(contentsOf: url) else { throw PipelineError("Could not read \(url.lastPathComponent)") }
        let extent = source.extent

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(ciImage: source, options: [:]).perform([request])

        var keep = CIImage(color: .white).cropped(to: extent)   // white = use for features
        var found = false
        if let buffer = request.results?.first?.pixelBuffer {
            var person = CIImage(cvPixelBuffer: buffer)
            // Scale the (lower resolution) mask up to the frame.
            person = person.transformed(by: CGAffineTransform(scaleX: extent.width / person.extent.width,
                                                              y: extent.height / person.extent.height))
            // Threshold → binary person mask.
            let threshold = CIFilter.colorThreshold()
            threshold.inputImage = person
            threshold.threshold = 0.35
            person = threshold.outputImage ?? person
            // Is anybody there? (average brightness of the mask)
            let avg = CIFilter.areaAverage()
            avg.inputImage = person
            avg.extent = extent
            var px = [UInt8](repeating: 0, count: 4)
            if let out = avg.outputImage {
                context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBA8, colorSpace: nil)
            }
            found = px[0] > 0
            if found {
                // Grow the person region by ~1.5% of the frame to cover edges and motion blur.
                let dilate = CIFilter.morphologyMaximum()
                dilate.inputImage = person.clampedToExtent()
                dilate.radius = Float(max(extent.width, extent.height) * 0.015)
                let grown = (dilate.outputImage ?? person).cropped(to: extent)
                let invert = CIFilter.colorInvert()
                invert.inputImage = grown
                keep = (invert.outputImage ?? keep).cropped(to: extent)
            }
        }
        try context.writePNGRepresentation(of: keep, to: output, format: .L8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
        return found
    }
}
