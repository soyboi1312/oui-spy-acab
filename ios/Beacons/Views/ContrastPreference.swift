import SwiftUI
import UIKit

/// The in-app "always use higher contrast" switch, and the plumbing that turns it into the
/// `accessibilityContrast` trait every ACABTheme colour already reads.
///
/// Off means "follow the system": the window inherits the iOS Increase Contrast setting. On
/// forces the trait high on every window. So switching this off while the system setting is on
/// leaves higher contrast active, and the settings copy (SettingsView.displayCard) says so.
///
/// Android twin: ContrastMode in ui/theme/ContrastMode.kt. Same two inputs (forced || system),
/// same off-follows-system rule.
@MainActor
final class ContrastPreference: ObservableObject {
    static let shared = ContrastPreference()
    static let key = "display.alwaysHigherContrast"

    @Published var alwaysHigher: Bool {
        didSet {
            UserDefaults.standard.set(alwaysHigher, forKey: Self.key)
            applyToAllWindows()
        }
    }

    /// The SYSTEM Increase Contrast setting. Read from UIAccessibility, never from a window's
    /// trait collection: once the override below is applied, a window reports our override,
    /// not the user's setting.
    @Published private(set) var systemIncreased: Bool

    private init() {
        alwaysHigher = UserDefaults.standard.bool(forKey: Self.key)
        systemIncreased = UIAccessibility.isDarkerSystemColorsEnabled
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                ContrastPreference.shared.systemIncreased = UIAccessibility.isDarkerSystemColorsEnabled
            }
        }
    }

    /// Force the trait high, or REMOVE the override so the window inherits the system value
    /// again. Setting `.standard` instead of removing would pin the app to normal contrast
    /// even for a user whose iOS setting is on.
    func apply(to window: UIWindow) {
        if alwaysHigher {
            window.traitOverrides.accessibilityContrast = .high
        } else {
            window.traitOverrides.remove(UITraitAccessibilityContrast.self)
        }
    }

    func applyToAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { apply(to: w) }
        }
    }
}

/// Zero-size view that hands its window to ContrastPreference the moment it joins one, so a
/// freshly created window (cold launch, a new scene) carries the override before the first
/// frame the user sees. applyToAllWindows() covers later changes; this covers windows that did
/// not exist yet when the preference was last applied.
struct WindowTraitApplier: UIViewRepresentable {
    func makeUIView(context: Context) -> ApplierView {
        let v = ApplierView()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        return v
    }
    func updateUIView(_ uiView: ApplierView, context: Context) {}

    final class ApplierView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let w = window { ContrastPreference.shared.apply(to: w) }
        }
    }
}
