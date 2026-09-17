import AVFoundation
import Combine
import SwiftUI

struct MotionView: View {
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCameraID = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HandPoseCameraView(cameraID: selectedCameraID)
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
        cameras = CameraDiscovery.devices
        guard !cameras.contains(where: { $0.uniqueID == selectedCameraID }) else { return }
        selectedCameraID = AVCaptureDevice.systemPreferredCamera?.uniqueID ?? cameras.first?.uniqueID ?? ""
    }

    private var selectedCameraName: String {
        cameras.first { $0.uniqueID == selectedCameraID }?.localizedName ?? "Camera"
    }
}

#Preview {
    MotionView()
}
