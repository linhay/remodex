// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring for CodexService.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    private let isRunningXCTest: Bool

    init() {
        isRunningXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let service = CodexService()
        if !isRunningXCTest {
            service.configureNotifications()
        }
        _codexService = State(initialValue: service)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(codexService)
                .task {
                    guard !isRunningXCTest else {
                        return
                    }
                    await codexService.requestNotificationPermissionOnFirstLaunchIfNeeded()
                }
        }
    }
}
