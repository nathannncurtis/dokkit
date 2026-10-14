import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

@MainActor
final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let onCode: @MainActor (String) -> Void
    private let box = SessionBox()
    private let label = UILabel()
    private var lastAt = Date.distantPast

    init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { start() } else { deny() }
            }
        default: deny()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = box
        DispatchQueue.global().async { box.session.stopRunning() }
    }

    private func deny() {
        label.text = "The camera is off for Dokkit. Allow it in Settings, or paste the code below."
    }

    private func start() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              box.session.canAddInput(input)
        else {
            label.text = "No camera is available. Paste the code below."
            return
        }
        let output = AVCaptureMetadataOutput()
        box.session.addInput(input)
        guard box.session.canAddOutput(output) else { return }
        box.session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: box.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        let box = box
        DispatchQueue.global().async { box.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              text.hasPrefix("dokkit-phone:"), Date().timeIntervalSince(lastAt) > 3
        else { return }
        lastAt = Date()
        onCode(text)
    }
}
