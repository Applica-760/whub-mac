import AVFoundation
import OSLog

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    let session = AVCaptureSession()
    var onPoints: (([CGPoint]) -> Void)?
    var onSessionConfigured: (() -> Void)?

    private let queue = DispatchQueue(label: "camera.hand-landmarks")
    private let output = AVCaptureVideoDataOutput()
    private let detector = HandPoseDetector()
    private var input: AVCaptureDeviceInput?
    private var requestedCameraID = ""
    private var isOutputConfigured = false
    private var wantsRunning = false
    private let logger = Logger(subsystem: "whub.camera", category: "lifecycle")

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start(cameraID: String) {
        queue.async {
            let wasRunningRequested = self.wantsRunning
            if !wasRunningRequested { self.logger.notice("Camera start requested") }
            self.wantsRunning = true
            self.requestedCameraID = cameraID
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndStart()
            case .notDetermined where !wasRunningRequested:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    guard granted else { return }
                    self.queue.async { self.configureAndStart() }
                }
            default:
                break
            }
        }
    }

    func stop() {
        logger.notice("Camera stop requested")
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.logger.notice("Camera stop completed; isRunning=\(self.session.isRunning)")
        }
    }

    private func configureAndStart() {
        guard wantsRunning else { return }
        let cameras = Self.devices
        guard let camera = cameras.first(where: { $0.uniqueID == requestedCameraID })
                ?? AVCaptureDevice.systemPreferredCamera
                ?? cameras.first else { return }
        if input?.device.uniqueID == camera.uniqueID {
            if !session.isRunning {
                session.startRunning()
                logger.notice("Camera resumed; isRunning=\(self.session.isRunning)")
            }
            return
        }

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
            logger.notice("Camera configured; isRunning=\(self.session.isRunning)")
            DispatchQueue.main.async { [weak self] in self?.onSessionConfigured?() }
        } catch {
            print("Camera setup failed: \(error)")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard wantsRunning else { return }
        do {
            let points = try detector.points(in: sampleBuffer)
            DispatchQueue.main.async { [weak self] in self?.onPoints?(points) }
        } catch {
            print("Hand detection failed: \(error)")
        }
    }
}
