import AppKit

@MainActor
enum CherryApplicationAppearance {
    static func apply(_ preference: CherryAppearancePreference) {
        apply(preference, to: .shared)
    }

    static func apply(
        _ preference: CherryAppearancePreference,
        to application: NSApplication
    ) {
        application.appearance = appearanceName(for: preference)
            .flatMap(NSAppearance.init(named:))
    }

    static func appearanceName(
        for preference: CherryAppearancePreference
    ) -> NSAppearance.Name? {
        switch preference {
        case .system:
            nil
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }
}
