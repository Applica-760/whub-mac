import AVFoundation
import SwiftUI
import Vision

struct HandPoseCameraView: NSViewRepresentable {
    let cameraID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.start(previewingIn: view, cameraID: cameraID)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        context.coordinator.selectCamera(cameraID)
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "camera.hand-landmarks")
        private let output = AVCaptureVideoDataOutput()
        private let request = VNDetectHumanHandPoseRequest()
        private weak var previewView: CameraPreviewView?
        private var input: AVCaptureDeviceInput?
        private var requestedCameraID = ""
        private var isOutputConfigured = false

        override init() {
            super.init()
            request.maximumHandCount = 2
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
        }

        func start(previewingIn view: CameraPreviewView, cameraID: String) {
            previewView = view
            view.previewLayer.session = session
            selectCamera(cameraID)

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    guard granted else { return }
                    self.queue.async { self.configureAndStart() }
                }
            default:
                break
            }
        }

        func selectCamera(_ cameraID: String) {
            queue.async {
                self.requestedCameraID = cameraID
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
                self.configureAndStart()
            }
        }

        func stop() {
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        private func configureAndStart() {
            let cameras = CameraDiscovery.devices
            guard let camera = cameras.first(where: { $0.uniqueID == requestedCameraID })
                    ?? AVCaptureDevice.systemPreferredCamera
                    ?? cameras.first,
                  input?.device.uniqueID != camera.uniqueID else { return }

            do {
                let newInput = try AVCaptureDeviceInput(device: camera)

                session.beginConfiguration()
                if !isOutputConfigured {
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        return
                    }
                    session.addOutput(output)
                    isOutputConfigured = true
                }

                let oldInput = input
                if let oldInput { session.removeInput(oldInput) }
                guard session.canAddInput(newInput) else {
                    if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
                    session.commitConfiguration()
                    return
                }
                session.addInput(newInput)
                input = newInput
                session.commitConfiguration()

                if !session.isRunning { session.startRunning() }

                DispatchQueue.main.async { [weak previewView] in
                    previewView?.enableMirroring()
                }
            } catch {
                print("Camera setup failed: \(error)")
            }
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            do {
                try VNImageRequestHandler(
                    cmSampleBuffer: sampleBuffer,
                    orientation: .up
                ).perform([request])

                let points = try request.results?.flatMap {
                    try $0.recognizedPoints(.all).values
                }
                .filter { $0.confidence > 0.3 }
                .map(\.location) ?? []

                DispatchQueue.main.async { [weak previewView] in
                    previewView?.show(points: points)
                }
            } catch {
                print("Hand detection failed: \(error)")
            }
        }
    }
}

enum CameraDiscovery {
    nonisolated static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}
