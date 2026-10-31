// Import Apple's SwiftUI framework, the toolkit that provides View, Text,
// Button, VStack, and all the other UI building blocks used below.
import SwiftUI

// MARK: - Main Search View

/// The search screen where users find songs, artists, and albums on YouTube Music.
///
/// HOW IT WORKS:
/// 1. User types in the search bar → suggestions appear as they type
/// 2. User taps search (or a suggestion) → results load from YouTube's API
/// 3. User taps a result → song starts playing
/// 4. User long-presses a result → context menu with Play/Play Next/Add to Queue
///
/// This view manages 4 states: idle, typing suggestions, loading, and results.
///
/// NOTE ON STRUCTURE: SwiftUI views describe *what* the screen should look
/// like for the current data ("declarative UI"), and SwiftUI takes care of
/// drawing (and redrawing) it whenever that data changes. A `View` here is a
/// `struct` (a lightweight value type, copied rather than shared by
/// reference) that conforms to the `View` protocol, meaning it promises a
/// `body` computed property describing its contents. This file is the
/// largest view in the app, so to keep it readable it's broken into several
/// small, independently-named types (`SearchBar`, `SuggestionsList`,
/// `SearchResultsList`, etc.) and, within `SearchView` itself, several small
/// computed properties (`filterBar`, `resultsSection`, etc.) that `body`
/// assembles like puzzle pieces instead of nesting everything inline.
struct SearchView: View {

    /// The API client handles all YouTube Music API calls.
    /// Injected via `@EnvironmentObject`, a property wrapper that reads a
    /// shared object out of the SwiftUI "environment" (a bag of shared data
    /// available to a view and all of its children) instead of it being
    /// passed in explicitly. That's how child views like `SearchResultsList`
    /// can also reach the same `APIClient` without us threading it through
    /// every initializer by hand.
    @EnvironmentObject var apiClient: APIClient

    /// The audio player handles playback. Injected via environment.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The search history manager, saves and loads recent searches.
    @EnvironmentObject var searchHistory: SearchHistoryManager

    /// The current text in the search field. `@State` means this view "owns"
    /// this value, SwiftUI stores it outside the struct itself (since
    /// structs are normally copied, not mutated in place) and automatically
    /// re-renders `body` whenever it changes.
    @State private var searchText = ""

    /// Whether the user has submitted a search (tapped Search or selected a suggestion).
    /// This controls whether we show results vs the idle/suggestions state.
    @State private var isSearching = false

    /// Autocomplete suggestions from YouTube. Populated as the user types.
    @State private var suggestions: [String] = []

    /// Controls whether the queue sheet is shown (presented modally).
    @State private var showQueue = false

    /// The currently selected search filter.
    /// nil = All, "songs" = Songs, "videos" = Videos, "albums" = Albums
    @State private var selectedFilter: String? = nil

    /// Available filter options with their display names.
    /// This is a `let` (constant) array of named tuples, each element bundles
    /// a human-readable `name` with the `key` string the API expects (or `nil`
    /// for "no filter"). Tuples are a lightweight way to group a couple of
    /// related values without declaring a whole new type.
    let filters: [(name: String, key: String?)] = [
        ("All", nil),
        ("Songs", "songs"),
        ("Videos", "videos"),
        ("Albums", "albums")
    ]

    var body: some View {
        NavigationView {
            // spacing: 0 means the sections below sit flush against each
            // other, each section adds its own internal padding as needed.
            VStack(spacing: 0) {
                searchBarSection
                suggestionsSection
                filterBarSection
                resultsSection
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            // Show error banner if search failed.
            // `.overlay(alignment:)` draws content on top of this view without
            // affecting its layout, here, pinned to the top edge.
            .overlay(alignment: .top) {
                // `if let` unwraps the optional `errorMessage`: the banner
                // only appears when there actually is an error string to show.
                if let error = apiClient.errorMessage {
                    ErrorBanner(message: error) {
                        performSearch()
                    }
                }
            }
            .toolbar {
                // Queue button in the top-right corner of the nav bar
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showQueue = true // Triggers the .sheet modifier below
                    }) {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            // .sheet presents a modal that slides up from the bottom.
            // It stays visible until the user dismisses it (swipe down or tap Done).
            // Unlike .fullScreenCover, it doesn't cover the entire screen.
            .sheet(isPresented: $showQueue) {
                QueueView()
            }
        }
    }

    // MARK: - Body Sections
    // Each of these computed properties is one self-contained piece of the
    // search screen. Splitting them out keeps `body` short enough to read
    // top-to-bottom as an outline of the screen, and makes each piece easy
    // to reason about (or move/reuse) on its own.

    /// The search text field itself, wired up to this view's state.
    private var searchBarSection: some View {
        // Pass bindings ($) so the SearchBar can read AND write these values.
        // A "binding" (`Binding<T>`) is a two-way reference to a piece of
        // state owned somewhere else, writing to it here updates the
        // original `@State` in `SearchView`, and SwiftUI re-renders both
        // sides. When SearchBar changes searchText, SearchView sees the update.
        SearchBar(
            text: $searchText,
            isSearching: $isSearching,
            onSearchButtonClicked: {
                performSearch()
            },
            onTextChanged: { newValue in
                // Load suggestions as user types (but not during an active search).
                // `Task { ... }` kicks off an async unit of work, asynchronous
                // code can `await` slow operations like network calls without
                // freezing the rest of the app while it waits.
                Task {
                    await loadSuggestions(for: newValue)
                }
            }
        )
    }

    /// The autocomplete dropdown, shown only while the user is actively typing
    /// (not yet searching) and suggestions are available.
    private var suggestionsSection: some View {
        // Show suggestions only when:
        //   1. User has typed something (!searchText.isEmpty)
        //   2. We have suggestions to show (!suggestions.isEmpty)
        //   3. User hasn't submitted a search yet (!isSearching)
        // If any of these is false, the suggestions list is hidden.
        //
        // `Group` lets us return one of two possible views (the list, or
        // nothing) from a single computed property, which SwiftUI requires
        // to have one consistent return type.
        Group {
            if !searchText.isEmpty && !suggestions.isEmpty && !isSearching {
                SuggestionsList(suggestions: suggestions) { suggestion in
                    // When user taps a suggestion, fill the search bar and search
                    searchText = suggestion
                    performSearch()
                }
            }
        }
    }

    /// Horizontal scroll of pill-shaped filter buttons (All, Songs, Videos,
    /// Albums), shown only once a search has been performed.
    private var filterBarSection: some View {
        Group {
            if isSearching {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // `ForEach` turns each element of a collection into a
                        // view. `id: \.name` tells SwiftUI how to tell the
                        // rows apart (here, by each filter's unique display
                        // name) so it can track which one is which across
                        // re-renders, required because `filters` isn't an
                        // array of `Identifiable` elements.
                        ForEach(filters, id: \.name) { filter in
                            FilterPill(
                                name: filter.name,
                                isSelected: selectedFilter == filter.key,
                                action: {
                                    // Update the selected filter and re-search
                                    selectedFilter = filter.key
                                    performSearch()
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// The main content area below the search bar/filters, whichever of the
    /// four search states currently applies.
    private var resultsSection: some View {
        Group {
            if isSearching {
                activeSearchContent
            } else {
                idleContent
            }
        }
    }

    /// Content shown once a search has been submitted: loading skeleton,
    /// "no results" message, or the actual results list.
    @ViewBuilder
    private var activeSearchContent: some View {
        // `@ViewBuilder` lets this computed property contain an `if/else if/else`
        // chain that returns a *different* view type from each branch, normally
        // Swift requires a single consistent return type, but `@ViewBuilder`
        // (the same mechanism `body` itself uses under the hood) relaxes that
        // for SwiftUI view code.
        if apiClient.isLoading {
            // State 1: Loading, show skeleton search result rows
            loadingSkeletonView
        } else if apiClient.searchResults.isEmpty && !searchText.isEmpty {
            // State 2: No results, show empty state message
            noResultsView
        } else {
            // State 3: Results, show the list
            SearchResultsList(results: apiClient.searchResults)
        }
    }

    /// Skeleton ("shimmer") placeholder rows shown while search results are loading.
    /// These mimic the shape of the real result rows so the layout doesn't
    /// jump once real data arrives.
    private var loadingSkeletonView: some View {
        VStack(spacing: 0) {
            // `0..<6` is a Range, the integers 0 through 5. We don't care
            // about the actual number for each iteration (there's no real
            // data yet), so the closure parameter is named `_` to say
            // "ignore this value".
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    // Thumbnail skeleton
                    SkeletonView(width: 56, height: 56, cornerRadius: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        // Title skeleton
                        SkeletonView(width: 200, height: 14, cornerRadius: 4)
                        // Artist skeleton
                        SkeletonView(width: 140, height: 12, cornerRadius: 4)
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Empty-state message shown when a search returned zero results.
    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No results found")
                .font(.headline)
            Text("Try a different search term")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// Content shown before any search has been performed: recent search
    /// history, or a first-run placeholder if there's no history yet.
    @ViewBuilder
    private var idleContent: some View {
        if searchHistory.searches.isEmpty {
            // No history yet, show placeholder
            EmptySearchView()
        } else {
            // Show recent searches list
            SearchHistoryList(
                searches: searchHistory.searches,
                onSelect: { query in
                    searchText = query
                    performSearch()
                },
                onDelete: { query in
                    searchHistory.removeSearch(query)
                },
                onClearAll: {
                    searchHistory.clearHistory()
                }
            )
        }
    }

    // MARK: - Private Methods

    /// Execute a search using the current search text.
    ///
    /// GUARD: We trim whitespace and check for empty to prevent searching
    /// for just spaces (which YouTube would return no results for).
    /// `.whitespacesAndNewlines` removes spaces, tabs, and newlines.
    private func performSearch() {
        // `guard ... else { return }` checks a condition up front and exits
        // the function immediately if it's not satisfied, it reads as
        // "make sure this is true, otherwise stop here" and keeps the rest
        // of the function free of an extra nesting level.
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return // Don't search for empty/whitespace-only queries
        }

        // Save to search history before performing the search
        searchHistory.addSearch(searchText)

        isSearching = true   // Switch to results state
        suggestions = []     // Clear suggestions (they're hidden during search)

        // Task = start an async operation without blocking the UI.
        // The UI stays responsive while the API call happens in the background.
        Task {
            await apiClient.search(query: searchText, filter: selectedFilter)
        }
    }

    /// Fetch autocomplete suggestions as the user types.
    ///
    /// Suggestions are fetched after 2+ characters to avoid too many API calls.
    /// We limit to 8 suggestions to keep the dropdown manageable.
    /// Failures are silently ignored, suggestions are a nice-to-have, not critical.
    private func loadSuggestions(for query: String) async {
        // Don't fetch suggestions for 1-character queries (too broad)
        guard query.count >= 2 else {
            suggestions = []
            return
        }

        do {
            // Access the InnerTube client directly through the APIClient.
            // This is a slight architectural shortcut, normally we'd add
            // a `getSuggestions()` method to APIClient, but for suggestions
            // it's simpler to call the client directly since there's no
            // loading state or error handling needed.
            let newSuggestions = try await apiClient.client.getSearchSuggestions(query: query)
            // .prefix(8) takes only the first 8 elements, then Array() converts
            // the SubSequence back to a regular Array (needed for @State)
            suggestions = Array(newSuggestions.prefix(8))
        } catch {
            // Silently fail, suggestions are optional, not critical
            print("Failed to load suggestions: \(error)")
        }
    }
}

// MARK: - Filter Pill

/// A single pill-shaped filter button (e.g. "All", "Songs") used in the
/// horizontal filter bar. Pulled out of `filterBarSection` so that one row's
/// styling logic isn't buried inside a `ForEach` closure.
struct FilterPill: View {

    /// The display text for this filter (e.g. "Songs")
    let name: String

    /// Whether this is the currently active filter, changes the pill's
    /// fill color and text weight.
    let isSelected: Bool

    /// Called when the user taps this pill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Pill shape: filled when selected, outlined when not
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Search Bar Component

/// The search input field with cancel button and voice search.
///
/// This is a separate struct so it can manage its own @FocusState
/// (keyboard focus) without cluttering the parent view.
/// Includes a microphone button for voice-to-text search.
struct SearchBar: View {

    /// Two-way binding to the parent's search text.
    /// When the user types here, the parent sees the update.
    @Binding var text: String

    /// Two-way binding to the parent's searching state.
    /// Set to true when search is submitted.
    @Binding var isSearching: Bool

    /// Called when the user taps the Search button on the keyboard.
    /// This property's type, `() -> Void`, is a "closure", a chunk of code
    /// that can be passed around and called later, like a function stored in
    /// a variable. It takes no arguments and returns nothing (`Void`).
    var onSearchButtonClicked: () -> Void

    /// Called every time the text changes (for live suggestions).
    /// This closure takes a `String` argument (the new text) and returns nothing.
    var onTextChanged: (String) -> Void

    /// The voice search manager, handles speech-to-text conversion.
    @EnvironmentObject var voiceSearch: VoiceSearchManager

    /// @FocusState tracks which text field has keyboard focus.
    /// When isFocused is true, the keyboard is showing for this field.
    /// When we set isFocused = false, the keyboard dismisses.
    /// This is a SwiftUI-specific property wrapper for keyboard management.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            searchField
            cancelButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Animate when focus or search state changes (smooth appear/disappear).
        // `.animation(_:value:)` tells SwiftUI to smoothly transition any
        // visual changes that happen as a *result* of `isFocused` or
        // `isSearching` changing, instead of the UI snapping instantly.
        .animation(.easeInOut, value: isFocused)
        .animation(.easeInOut, value: isSearching)
    }

    /// The rounded text-entry field, including the magnifying-glass icon,
    /// the optional microphone button, and the optional clear ("x") button.
    private var searchField: some View {
        HStack {
            // Magnifying glass icon inside the search field
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            // TextField = single-line text input
            // $text = binding to our text state
            // .focused($isFocused) = track keyboard focus for this field
            // .onSubmit = called when user taps "Search" on the keyboard
            TextField("Search songs, artists, albums...", text: $text)
                .textFieldStyle(.plain) // Remove default border styling
                .focused($isFocused)
                .onSubmit {
                    onSearchButtonClicked()
                }
                // .onChange fires every time `text` changes.
                // The closure receives the new value.
                // We forward it to the parent's callback for live suggestions.
                .onChange(of: text) { newValue in
                    onTextChanged(newValue)
                }

            voiceSearchButton

            // Clear button (X icon), only shows when there's text
            if !text.isEmpty {
                Button(action: {
                    text = ""
                    isSearching = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6)) // Light gray background
        .cornerRadius(10) // Rounded corners
    }

    /// Microphone button for voice search, only shows if speech recognition
    /// is available on this device (some devices/locales don't support it).
    @ViewBuilder
    private var voiceSearchButton: some View {
        if voiceSearch.isAvailable {
            Button(action: {
                if voiceSearch.isListening {
                    // Stop listening, use the recognized text as the search query
                    voiceSearch.stopListening()
                    if !voiceSearch.recognizedText.isEmpty {
                        text = voiceSearch.recognizedText
                        onSearchButtonClicked()
                    }
                    voiceSearch.reset()
                } else {
                    // Start listening, clear any previous result
                    voiceSearch.reset()
                    voiceSearch.startListening()
                }
            }) {
                Image(systemName: voiceSearch.isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .foregroundColor(voiceSearch.isListening ? .red : .blue)
                    .font(.title3)
            }
        }
    }

    /// "Cancel" button that appears while the field is focused or a search is active.
    /// Only shows when the search field is focused or a search is active.
    /// `.transition(.move(edge: .trailing))` = animate in from the right edge.
    @ViewBuilder
    private var cancelButton: some View {
        if isFocused || isSearching {
            Button("Cancel") {
                text = ""           // Clear search text
                isSearching = false // Exit search state
                isFocused = false   // Dismiss keyboard
                voiceSearch.stopListening() // Stop voice search if active
                voiceSearch.reset()
            }
            .transition(.move(edge: .trailing))
        }
    }
}

// MARK: - Suggestions List

/// Dropdown list of autocomplete suggestions shown while typing.
///
/// Each suggestion is a tappable row. When tapped, it triggers the search.
struct SuggestionsList: View {

    /// The suggestion strings from YouTube's API
    let suggestions: [String]

    /// Called when the user taps a suggestion, passes the selected text
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            // LazyVStack = VStack that only creates rows when they scroll into view
            // (better performance than VStack for long lists)
            LazyVStack(spacing: 0) {
                // id: \.self means each string is its own identity
                // (SwiftUI needs this for ForEach to track items)
                ForEach(suggestions, id: \.self) { suggestion in
                    SuggestionRow(suggestion: suggestion) {
                        onSelect(suggestion)
                    }
                }
            }
        }
        .frame(maxHeight: 300) // Don't let suggestions take over the screen
        .background(Color(.systemBackground))
    }
}

/// A single tappable row inside `SuggestionsList`, with a trailing divider.
struct SuggestionRow: View {

    /// The suggestion text to display
    let suggestion: String

    /// Called when this row is tapped
    let onTap: () -> Void

    var body: some View {
        // Using a `Group` lets us attach the `Divider` alongside the button
        // as siblings within the parent `LazyVStack`, matching the original
        // (non-boxed) row layout.
        Group {
            Button(action: onTap) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .frame(width: 24) // Fixed width so text aligns

                    Text(suggestion)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            // Divider between suggestions
            Divider()
                .padding(.leading, 44) // Indent to match text position
        }
    }
}

// MARK: - Search Results List

/// List of search results with context menu support.
///
/// Each result can be:
/// - Tapped → play immediately
/// - Long-pressed → context menu (Play, Play Next, Add to Queue, Add to Playlist, Download)
struct SearchResultsList: View {

    /// The search results from the API
    let results: [SearchResult]

    /// Audio player for controlling playback
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// API client for fetching player info (stream URLs)
    @EnvironmentObject var apiClient: APIClient

    /// Offline manager for downloading songs
    @EnvironmentObject var offlineManager: OfflineManager

    /// Playlist manager for adding songs to playlists
    @EnvironmentObject var playlistManager: PlaylistManager

    /// The song currently being added to a playlist (shows playlist picker)
    @State private var songToAddToPlaylist: SearchResult?

    /// Whether to show the playlist picker sheet
    @State private var showPlaylistPicker = false

    /// The song whose details are being shown
    @State private var songForDetails: NowPlaying?

    /// Whether to show the song detail sheet
    @State private var showSongDetails = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    resultRow(for: result)
                }
            }
        }
        // Playlist picker sheet, shows when user taps "Add to Playlist"
        .sheet(isPresented: $showPlaylistPicker) {
            // `songToAddToPlaylist` is an optional (`SearchResult?`) because
            // there's no song selected until the user taps "Add to Playlist".
            // `if let` only builds the sheet's contents once a result exists.
            if let result = songToAddToPlaylist {
                PlaylistPickerSheet(
                    result: result,
                    isPresented: $showPlaylistPicker
                )
            }
        }
        // Song details sheet, shows play count, last played, actions
        .sheet(isPresented: $showSongDetails) {
            if let song = songForDetails {
                SongDetailView(
                    videoId: song.id,
                    title: song.title,
                    artist: song.artist,
                    thumbnailUrl: song.thumbnailUrl,
                    duration: "\(song.duration)"
                )
            }
        }
    }

    /// Builds one result row plus its tap/long-press behavior and trailing divider.
    /// Pulled out of `body` so the `ForEach` closure stays short and the
    /// (fairly long) context menu definition isn't nested three levels deep.
    @ViewBuilder
    private func resultRow(for result: SearchResult) -> some View {
        SearchResultRow(result: result, moreMenuContent: AnyView(contextMenuContent(for: result)))
            .onTapGesture {
                // Tap = play this song immediately
                playResult(result)
            }
            // .contextMenu = long-press menu (like right-click on desktop).
            .contextMenu {
                contextMenuContent(for: result)
            }

        // Divider line between results (indented to align with text)
        Divider()
            .padding(.leading, 76)
    }

    /// The long-press context menu's buttons for a given result: Play, Play
    /// Next, Add to Queue, Download, Add to Playlist, and Song Info.
    @ViewBuilder
    private func contextMenuContent(for result: SearchResult) -> some View {
        Button(action: {
            playResult(result)
        }) {
            Label("Play", systemImage: "play.fill")
        }

        Button(action: {
            addNextToQueue(result)
        }) {
            Label("Play Next", systemImage: "arrow.up.next")
        }

        Button(action: {
            addToQueue(result)
        }) {
            Label("Add to Queue", systemImage: "plus")
        }

        // Download option, only shows if not already downloaded
        if !offlineManager.isDownloaded(result.id) {
            Button(action: {
                downloadResult(result)
            }) {
                Label("Download", systemImage: "arrow.down.circle")
            }
        } else {
            // Show "Downloaded" with checkmark if already cached
            Label("Downloaded", systemImage: "checkmark.circle.fill")
        }

        // Add to Playlist option, shows playlist picker
        if !playlistManager.playlists.isEmpty {
            Button(action: {
                songToAddToPlaylist = result
                showPlaylistPicker = true
            }) {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }

        // Song Info, shows detailed info about this song
        Button(action: {
            songForDetails = NowPlaying(
                id: result.id,
                title: result.title,
                artist: result.artist,
                thumbnailUrl: result.thumbnailUrl,
                duration: 0,
                audioUrl: ""
            )
            showSongDetails = true
        }) {
            Label("Song Info", systemImage: "info.circle")
        }
    }

    // MARK: - Playback Actions

    /// Play a search result immediately.
    ///
    /// FLOW: SearchResult → fetch streaming URL via API → play via AudioPlayer
    /// We need to call getPlayerInfo() first because SearchResult only has the
    /// video ID, not the actual audio streaming URL.
    private func playResult(_ result: SearchResult) {
        Task {
            do {
                // Get the streaming URL and metadata for this video
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id)

                // Play the song, this clears the queue and starts playing
                await audioPlayer.play(
                    videoId: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    audioUrl: playerInfo.audioUrl,
                    duration: playerInfo.duration
                )
            } catch {
                print("Failed to play: \(error)")
            }
        }
    }

    /// Add a song to play next (insert after the current song in the queue).
    ///
    /// FLOW: SearchResult → fetch streaming URL → create NowPlaying → insert into queue
    /// NOTE: These 3 methods (playResult, addNextToQueue, addToQueue) share
    /// most of their code. They could be refactored into a single helper method
    /// that accepts an action parameter. For now, they're kept separate for clarity.
    private func addNextToQueue(_ result: SearchResult) {
        Task {
            do {
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id)

                // Create a NowPlaying object from the player info
                let song = NowPlaying(
                    id: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    duration: playerInfo.duration,
                    audioUrl: playerInfo.audioUrl
                )

                // Insert right after the current song
                audioPlayer.playNext(song)
            } catch {
                print("Failed to get player info: \(error)")
            }
        }
    }

    /// Add a song to the end of the queue.
    ///
    /// Same flow as addNextToQueue, but appends instead of inserting.
    private func addToQueue(_ result: SearchResult) {
        Task {
            do {
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id)

                let song = NowPlaying(
                    id: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    duration: playerInfo.duration,
                    audioUrl: playerInfo.audioUrl
                )

                // Append to end of queue
                audioPlayer.addToQueue(song)
            } catch {
                print("Failed to get player info: \(error)")
            }
        }
    }

    /// Download a song for offline playback.
    ///
    /// FLOW: SearchResult → fetch streaming URL (with download quality) → download audio file to cache
    /// The OfflineManager handles the actual download and file storage.
    private func downloadResult(_ result: SearchResult) {
        Task {
            do {
                // Use download quality setting (may be different from playback quality)
                let playerInfo = try await apiClient.getPlayerInfoForDownload(videoId: result.id)

                await offlineManager.download(
                    videoId: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    audioUrl: playerInfo.audioUrl,
                    thumbnailUrl: playerInfo.thumbnailUrl
                )
            } catch {
                print("Failed to get player info for download: \(error)")
            }
        }
    }
}

// MARK: - Search Result Row

/// A single row in the search results list.
///
/// Shows: thumbnail, title, artist, duration, and a "more" button.
/// The actual tap and long-press handlers are applied in SearchResultsList,
/// not here, to keep this component purely visual.
struct SearchResultRow: View {

    /// The search result data to display
    let result: SearchResult

    /// Menu content for the visible "…" button, supplied by the list
    /// (the same actions as the row's long-press context menu).
    /// When nil, the button falls back to an inert placeholder.
    var moreMenuContent: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            titleAndArtist
            Spacer() // Pushes everything to the left
            moreButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Album art thumbnail, loaded asynchronously from the result's URL.
    private var thumbnail: some View {
        // `AsyncImage` handles fetching the image over the network itself;
        // while it's loading (or if the URL fails to load), it shows the
        // `placeholder` closure's content instead.
        AsyncImage(url: URL(string: result.bestThumbnailUrl)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
        }
        .frame(width: 56, height: 56)
        .cornerRadius(4)
    }

    /// Song title and artist/duration info, stacked vertically.
    private var titleAndArtist: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .font(.body)
                .lineLimit(1)

            // Artist name with duration, separated by a bullet (•)
            // The bullet is a Text view between the two strings.
            // We check `if let duration` because duration is optional,
            // some results (like artists) don't have a duration.
            HStack(spacing: 4) {
                Text(result.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let duration = result.duration {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(duration)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    /// "More" button. When the list supplies menu content it opens
    /// that menu (same actions as the long-press context menu);
    /// otherwise it stays an inert placeholder.
    private var moreButton: some View {
        Group {
            if let moreMenuContent {
                Menu {
                    moreMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                }
            } else {
                Button(action: {}) {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                }
            }
        }
    }
}

// MARK: - Empty State

/// Placeholder shown when the search tab is idle and there's no history yet.
struct EmptySearchView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("Search for music")
                .font(.headline)

            Text("Find songs, artists, and albums")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Search History List

/// Displays recent search queries when the search bar is focused.
///
/// Each row shows the query text with a clock icon. Tapping a row
/// fills the search bar and executes the search. Swiping left reveals
/// a delete button to remove individual entries. A "Clear All" button
/// appears at the top if there's history.
struct SearchHistoryList: View {

    /// The list of recent search queries (most recent first)
    let searches: [String]

    /// Called when the user taps a search query, fills the bar and searches
    let onSelect: (String) -> Void

    /// Called when the user deletes a single search query
    let onDelete: (String) -> Void

    /// Called when the user taps "Clear All" to wipe the entire history
    let onClearAll: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Clear All button at the top
                if !searches.isEmpty {
                    clearAllHeader
                }

                // List of search queries
                ForEach(searches, id: \.self) { query in
                    SearchHistoryRow(
                        query: query,
                        onSelect: { onSelect(query) },
                        onDelete: { onDelete(query) }
                    )
                }
            }
        }
    }

    /// The "Clear All" button and its trailing divider, shown above the list
    /// whenever there's at least one saved search.
    private var clearAllHeader: some View {
        Group {
            HStack {
                Spacer()
                Button(action: onClearAll) {
                    Text("Clear All")
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            Divider()
        }
    }
}

/// A single row in `SearchHistoryList`: a past search query with a clock
/// icon, tap-to-search behavior, and a per-row delete button.
struct SearchHistoryRow: View {

    /// The search query text this row represents
    let query: String

    /// Called when the row itself is tapped (re-runs this search)
    let onSelect: () -> Void

    /// Called when the delete ("x") button is tapped
    let onDelete: () -> Void

    var body: some View {
        Group {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    // Clock icon indicates this is a past search
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .frame(width: 24)

                    // The search query text
                    Text(query)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    // Delete button for this individual entry
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    // `.buttonStyle(.plain)` stops this inner button from
                    // inheriting the outer row Button's tap styling/behavior,
                    // and (importantly) keeps its tap from also triggering
                    // the outer button's action, without it, tapping delete
                    // could also fire onSelect.
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            Divider()
                .padding(.leading, 46) // Indent to align with text
        }
    }
}

// MARK: - Playlist Picker Sheet

/// A modal sheet that lets users choose which playlist to add a song to.
///
/// Shows a list of all playlists with checkmarks next to ones that
/// already contain the song. Tapping a playlist adds the song to it.
struct PlaylistPickerSheet: View {

    /// The search result to add to a playlist
    let result: SearchResult

    /// Binding to control whether this sheet is showing
    @Binding var isPresented: Bool

    /// The playlist manager
    @EnvironmentObject var playlistManager: PlaylistManager

    /// The API client for fetching player info
    @EnvironmentObject var apiClient: APIClient

    /// The audio player for creating NowPlaying objects
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// Whether we're currently adding the song (shows loading state)
    @State private var isAdding = false

    /// Whether to show the "New Playlist" naming alert.
    /// Mirrors the exact pattern used by PlaylistsView's "New Playlist"
    /// alert, see that file for the fuller explanation of each piece.
    @State private var showNewPlaylistAlert = false

    /// The name being typed for the new playlist in the alert's TextField.
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationView {
            List {
                // Create New Playlist option at the top
                Section {
                    Button(action: {
                        // FIX: this used to silently create a playlist named
                        // "My Playlist" with no way to name it (the TODO
                        // this replaces). Now it shows a naming alert, same
                        // as the "New Playlist" flow in the Library tab.
                        showNewPlaylistAlert = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            Text("Create New Playlist")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // List of existing playlists
                Section {
                    ForEach(playlistManager.playlists) { playlist in
                        playlistRow(for: playlist)
                    }
                } header: {
                    Text("Your Playlists")
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    // Create the playlist AND immediately add the song the
                    // user was trying to save, that's the whole point of
                    // reaching this alert from the "Add to Playlist" sheet,
                    // not just an empty playlist.
                    let playlist = playlistManager.createPlaylist(name: trimmed)
                    addSongToPlaylist(playlist)
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for your new playlist")
            }
        }
    }

    /// A single row representing one of the user's playlists, showing its
    /// name, song count, and a checkmark if the current song is already in it.
    private func playlistRow(for playlist: Playlist) -> some View {
        Button(action: {
            addSongToPlaylist(playlist)
        }) {
            HStack {
                // Playlist name
                Text(playlist.name)
                    .foregroundColor(.primary)

                Spacer()

                // Song count
                Text("\(playlist.songCount) songs")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Checkmark if song is already in this playlist
                if playlistContainsSong(playlist) {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
        .disabled(isAdding)
    }

    /// Check if a playlist already contains this song.
    private func playlistContainsSong(_ playlist: Playlist) -> Bool {
        playlist.songs.contains(where: { $0.id == result.id })
    }

    /// Add the song to the selected playlist.
    ///
    /// We need to fetch the player info first to get the streaming URL,
    /// then create a NowPlaying object and add it to the playlist.
    private func addSongToPlaylist(_ playlist: Playlist) {
        guard !isAdding else { return }

        isAdding = true

        Task {
            do {
                // Fetch player info to get the streaming URL and metadata
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id)

                // Create a NowPlaying object
                let song = NowPlaying(
                    id: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    duration: playerInfo.duration,
                    audioUrl: playerInfo.audioUrl
                )

                // Add to the playlist
                playlistManager.addSong(song, to: playlist)

                // `MainActor.run` hops back onto the main thread (the one
                // responsible for updating the UI) before touching @State,
                // SwiftUI state must only be mutated from the main thread,
                // and code inside `Task { }` isn't guaranteed to already be
                // there once an `await` has suspended and resumed it.
                await MainActor.run {
                    isAdding = false
                    isPresented = false
                }
            } catch {
                print("Failed to add song to playlist: \(error)")
                await MainActor.run {
                    isAdding = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SearchView()
        .environmentObject(AudioPlayer())
        .environmentObject(APIClient())
        .environmentObject(OfflineManager())
        .environmentObject(PlaylistManager())
        .environmentObject(SearchHistoryManager())
        .environmentObject(VoiceSearchManager())
}
