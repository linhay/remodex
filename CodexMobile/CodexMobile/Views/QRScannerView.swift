// FILE: QRScannerView.swift
// Purpose: AVFoundation camera-based QR scanner for relay session pairing.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import Observation
import SwiftUI
import UIKit

struct QRScannerView: View {
    let onScan: (CodexPairingQRPayload) -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = QRScannerViewModel()
    @FocusState private var isManualEntryFocused: Bool
    private let settingsAccentColor = Color(.plan)

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.secondarySystemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if viewModel.isCheckingPermission {
                ProgressView()
                    .tint(.primary)
            } else if viewModel.hasCameraPermission {
                scannerContent
            } else {
                cameraPermissionView
            }

            if let onClose {
                VStack {
                    HStack {
                        Spacer()
                        Button("Close") {
                            onClose()
                        }
                        .font(AppFont.subheadline(weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    Spacer()
                }
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

    private var scannerContent: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 32, 420)
            let scannerHeight = min(max(geometry.size.height * 0.5, 320), 520)
            let topInset: CGFloat = onClose == nil ? 14 : 66

            VStack(spacing: 16) {
                headerCard

                ZStack {
                    QRCameraPreview(
                        isSessionActive: isCameraSessionActive,
                        onScan: { code, resetScanLock in
                            handleScanResult(code, resetScanLock: resetScanLock)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .frame(width: min(width * 0.68, 260), height: min(width * 0.68, 260))

                    VStack {
                        Spacer()
                        HStack {
                            Text("Align the full QR code in frame")
                                .font(AppFont.caption(weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.45), in: Capsule())
                            Spacer()
                        }
                        .padding(14)
                    }
                }
                .frame(width: width, height: scannerHeight)
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)

                actionStrip
                    .frame(width: width)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, topInset)
            .padding(.horizontal, 16)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pair Your Mac")
                    .font(AppFont.title3(weight: .semibold))
                Spacer()
                Text("Secure")
                    .font(AppFont.caption(weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.green)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }

            Text("Scan the QR code shown by `remodex up` on your Mac.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.55))
        )
    }

    private var actionStrip: some View {
        HStack(spacing: 10) {
            scannerSecondaryActionButton(
                title: "Use Pairing Code",
                systemImage: "keyboard"
            ) {
                viewModel.isShowingManualEntry = true
            }

            scannerPrimaryActionButton(
                title: "Paste",
                systemImage: "doc.on.clipboard"
            ) {
                attemptSimulatorClipboardPairing()
            }
        }
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Camera Access Needed")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.primary)

            Text("Enable camera permission in iOS Settings, or continue with manual pairing code.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                scannerPrimaryActionButton(
                    title: "Open Settings",
                    systemImage: "gearshape.fill"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

                scannerSecondaryActionButton(
                    title: "Use Pairing Code",
                    systemImage: "keyboard"
                ) {
                    viewModel.isShowingManualEntry = true
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.6))
        )
        .padding(.horizontal, 20)
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
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.secondarySystemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsCard(title: "Pairing Code") {
                            Text("Paste the full pairing payload printed by `remodex up`.")
                                .font(AppFont.subheadline())
                                .foregroundStyle(.secondary)

                            TextEditor(text: $viewModel.manualEntryText)
                                .font(AppFont.mono(.caption))
                                .scrollContentBackground(.hidden)
                                .focused($isManualEntryFocused)
                                .padding(12)
                                .frame(minHeight: 220)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            isManualEntryFocused ? settingsAccentColor : Color(.separator),
                                            lineWidth: isManualEntryFocused ? 1.5 : 1
                                        )
                                )
                        }

                        HStack(spacing: 10) {
                            scannerSecondaryActionButton(
                                title: "Paste from Clipboard",
                                systemImage: "doc.on.clipboard"
                            ) {
                                viewModel.manualEntryText = UIPasteboard.general.string ?? ""
                            }

                            scannerPrimaryActionButton(
                                title: "Connect",
                                systemImage: "link",
                                isEnabled: viewModel.canSubmitManualEntry
                            ) {
                                submitManualEntry()
                            }
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
            }
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

    private func scannerSecondaryActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func scannerPrimaryActionButton(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isEnabled ? settingsAccentColor : Color(.quaternaryLabel))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
        guard let clipboardValue = UIPasteboard.general.string else {
            return
        }

        #if targetEnvironment(simulator)
        guard let payload = try? decodePairingPayload(from: clipboardValue) else {
            return
        }
        onScan(payload)
        #else
        if let payload = try? decodePairingPayload(from: clipboardValue) {
            onScan(payload)
        } else {
            viewModel.scannerError = "Clipboard does not contain a valid pairing payload."
        }
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

@MainActor
@Observable
final class QRScannerViewModel {
    var hasCameraPermission = false
    var isCheckingPermission = true
    var scannerError: String?
    var isShowingManualEntry = false
    var manualEntryText = ""

    var canSubmitManualEntry: Bool {
        !manualEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearManualEntry() {
        manualEntryText = ""
    }

    func dismissManualEntry() {
        isShowingManualEntry = false
        clearManualEntry()
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
