import AVFoundation
import AppKit
import Combine
import SwiftUI

struct MotionView: View {
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCameraID = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CameraPreview(cameraID: selectedCameraID)
                .ignoresSafeArea()

            if !cameras.isEmpty {
                Menu {
                    ForEach(cameras, id: \.uniqueID) { camera in
                        Button {
                            selectedCameraID = camera.uniqueID
                        } label: {
                            if camera.uniqueID == selectedCameraID {
                                Label(camera.localizedName, systemImage: "checkmark")
                            } else {
                                Text(camera.localizedName)
                            }
                        }
                    }
                } label: {
                    Text(selectedCameraName)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)
                .frame(maxWidth: 240)
                .padding()
            }
        }
        .onAppear(perform: refreshCameras)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshCameras()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshCameras()
        }
    }

    private func refreshCameras() {
        cameras = CameraController.devices
        guard !cameras.contains(where: { $0.uniqueID == selectedCameraID }) else { return }
        selectedCameraID = AVCaptureDevice.systemPreferredCamera?.uniqueID ?? cameras.first?.uniqueID ?? ""
    }

    private var selectedCameraName: String {
        cameras.first { $0.uniqueID == selectedCameraID }?.localizedName ?? "Camera"
    }

    private struct CameraPreview: NSViewRepresentable {
        let cameraID: String

        func makeCoordinator() -> CameraController {
            CameraController()
        }

        func makeNSView(context: Context) -> PreviewView {
            let view = PreviewView()
            view.attach(session: context.coordinator.session)
            context.coordinator.onPoints = { [weak view] in view?.show(points: $0) }
            context.coordinator.onSessionConfigured = { [weak view] in view?.enableMirroring() }
            context.coordinator.start(cameraID: cameraID)
            return view
        }

        func updateNSView(_ nsView: PreviewView, context: Context) {
            context.coordinator.selectCamera(cameraID)
        }

        static func dismantleNSView(_ nsView: PreviewView, coordinator: CameraController) {
            coordinator.stop()
        }
    }

    private final class PreviewView: NSView {
        private let previewLayer = AVCaptureVideoPreviewLayer()
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

        func attach(session: AVCaptureSession) {
            previewLayer.session = session
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
}

#Preview {
    MotionView()
}
