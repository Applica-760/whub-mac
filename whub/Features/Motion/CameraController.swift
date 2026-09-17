import AVFoundation

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

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start(cameraID: String) {
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
        let cameras = Self.devices
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
        do {
            let points = try detector.points(in: sampleBuffer)
            DispatchQueue.main.async { [weak self] in self?.onPoints?(points) }
        } catch {
            print("Hand detection failed: \(error)")
        }
    }
}
