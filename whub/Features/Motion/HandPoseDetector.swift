import AVFoundation
import Vision

final class HandPoseDetector {
    private let request = VNDetectHumanHandPoseRequest()

    init() {
        request.maximumHandCount = 2
    }

    func points(in sampleBuffer: CMSampleBuffer) throws -> [CGPoint] {
        try VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up
        ).perform([request])

        return try request.results?.flatMap {
            try $0.recognizedPoints(.all).values
        }
        .filter { $0.confidence > 0.3 }
        .map(\.location) ?? []
    }
}
