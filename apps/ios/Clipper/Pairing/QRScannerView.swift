import AVFoundation
import SwiftUI

/// Camera preview that reports the first QR code it sees.
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        let session = context.coordinator.session
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok, let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) {
                session.addOutput(out)
                out.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                out.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}

    static func dismantleUIView(_ v: PreviewView, coordinator: Coordinator) {
        let s = coordinator.session
        DispatchQueue.global().async { s.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(s)
        }
    }
}
