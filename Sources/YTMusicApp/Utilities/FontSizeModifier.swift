import SwiftUI

// MARK: - Font Size Modifier

/// A view modifier that scales the font size based on the user's preference.
///
/// USAGE:
/// Any view can read `@AppStorage("fontSizeScale") var fontSizeScale` and
/// apply it to text elements. The ContentView applies the scale factor
/// to the entire app via the `.environment(\.font)` modifier.
///
/// Scale values:
/// - 0 (Small): body = 15px (subheadline)
/// - 1 (Medium): body = 17px (default)
/// - 2 (Large): body = 20px (title3)
struct FontSizeModifier: ViewModifier {
    
    /// The font size scale setting (0 = small, 1 = medium, 2 = large).
    ///
    /// `@AppStorage` automatically reads/writes this value to `UserDefaults`
    /// (the system's small persistent key-value store) under the key
    /// "fontSizeScale", so whatever the user last picked in Settings is
    /// remembered across app launches, with no manual save/load code needed.
    @AppStorage("fontSizeScale") private var scale = 1

    func body(content: Content) -> some View {
        content
            // Set the base text style used before dynamic type scaling is applied.
            .font(.body)
            // Override the environment's dynamic type size for this view (and
            // everything below it) with the size mapped from `scale`.
            .environment(\.dynamicTypeSize, dynamicTypeSize)
    }
    
    /// Map the scale setting to SwiftUI's DynamicTypeSize.
    ///
    /// DynamicTypeSize controls how the system responds to the user's
    /// preferred text size. We map our 3-value scale to:
    /// - Small: .medium (standard accessibility)
    /// - Medium: .large (default)
    /// - Large: .xLarge (bigger)
    private var dynamicTypeSize: DynamicTypeSize {
        switch scale {
        case 0:
            return .small
        case 1:
            return .medium
        case 2:
            return .large
        default:
            return .medium
        }
    }
}

extension View {
    /// Apply the user's preferred font size scale.
    func withFontScale() -> some View {
        modifier(FontSizeModifier())
    }
}
