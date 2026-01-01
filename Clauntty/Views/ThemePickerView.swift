import SwiftUI

struct ThemePickerView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @ObservedObject var themeManager = ThemeManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section("Dark Themes") {
                ForEach(themeManager.darkThemes) { theme in
                    ThemeRow(
                        theme: theme,
                        isSelected: theme.id == ghosttyApp.currentThemeId
                    ) {
                        ghosttyApp.setTheme(theme)
                    }
                }
            }

            Section("Light Themes") {
                ForEach(themeManager.lightThemes) { theme in
                    ThemeRow(
                        theme: theme,
                        isSelected: theme.id == ghosttyApp.currentThemeId
                    ) {
                        ghosttyApp.setTheme(theme)
                    }
                }
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ThemeRow: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Color preview swatch
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.backgroundColor)
                    .overlay(
                        Text("Aa")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.foregroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                    .frame(width: 48, height: 32)

                Text(theme.name)
                    .foregroundColor(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        ThemePickerView()
            .environmentObject(GhosttyApp())
    }
}
