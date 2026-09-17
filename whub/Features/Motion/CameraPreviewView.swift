import AVFoundation
import AppKit

final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let landmarkLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        landmarkLayer.fillColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(landmarkLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        landmarkLayer.frame = bounds
    }

    func enableMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    func show(points: [CGPoint]) {
        let path = CGMutablePath()
        for point in points {
            let previewPoint = previewLayer.layerPointConverted(
                fromCaptureDevicePoint: CGPoint(x: point.x, y: 1 - point.y)
            )
            let converted = CGPoint(x: previewPoint.x, y: bounds.height - previewPoint.y)
            path.addEllipse(in: CGRect(x: converted.x - 4, y: converted.y - 4, width: 8, height: 8))
        }
        landmarkLayer.path = path
    }
}
