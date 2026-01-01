import SwiftUI
import GhosttyKit
import os.log

// MARK: - Theme Model

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let isLight: Bool
    let content: String

    var backgroundColor: Color {
        parseColor(key: "background") ?? (isLight ? .white : .black)
    }

    var foregroundColor: Color {
        parseColor(key: "foreground") ?? (isLight ? .black : .white)
    }

    private func parseColor(key: String) -> Color? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) =") || trimmed.hasPrefix("\(key)=") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let hex = parts[1].trimmingCharacters(in: .whitespaces)
                    return Color(hex: hex)
                }
            }
        }
        return nil
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    /// Returns true if this is a light color (useful for determining theme type)
    var isLight: Bool {
        guard let components = UIColor(self).cgColor.components else { return false }
        let r = components[0]
        let g = components.count > 1 ? components[1] : r
        let b = components.count > 2 ? components[2] : r
        // Using luminance formula
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.5
    }
}

// MARK: - Theme Manager

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var themes: [Theme] = []

    private init() {
        loadBundledThemes()
    }

    private func loadBundledThemes() {
        guard let themesURL = Bundle.main.resourceURL?.appendingPathComponent("Themes") else {
            Logger.clauntty.error("ThemeManager: Could not find Themes resource directory")
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: themesURL, includingPropertiesForKeys: nil)
            themes = files.compactMap { url -> Theme? in
                // Skip hidden files and directories
                guard !url.lastPathComponent.hasPrefix("."),
                      !url.hasDirectoryPath else { return nil }

                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    Logger.clauntty.warning("ThemeManager: Could not read theme file: \(url.lastPathComponent)")
                    return nil
                }

                let name = url.lastPathComponent
                let isLight = determineIsLight(content: content)
                let id = name.lowercased().replacingOccurrences(of: " ", with: "-")

                return Theme(id: id, name: name, isLight: isLight, content: content)
            }.sorted { $0.name < $1.name }

            Logger.clauntty.info("ThemeManager: Loaded \(self.themes.count) themes")
        } catch {
            Logger.clauntty.error("ThemeManager: Failed to load themes: \(error)")
        }
    }

    private func determineIsLight(content: String) -> Bool {
        // Parse background color and determine if it's light
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background =") || trimmed.hasPrefix("background=") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let hex = parts[1].trimmingCharacters(in: .whitespaces)
                    return Color(hex: hex).isLight
                }
            }
        }
        return false
    }

    /// Get the default theme based on system appearance
    func defaultTheme(for userInterfaceStyle: UIUserInterfaceStyle) -> Theme? {
        let preferDark = userInterfaceStyle != .light

        if preferDark {
            return themes.first { $0.id == "andromeda" }
                ?? themes.first { !$0.isLight }
        } else {
            return themes.first { $0.id == "catppuccin-latte" }
                ?? themes.first { $0.isLight }
        }
    }

    /// Get a theme by ID
    func theme(withId id: String) -> Theme? {
        themes.first { $0.id == id }
    }

    /// Apply a theme to a ghostty config
    func applyTheme(_ theme: Theme, to config: ghostty_config_t) {
        theme.content.withCString { ptr in
            ghostty_config_load_string(config, ptr, UInt(theme.content.utf8.count))
        }
        Logger.clauntty.info("ThemeManager: Applied theme '\(theme.name)'")
    }

    // MARK: - Computed Properties

    var darkThemes: [Theme] {
        themes.filter { !$0.isLight }
    }

    var lightThemes: [Theme] {
        themes.filter { $0.isLight }
    }
}
