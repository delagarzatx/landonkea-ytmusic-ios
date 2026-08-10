import SwiftUI

// MARK: - Explore View

/// Browse new releases, moods, and genres from YouTube Music.
///
/// This view has three tabs:
/// 1. New Releases, recently released albums and singles
/// 2. Moods & Genres, curated playlists by mood or genre
/// 3. Explore, combined feed from YouTube Music's explore page
///
/// `struct ExploreView: View` declares a SwiftUI "View", a description of
/// some UI. SwiftUI is a "declarative" UI framework, which means instead of
/// writing step-by-step instructions for how to draw the screen, you just
/// describe *what* the screen should look like for the current state, and
/// SwiftUI figures out how to draw (and redraw) it for you.
struct ExploreView: View {

    // MARK: - Properties

    /// `@EnvironmentObject` is a "property wrapper" (a special annotation that
    /// changes how a property behaves). It means: "don't create this value
    /// here, expect some ancestor view to have already placed one into the
    /// environment (a shared bag of values available to every view below it
    /// in the view tree), and hand me a reference to it." If no ancestor
    /// provides an `APIClient`, the app will crash at runtime, so whoever
    /// creates this view's parent must call `.environmentObject(apiClient)`.
    /// The API client for fetching explore data
    @EnvironmentObject var apiClient: APIClient

    /// The audio player for playing songs
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// `@State` is a property wrapper for simple, view-local data. When a
    /// `@State` value changes, SwiftUI automatically re-runs (re-renders)
    /// this view's `body` so the screen reflects the new value. `private`
    /// means only this view's own code can read or write it, nothing
    /// outside `ExploreView` should reach in and change it directly.
    /// Selected tab: 0 = New Releases, 1 = Moods & Genres, 2 = Explore
    @State private var selectedTab = 0

    /// New releases categories
    @State private var newReleases: [ExploreCategory] = []

    /// Mood and genre categories
    @State private var moodCategories: [ExploreCategory] = []

    /// Explore page categories
    @State private var exploreSections: [ExploreCategory] = []

    /// Whether any data is currently loading
    @State private var isLoading = true

    /// `String?` is an "optional" String, it can either hold a real String
    /// value or hold nothing at all (`nil`). Swift forces you to explicitly
    /// handle the "nothing" case before using the value, which prevents a
    /// whole category of crashes common in other languages. Here, `nil`
    /// means "no error has happened."
    /// Error message if loading fails
    @State private var errorMessage: String?

    // MARK: - Body

    /// `body` is a "computed property" (a property whose value is calculated
    /// by running code, rather than stored directly) that SwiftUI calls
    /// every time it needs to know what this view looks like. `some View`
    /// means "this returns some specific type that conforms to (implements)
    /// the `View` protocol, but the exact type is an implementation detail
    /// you don't need to spell out."
    var body: some View {
        VStack(spacing: 0) {
            // Tab picker lets the user switch between the three explore tabs.
            tabPicker

            // The main content area changes based on loading/error/success state.
            contentArea
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        // `.task` is a "view modifier" (a function that wraps a view and
        // returns a new, modified view, SwiftUI's whole styling/behavior
        // system is built from chaining these). `.task` runs the given
        // asynchronous closure (a self-contained block of code that can be
        // passed around and executed later) automatically when the view
        // first appears on screen, and automatically cancels it if the view
        // disappears before it finishes.
        .task {
            await loadAll()
        }
    }

    // MARK: - Tab Picker

    /// The segmented control at the top for switching between New Releases,
    /// Moods, and Explore. Extracted into its own computed property so
    /// `body` stays short and each piece of UI has a clear name.
    private var tabPicker: some View {
        // `Picker` is a control that lets the user choose one option from a
        // set. `selection: $selectedTab` passes a "Binding", a two-way
        // connection to the `selectedTab` @State property. The `$` prefix
        // turns a `@State` property into a Binding: the Picker can both
        // read the current value AND write a new value back into
        // `selectedTab` when the user taps a different segment.
        Picker("Section", selection: $selectedTab) {
            // `.tag(0)` associates this Text with the value 0, so that when
            // the Picker's selection equals 0, this segment is the one shown
            // as selected.
            Text("New Releases").tag(0)
            Text("Moods").tag(1)
            Text("Explore").tag(2)
        }
        .pickerStyle(.segmented)
        .padding()
    }

    // MARK: - Content Area

    /// Chooses what to show below the tab picker: a spinner while loading,
    /// an error message if something failed, or the actual tab content.
    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            loadingState
        } else if let error = errorMessage {
            // `if let error = errorMessage` is "optional binding": it only
            // enters this branch when `errorMessage` is not nil, and inside
            // the branch `error` is a normal (non-optional) String.
            errorState(message: error)
        } else {
            loadedState
        }
    }

    /// Simple centered spinner shown while the three explore feeds load.
    private var loadingState: some View {
        VStack {
            Spacer()
            // `ProgressView` with no arguments is a plain spinning activity
            // indicator.
            ProgressView()
            Spacer()
        }
    }

    /// Error message with a retry button, shown if any of the network
    /// requests failed.
    private func errorState(message: String) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    // `Task { ... }` starts a new unit of asynchronous work.
                    // Button actions themselves aren't allowed to be `async`,
                    // so wrapping the `await` call in a `Task` is how we
                    // bridge from a synchronous button tap into asynchronous
                    // network-loading code.
                    Task { await loadAll() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            Spacer()
        }
    }

    /// The scrollable content for whichever tab is currently selected.
    private var loadedState: some View {
        ScrollView {
            VStack(spacing: 24) {
                // `switch` picks one branch based on the value of
                // `selectedTab`. Each `case` matches one possible tab index.
                switch selectedTab {
                case 0:
                    CategoryCarouselList(
                        categories: newReleases,
                        emptyIcon: "clock.arrow.circlepath",
                        emptyText: "No new releases found",
                        destination: destinationFor
                    )
                case 1:
                    CategoryCarouselList(
                        categories: moodCategories,
                        emptyIcon: "sparkles",
                        emptyText: "No moods available",
                        destination: destinationFor
                    )
                case 2:
                    CategoryCarouselList(
                        categories: exploreSections,
                        emptyIcon: "square.grid.2x2",
                        emptyText: "Nothing to explore right now",
                        destination: destinationFor
                    )
                default:
                    // `EmptyView()` renders nothing. `selectedTab` can only
                    // ever be 0, 1, or 2 (those are the only tags the Picker
                    // above offers), so this branch is unreachable in
                    // practice, but `switch` over an `Int` must still be
                    // "exhaustive" (cover every possible value), so Swift
                    // requires a `default` case.
                    EmptyView()
                }
            }
            .padding(.bottom, 100)
        }
    }

    // MARK: - Load Data

    /// Load all explore data in parallel.
    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        do {
            // `async let` starts three network requests at the same time
            // instead of waiting for each one to finish before starting the
            // next (which `await`-ing them one at a time would do). Each
            // `async let` binding is like a placeholder for a value that's
            // still being computed in the background.
            // Fetch all in parallel
            async let releases = apiClient.getNewReleases()
            async let moods = apiClient.getMoodCategories()
            async let explore = apiClient.getExplore()

            // `await` here pauses until all three background requests have
            // finished, then unpacks their three results into a tuple and
            // assigns them to our three @State arrays in one step. `try`
            // is required because each of these calls can throw an error
            // (e.g. a network failure); if any of them throws, execution
            // jumps to the `catch` block below.
            (newReleases, moodCategories, exploreSections) = try await (releases, moods, explore)
        } catch {
            // `error` here is the thrown error's `localizedDescription`, a
            // human-readable message we can show directly in the UI.
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Navigation Destination

    /// Determine the appropriate destination view based on item type.
    ///
    /// `@ViewBuilder` lets a function return different concrete View types
    /// from its different branches (normally a Swift function must return
    /// exactly one type) by secretly wrapping the result in a common
    /// "either-or" view type behind the scenes.
    @ViewBuilder
    private func destinationFor(_ item: BrowseItem) -> some View {
        // `item.type` is an enum (a fixed set of named possibilities) that
        // tells us what kind of thing this browse item represents, so we
        // know which detail screen to navigate to.
        switch item.type {
        case .album:
            AlbumView(browseId: item.id)
        case .artist:
            ArtistView(channelId: item.id)
        case .playlist:
            // Playlists open inline, show a simple text view
            // Full playlist browsing requires API support for fetching
            // playlist contents by browseId (future enhancement).
            PlaylistBrowseView(browseId: item.id, title: item.title)
        case .song:
            // Songs play inline, no navigation
            // Show a song detail view instead.
            // SongDetailView takes the song info as individual parameters.
            SongDetailView(
                videoId: item.id,
                title: item.title,
                artist: item.subtitle,
                thumbnailUrl: item.thumbnailUrl,
                duration: ""
            )
        }
    }
}

// MARK: - Category Carousel List

/// Renders a list of `ExploreCategory` sections, each as a title followed by
/// a horizontally scrolling carousel of items, or an empty-state message if
/// there are no categories yet.
///
/// This one component replaces what used to be three nearly-identical blocks
/// of view code (one each for New Releases, Moods, and Explore). Extracting
/// shared UI like this into a small reusable view avoids repeating the same
/// layout code three times, and means a future style tweak only has to be
/// made in one place.
struct CategoryCarouselList: View {

    /// The list of categories to display (each with its own title + items).
    let categories: [ExploreCategory]

    /// SF Symbol name shown when `categories` is empty.
    let emptyIcon: String

    /// Message shown when `categories` is empty.
    let emptyText: String

    /// A closure (a chunk of code passed around like a value) that, given a
    /// `BrowseItem`, produces the view to navigate to when that item is
    /// tapped. Passing behavior in as a closure lets this view stay generic
    ///, it doesn't need to know anything about albums, artists, or songs.
    let destination: (BrowseItem) -> AnyView

    /// Convenience initializer that lets callers pass a `@ViewBuilder`
    /// closure returning `some View` (like `ExploreView.destinationFor`)
    /// even though the type of `some View` differs per call site. We erase
    /// that to `AnyView` (a "type-erased" wrapper that can hold any View)
    /// so this struct's `destination` property can have one concrete type.
    init<Destination: View>(
        categories: [ExploreCategory],
        emptyIcon: String,
        emptyText: String,
        @ViewBuilder destination: @escaping (BrowseItem) -> Destination
    ) {
        self.categories = categories
        self.emptyIcon = emptyIcon
        self.emptyText = emptyText
        self.destination = { AnyView(destination($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if categories.isEmpty {
                ExploreEmptyState(icon: emptyIcon, text: emptyText)
            } else {
                // `ForEach` turns each element of a collection into a view.
                // SwiftUI needs a stable way to identify each element across
                // re-renders (so it can tell "this row moved" from "this row
                // was replaced"); `ExploreCategory` conforms to the
                // `Identifiable` protocol (it has a stable `id` property),
                // so `ForEach` can use that automatically.
                ForEach(categories) { category in
                    CategorySection(category: category, destination: destination)
                }
            }
        }
    }
}

/// One category's title plus its horizontally-scrolling row of item cards.
private struct CategorySection: View {
    let category: ExploreCategory
    let destination: (BrowseItem) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Category section title (e.g. "New Albums", "Chill").
            Text(category.title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal)

            // `ScrollView(.horizontal, ...)` scrolls sideways instead of up
            // and down. `showsIndicators: false` hides the little scrollbar
            // that would otherwise flash briefly while scrolling.
            // Horizontal carousel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(category.items) { item in
                        // `NavigationLink` makes its label tappable, and
                        // pushes `destination` onto the navigation stack
                        // (the "back button" stack of screens) when tapped.
                        NavigationLink(destination: destination(item)) {
                            ExploreItemCard(item: item)
                        }
                        // `.buttonStyle(.plain)` strips away the default
                        // blue tint and highlight NavigationLink applies to
                        // its label, so our custom card styling shows
                        // through unchanged.
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// A single thumbnail + title + subtitle card used inside explore carousels.
private struct ExploreItemCard: View {
    let item: BrowseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `AsyncImage` downloads and displays an image from a URL,
            // showing a placeholder while it loads. Its `phase` closure is
            // called with the current loading state (`.empty` while
            // waiting, `.success` once the image is ready, or `.failure` if
            // the download failed), so we can show different UI for each.
            // Thumbnail
            AsyncImage(url: URL(string: item.thumbnailUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 140)
                        .cornerRadius(8)
                case .failure:
                    // `URL(string:)` returns nil (and AsyncImage reports
                    // `.failure`) if `item.thumbnailUrl` is empty or
                    // malformed, or if the download itself fails, showing
                    // this gray placeholder instead of crashing keeps the
                    // app safe even when the API returns unexpected data.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 140, height: 140)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.secondary)
                        )
                case .empty:
                    ProgressView()
                        .frame(width: 140, height: 140)
                @unknown default:
                    // Swift requires this branch because `AsyncImagePhase`
                    // is a public enum Apple could add new cases to in a
                    // future SDK release; `@unknown default` future-proofs
                    // this switch against that without us having to guess
                    // what a new case might mean.
                    EmptyView()
                }
            }

            // Title
            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
                .frame(width: 140, alignment: .leading)

            // Subtitle
            Text(item.subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }
}

/// Centered icon + message shown when a category list has no items.
private struct ExploreEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Playlist Browse View

/// A simple view for browsing external playlists from YouTube Music.
///
/// This is a placeholder until full API-based playlist browsing is implemented.
/// It shows the playlist title and explains that full browsing is coming soon.
struct PlaylistBrowseView: View {
    let browseId: String
    let title: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.purple)

            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Playlist browsing coming soon")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("This playlist can be played from the YouTube Music app or website.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
