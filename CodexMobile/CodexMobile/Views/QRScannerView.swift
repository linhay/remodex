// FILE: QRScannerView.swift
// Purpose: AVFoundation camera-based QR scanner for relay session pairing.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI

struct QRScannerView: View {
    let onScan: (CodexPairingQRPayload) -> Void

    @State private var scannerError: String?
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true
    @State private var isShowingManualEntry = false
    @State private var manualEntryText = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isCheckingPermission {
                ProgressView()
                    .tint(.white)
            } else if hasCameraPermission {
                QRCameraPreview { code, resetScanLock in
                    handleScanResult(code, resetScanLock: resetScanLock)
                }
                .ignoresSafeArea()

                scannerOverlay
            } else {
                cameraPermissionView
            }
        }
        .sheet(isPresented: $isShowingManualEntry) {
            manualEntrySheet
        }
        .task {
            await checkCameraPermission()
            attemptSimulatorClipboardPairing()
        }
        .alert("Scan Error", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK", role: .cancel) { scannerError = nil }
        } message: {
            Text(scannerError ?? "Invalid QR code")
        }
    }

    private var scannerOverlay: some View {
        VStack(spacing: 24) {
            Spacer()

            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                .frame(width: 250, height: 250)

            Text("Scan QR code from Remodex CLI")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.white)

            Button("Use Pairing Code") {
                isShowingManualEntry = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.18))

            Spacer()
        }
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Camera access needed")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.white)

            Text("Open Settings and allow camera access to scan the pairing QR code.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Use Pairing Code Instead") {
                isShowingManualEntry = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            hasCameraPermission = false
        }
        isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        do {
            onScan(try decodePairingPayload(from: code))
        } catch {
            scannerError = error.localizedDescription
            resetScanLock()
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste the full pairing payload from the Remodex CLI QR output.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)

                TextEditor(text: $manualEntryText)
                    .font(AppFont.mono(.caption))
                    .padding(12)
                    .frame(minHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                Button("Paste from Clipboard") {
                    manualEntryText = UIPasteboard.general.string ?? ""
                }
                .buttonStyle(.bordered)

                Button("Connect") {
                    submitManualEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        isShowingManualEntry = false
                    }
                }
            }
        }
    }

    private func submitManualEntry() {
        do {
            let payload = try decodePairingPayload(from: manualEntryText)
            isShowingManualEntry = false
            onScan(payload)
        } catch {
            scannerError = error.localizedDescription
        }
    }

    private func decodePairingPayload(from rawValue: String) throws -> CodexPairingQRPayload {
        try CodexPairingQRPayload.parse(from: rawValue)
    }

    private func attemptSimulatorClipboardPairing() {
        #if targetEnvironment(simulator)
        guard let clipboardValue = UIPasteboard.general.string,
              let payload = try? decodePairingPayload(from: clipboardValue) else {
            return
        }
        onScan(payload)
        #endif
    }
}

// MARK: - Camera Preview UIViewRepresentable

private struct QRCameraPreview: UIViewRepresentable {
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) {}
}

private class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.phodex.qr-camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        previewLayer = layer

        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        hasScanned = true
        HapticFeedback.shared.triggerImpactFeedback(style: .heavy)
        onScan?(code)
    }

    func resetScanLock() {
        hasScanned = false
    }

    deinit {
        let session = captureSession
        sessionQueue.async {
            session.stopRunning()
        }
    }
}
