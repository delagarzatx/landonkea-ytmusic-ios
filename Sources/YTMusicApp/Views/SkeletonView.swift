// Import Apple's SwiftUI framework, provides View, Color, Rectangle,
// GeometryReader, Animation, and all other UI tools used here
import SwiftUI

// MARK: - Skeleton View

/// A placeholder view with a shimmer animation for loading states.
///
/// Shows a gray rectangle with a moving gradient that creates a "shimmer" effect.
/// Used to indicate content is loading, giving the user visual feedback that
/// something is happening (better than a blank screen or spinner).
///
/// GLOSSARY (terms explained here the first time they appear in this file):
/// - **struct**: a Swift value type. Every SwiftUI view is a `struct` that
///   conforms to (adopts the rules of) the `View` protocol.
/// - **protocol**: a contract that says "any type that conforms to me must
///   provide these things." `View` requires a `body` computed property.
/// - **computed property**: a property (like `body`) whose value is calculated
///   by running code each time it's accessed, instead of being stored in memory.
/// - **@State**: a property wrapper (a special annotation starting with `@`)
///   that tells SwiftUI "this value can change over time, and when it does,
///   redraw any view that depends on it." State only lives as long as the view
///   is on screen.
/// - **view modifier**: a method like `.fill(...)`, `.frame(...)`, or
///   `.cornerRadius(...)` that returns a new, modified version of a view.
///   Modifiers are chained together to build up a view's final appearance.
/// - **declarative UI**: instead of writing step-by-step instructions for how
///   to draw and update the screen, you describe *what* the UI should look like
///   for a given state, and SwiftUI figures out how to make the screen match.
struct SkeletonView: View {

    /// The width of the skeleton element in points (e.g. 100 for a 100pt-wide placeholder)
    let width: CGFloat

    /// The height of the skeleton element in points (e.g. 100 for a 100pt-tall placeholder)
    let height: CGFloat

    /// Corner radius for rounded corners, makes the skeleton look softer by default (8pt)
    let cornerRadius: CGFloat

    /// The current phase of the shimmer animation (0.0 to 1.0).
    /// Starts at 0 and animates to 1.0, making the highlight slide across the view.
    /// Marked `@State` because this value changes continuously while the view is
    /// visible (SwiftUI redraws the view every time `phase` updates).
    @State private var phase: CGFloat = 0

    /// Creates a skeleton loading placeholder with a shimmer animation
    /// - Parameters:
    ///   - width: The width of the skeleton placeholder
    ///   - height: The height of the skeleton placeholder
    ///   - cornerRadius: How rounded the corners should be (defaults to 8 points)
    init(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 8) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    /// The body of the skeleton view, draws the shimmering rectangle.
    /// Kept small on purpose: it just lays out the base shape and attaches the
    /// moving highlight, while the gradients themselves live in their own
    /// computed properties below (`baseGradient`) and a helper method
    /// (`movingHighlight(in:)`). Splitting a view into small named pieces like
    /// this makes each piece easy to read and re-use on its own.
    var body: some View {
        // GeometryReader is a container view that doesn't draw anything itself,
        // instead it hands you a `geometry` value describing the size and
        // position it was given, so its children can size themselves relative
        // to their parent instead of using a fixed number.
        GeometryReader { geometry in
            // The base shape, a simple filled rectangle
            Rectangle()
                // Fills the rectangle with the still (non-moving) gray gradient
                .fill(baseGradient)
                // Apply an overlay that draws the moving highlight on top of the base
                .overlay(movingHighlight)
                // Applies rounded corners to both the base and the overlay together.
                // Because `.cornerRadius` is applied after `.overlay`, it clips
                // both layers as one shape rather than rounding them separately.
                .cornerRadius(cornerRadius)
        }
        // Constrains the entire GeometryReader to the requested width and height
        .frame(width: width, height: height)
        // .onAppear runs a closure (a self-contained block of code you can pass
        // around, like a mini anonymous function) once, the moment this view
        // first appears on screen.
        .onAppear {
            // withAnimation wraps a state change so SwiftUI animates the
            // transition smoothly instead of jumping instantly to the new value.
            withAnimation(
                Animation
                    // Uses ease-in-out timing, starts slow, speeds up, ends slow
                    .easeInOut(duration: 1.5)
                    // Repeats forever without reversing (loops back to start instantly)
                    .repeatForever(autoreverses: false)
            ) {
                // Animates phase from 0.0 to 1.0, sliding the highlight across
                phase = 1.0
            }
        }
    }

    /// The static gray gradient used as the skeleton's base fill.
    /// Pulled out into its own computed property so `body` stays focused on
    /// *layout* (what goes where) rather than *coloring* (what it looks like).
    private var baseGradient: LinearGradient {
        LinearGradient(
            // Gradient(colors:) defines a sequence of color "stops" that blend
            // smoothly into each other.
            gradient: Gradient(
                colors: [
                    // Darker gray at the start (30% opacity)
                    Color.gray.opacity(0.3),
                    // Brighter gray in the middle (50% opacity), the "shimmer" peak
                    Color.gray.opacity(0.5),
                    // Darker gray at the end (30% opacity)
                    Color.gray.opacity(0.3)
                ]
            ),
            // Gradient starts from the left edge
            startPoint: .leading,
            // Gradient ends at the right edge
            endPoint: .trailing
        )
    }

    /// The moving highlight band that slides left-to-right to create the
    /// "shimmer" illusion. Uses its own `GeometryReader` so it can size and
    /// position itself relative to the rectangle it's overlaid on top of
    /// (rather than the whole screen).
    private var movingHighlight: some View {
        GeometryReader { proxy in
            Rectangle()
                // Fills the highlight with a transparent → white → transparent gradient
                .fill(
                    LinearGradient(
                        gradient: Gradient(
                            colors: [
                                // Fully transparent on the left edge of the highlight
                                .clear,
                                // White with 30% opacity in the center of the highlight
                                .white.opacity(0.3),
                                // Fully transparent on the right edge of the highlight
                                .clear
                            ]
                        ),
                        // Highlight gradient also goes left-to-right,
                        // to match the base gradient direction
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                // The highlight is half the width of the parent rectangle
                .frame(width: proxy.size.width * 0.5)
                // Offsets the highlight horizontally based on the animation phase.
                // When phase=0, offset = -0.5 * width (hidden off the left edge).
                // When phase=1, offset = +0.5 * width (hidden off the right edge).
                // Because `phase` is animated in `body`, this offset smoothly
                // slides the highlight band all the way across the rectangle.
                .offset(x: proxy.size.width * (phase - 0.5))
        }
    }
}

// MARK: - Skeleton View Modifier

/// A view modifier that shows a skeleton while loading, then reveals the real content.
///
/// A `ViewModifier` is a reusable piece of view-transforming logic, like the
/// built-in `.padding()` or `.frame()` modifiers, but one you define yourself.
/// You implement a `body(content:)` method that receives the original view
/// (`content`) and returns a new, transformed view.
///
/// Usage: `.skeleton(isLoading: isLoading, width: 100, height: 100)`
/// When isLoading is true, the original view is hidden and a skeleton shows instead.
/// When isLoading is false, the original content is displayed normally.
struct SkeletonModifier: ViewModifier {

    /// Whether the skeleton is currently showing.
    /// When true, displays the shimmer placeholder. When false, shows the real content.
    let isLoading: Bool

    /// Width of the skeleton placeholder in points
    let width: CGFloat

    /// Height of the skeleton placeholder in points
    let height: CGFloat

    /// Applies the modifier to the content, replaces with skeleton or shows the real content
    /// - Parameter content: The original view that this modifier is applied to.
    ///   `Content` is a placeholder type supplied automatically by SwiftUI,
    ///   it stands for "whatever view this modifier gets attached to."
    /// - Returns: Either a SkeletonView or the original content
    func body(content: Content) -> some View {
        // If loading, show the shimmer placeholder instead of the real content
        if isLoading {
            SkeletonView(width: width, height: height)
        } else {
            // Otherwise, show the original content as-is
            content
        }
    }
}

// Extends the View protocol so every view gets the .skeleton() modifier.
// An `extension` adds new functionality to an existing type (here, the
// built-in `View` protocol) without needing to edit that type's original
// definition, this is how SwiftUI lets every view in the app gain a custom
// `.skeleton(...)` modifier just by importing this file.
extension View {
    /// Show a skeleton placeholder while content is loading.
    /// - Parameters:
    ///   - isLoading: When true, shows skeleton; when false, shows the original content
    ///   - width: Width of the skeleton placeholder
    ///   - height: Height of the skeleton placeholder
    /// - Returns: A view that conditionally shows skeleton or original content
    func skeleton(isLoading: Bool, width: CGFloat, height: CGFloat) -> some View {
        // Applies the SkeletonModifier to this view using the modifier() method
        modifier(SkeletonModifier(isLoading: isLoading, width: width, height: height))
    }
}

// MARK: - Skeleton Section (Home Page)

/// A skeleton placeholder for a home page section (horizontal carousel).
///
/// Shows 3-4 gray rectangles that look like song cards loading.
/// Used in HomeView while the API is fetching data.
/// Mimics the layout of the real content so the user knows what to expect.
struct SkeletonSection: View {
    /// The body of the skeleton section, a vertical stack with header + horizontal cards.
    /// Kept to just two lines by delegating to `sectionHeader` and `cardsRow`
    /// below, so each part can be read (and changed) independently.
    var body: some View {
        // A vertical stack aligned to the left with 12pt spacing
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            cardsRow
        }
    }

    /// Section header skeleton, a short wide rectangle standing in for the section title.
    private var sectionHeader: some View {
        SkeletonView(width: 150, height: 20, cornerRadius: 4)
            // Adds horizontal padding to match the real content's layout
            .padding(.horizontal)
    }

    /// Horizontal, scrollable row of card skeletons, mimics the real content's carousel.
    private var cardsRow: some View {
        // ScrollView(.horizontal) makes its contents scroll sideways instead
        // of the default up/down; `showsIndicators: false` hides the little
        // scrollbar that would otherwise flash on screen.
        ScrollView(.horizontal, showsIndicators: false) {
            // A horizontal stack with 12pt spacing between cards
            HStack(spacing: 12) {
                // ForEach repeats its content once per element in a sequence.
                // `0..<4` is a range meaning "0, 1, 2, 3" (four values), and
                // `id: \.self` tells SwiftUI to use each number itself as the
                // unique identifier for that loop iteration (since plain Ints
                // don't otherwise carry any built-in identity). The `_` means
                // we don't need to use the loop value inside the closure.
                ForEach(0..<4, id: \.self) { _ in
                    cardSkeleton
                }
            }
            // Adds horizontal padding to the entire row of cards
            .padding(.horizontal)
        }
    }

    /// A single card skeleton, album art placeholder above title/artist placeholders.
    private var cardSkeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Album art skeleton, a square placeholder (120x120)
            SkeletonView(width: 120, height: 120, cornerRadius: 8)
            // Title skeleton, a wide thin rectangle for the song name
            SkeletonView(width: 100, height: 12, cornerRadius: 4)
            // Artist skeleton, a narrower thin rectangle for the artist name
            SkeletonView(width: 80, height: 10, cornerRadius: 4)
        }
    }
}

// MARK: - Preview

/// A preview provider for Xcode's Canvas, shows what skeleton views look like at design time
#Preview {
    // A vertical stack showing the two skeleton types side-by-side
    VStack(spacing: 20) {
        // A single square skeleton placeholder (100x100)
        SkeletonView(width: 100, height: 100)
        // A full home page section skeleton with header and horizontal cards
        SkeletonSection()
    }
    // Adds padding around the entire preview
    .padding()
}
