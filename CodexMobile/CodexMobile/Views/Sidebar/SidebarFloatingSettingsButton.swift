// FILE: SidebarFloatingSettingsButton.swift
// Purpose: Floating shortcut used to open sidebar settings.
// Layer: View Component
// Exports: SidebarFloatingSettingsButton

import SwiftUI

struct SidebarFloatingSettingsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        FloatingIconCircleButton(
            systemImage: "gearshape.fill",
            colorScheme: colorScheme,
            accessibilityLabel: "Settings",
            action: action
        )
    }
}

struct FloatingIconCircleButton: View {
    let systemImage: String
    let colorScheme: ColorScheme
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback()
            action()
        }) {
            Image(systemName: systemImage)
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: 44, height: 44)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}
