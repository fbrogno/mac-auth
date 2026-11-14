import AVFoundation
import AppKit
import SwiftUI

enum CameraAccess {
    case notDetermined, authorized, denied, unavailable

    static var current: CameraAccess {
        if AVCaptureDevice.default(for: .video) == nil { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func request() async -> CameraAccess {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Runs a capture session and reports QR payloads (about 5 checks per second). Frames are never stored.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.fbrogno.macauth.camera")
    private var lastCheck = Date.distantPast
    private let handler: @Sendable ([String]) -> Void
    private(set) var failed = false

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        super.init()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            failed = true
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) } else { failed = true }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) } else { failed = true }
        session.commitConfiguration()
    }

    func start() {
        guard !failed else { return }
        queue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= 0.2 else { return }
        lastCheck = now
        let found = QRDecoder.payloads(in: sampleBuffer)
        if !found.isEmpty { handler(found) }
    }
}

/// Live preview; the session stops as soon as the view goes away.
struct CameraPreview: NSViewRepresentable {
    let onPayloads: @Sendable ([String]) -> Void

    final class Coordinator {
        var controller: CameraController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let controller = CameraController(handler: onPayloads)
        context.coordinator.controller = controller
        let layer = AVCaptureVideoPreviewLayer(session: controller.session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        controller.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.controller?.stop()
        coordinator.controller = nil
    }
}
