import XCTest
import Foundation
import UIKit

/// Reference images for brush verification, and the rules around them.
///
/// Goldens are pinned per device class: GPU rasterization is not
/// bit-identical across drivers, so comparing an iPad's frame to a
/// simulator's reference would fail for reasons that have nothing to do
/// with a brush. A run with no matching baseline says so instead of
/// comparing against someone else's images.
///
/// Nothing here ever writes into the repo. Re-baselining emits the new
/// images as attachments and a script lifts them out, so baselines change
/// by intent, in a reviewable diff.
@MainActor
enum GoldenStore {

    /// Set `CLAY_GOLDEN_REBASELINE=1` to emit new references instead of
    /// comparing. Deliberately an environment variable rather than a
    /// constant: a default run must not be able to rewrite the baseline.
    static var isRebaselining: Bool {
        ProcessInfo.processInfo.environment["CLAY_GOLDEN_REBASELINE"] == "1"
    }

    /// Hardware model ("iPad15,5"), or the simulated model when running on
    /// a simulator — where `uname` reports the Mac's architecture and would
    /// collapse every simulator onto one baseline.
    static var deviceClass: String {
        let environment = ProcessInfo.processInfo.environment
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "sim-" + simulated.replacingOccurrences(of: " ", with: "-")
        }
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self,
                                 capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }

    /// Flat name: Xcode flattens bundle resources, so the device class is
    /// carried in the filename rather than a directory.
    static func referenceName(brush: String, view: String) -> String {
        "golden-\(deviceClass)-\(brush)-\(view)"
    }

    /// How far a capture may drift and still count as the same image.
    /// Loose enough to absorb driver-level rasterization noise, tight
    /// enough that a brush whose result moved is caught.
    static let meanTolerance = 1.5
    static let outlierFractionTolerance = 0.02

    enum Outcome {
        case matched
        case rebaselined
        /// No reference for this device class — reported, never guessed at.
        case missingBaseline(String)
        /// A real mismatch, kept distinct from a behavioural failure so a
        /// driver update reads as "re-baseline", not "17 brushes broke".
        case drifted(name: String, difference: BrushCapture.Difference)
    }

    static func loadReference(named name: String) -> BrushCapture.Image? {
        let bundle = Bundle(for: BrushMatrixTests.self)
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data),
              let cgImage = image.cgImage else { return nil }

        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little).rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return BrushCapture.Image(width: width, height: height, pixels: pixels)
    }

    /// Compares a capture with its reference, or emits a new reference when
    /// re-baselining. Attaches what a reader needs either way.
    @discardableResult
    static func verify(_ capture: BrushCapture.Image, brush: String, view: String,
                       in testCase: XCTestCase) -> Outcome {
        let name = referenceName(brush: brush, view: view)

        if isRebaselining {
            BrushCapture.attach(capture, named: name, to: testCase)
            return .rebaselined
        }
        guard let reference = loadReference(named: name) else {
            BrushCapture.attach(capture, named: "\(name)-actual", to: testCase)
            return .missingBaseline(name)
        }
        guard let difference = BrushCapture.compare(capture, reference) else {
            return .drifted(name: name,
                            difference: BrushCapture.Difference(
                                meanAbsolute: .infinity, outlierPixels: 0,
                                totalPixels: 0))
        }
        if difference.meanAbsolute <= meanTolerance,
           difference.outlierFraction <= outlierFractionTolerance {
            return .matched
        }
        // Everything a reader needs to judge it: what it should look like,
        // what it looks like, and where they differ.
        BrushCapture.attach(reference, named: "\(name)-reference", to: testCase)
        BrushCapture.attach(capture, named: "\(name)-actual", to: testCase)
        if let diff = BrushCapture.differenceImage(capture, reference) {
            BrushCapture.attach(diff, named: "\(name)-difference", to: testCase)
        }
        return .drifted(name: name, difference: difference)
    }
}
