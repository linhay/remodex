// FILE: QRScannerView.swift
// Purpose: AVFoundation camera-based QR scanner for relay session pairing.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI

struct QRScannerView: View {
    let onScan: (CodexPairingQRPayload) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = QRScannerViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isCheckingPermission {
                ProgressView()
                    .tint(.white)
            } else if viewModel.hasCameraPermission {
                QRCameraPreview(
                    isSessionActive: isCameraSessionActive,
                    onScan: { code, resetScanLock in
                    handleScanResult(code, resetScanLock: resetScanLock)
                    }
                )
                .ignoresSafeArea()

                scannerOverlay
            } else {
                cameraPermissionView
            }
        }
        .sheet(isPresented: $viewModel.isShowingManualEntry) {
            manualEntrySheet
        }
        .onChange(of: viewModel.isShowingManualEntry) { _, isPresented in
            if !isPresented {
                viewModel.clearManualEntry()
            }
        }
        .task {
            await checkCameraPermission()
            attemptSimulatorClipboardPairing()
        }
        .alert("Scan Error", isPresented: Binding(
            get: { viewModel.scannerError != nil },
            set: { if !$0 { viewModel.scannerError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.scannerError = nil }
        } message: {
            Text(viewModel.scannerError ?? "Invalid QR code")
        }
    }

    private var isCameraSessionActive: Bool {
        QRScannerCameraSessionPolicy.shouldRunCameraSession(
            hasCameraPermission: viewModel.hasCameraPermission,
            isShowingManualEntry: viewModel.isShowingManualEntry,
            scenePhase: scenePhase
        )
    }

    private var scannerOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 24) {
                Spacer()

                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 250, height: 250)

                Text("Scan QR code from Remodex CLI")
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(.white)

                Spacer()
            }

            FloatingIconCircleButton(
                systemImage: "keyboard",
                colorScheme: colorScheme,
                accessibilityLabel: "Use Pairing Code",
                action: { viewModel.isShowingManualEntry = true }
            )
            .padding(.leading, 20)
            .padding(.bottom, 28)
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
                viewModel.isShowingManualEntry = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            viewModel.hasCameraPermission = true
        case .notDetermined:
            viewModel.hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            viewModel.hasCameraPermission = false
        }
        viewModel.isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        do {
            onScan(try decodePairingPayload(from: code))
        } catch {
            viewModel.scannerError = error.localizedDescription
            resetScanLock()
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste the full pairing payload from the Remodex CLI QR output.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.manualEntryText)
                    .font(AppFont.mono(.caption))
                    .padding(12)
                    .frame(minHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                Button("Paste from Clipboard") {
                    viewModel.manualEntryText = UIPasteboard.general.string ?? ""
                }
                .buttonStyle(.bordered)

                Button("Connect") {
                    submitManualEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitManualEntry)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        viewModel.dismissManualEntry()
                    }
                }
            }
        }
    }

    private func submitManualEntry() {
        do {
            let payload = try decodePairingPayload(from: viewModel.manualEntryText)
            viewModel.dismissManualEntry()
            onScan(payload)
        } catch {
            viewModel.scannerError = error.localizedDescription
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

enum QRScannerCameraSessionPolicy {
    static func shouldRunCameraSession(
        hasCameraPermission: Bool,
        isShowingManualEntry: Bool,
        scenePhase: ScenePhase
    ) -> Bool {
        hasCameraPermission && !isShowingManualEntry && scenePhase == .active
    }
}

// MARK: - Camera Preview UIViewRepresentable

private struct QRCameraPreview: UIViewRepresentable {
    let isSessionActive: Bool
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        view.setSessionRunning(isSessionActive)
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) {
        uiView.setSessionRunning(isSessionActive)
    }
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

    func setSessionRunning(_ isRunning: Bool) {
        let session = captureSession
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if isRunning {
                if !session.isRunning {
                    session.startRunning()
                }
                self.hasScanned = false
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    deinit {
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}
