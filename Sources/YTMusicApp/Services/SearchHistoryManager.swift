import Foundation
import SwiftUI

// MARK: - Search History Manager

/// Manages the user's search history, saving, loading, and clearing past searches.
///
/// RESPONSIBILITIES:
/// - Save search queries when the user performs a search
/// - Load history from disk on app launch
/// - Provide history to the search view for display
/// - Allow clearing individual entries or all history
///
/// STORAGE:
/// - Uses a JSON file in the Documents directory
/// - Limited to 20 entries to keep the list manageable
/// - Most recent searches appear first
///
/// HOW IT WORKS:
/// When the user performs a search, SearchView calls addSearch().
/// This method prepends the query to the list, removes duplicates,
/// trims to 20 entries, and saves to disk. The search view reads
/// `searches` to display recent searches when the search bar is focused.
///
/// This is a `class` (reference type), not a `struct` (value type), so that
/// every part of the app sharing this object sees the exact same history,
/// there's one shared instance, not separate copies. Conforming to
/// `ObservableObject` lets SwiftUI views watch it and re-render themselves
/// automatically whenever its `@Published` data changes.
class SearchHistoryManager: ObservableObject {

    // MARK: - Published Properties

    /// The list of recent search queries, most recent first.
    /// Views observe this and re-render when it changes.
    ///
    /// `@Published` is a property wrapper (special attached behavior) that
    /// automatically broadcasts "this changed!" to any SwiftUI view watching
    /// this object, triggering a UI refresh.
    @Published var searches: [String] = []

    // MARK: - Private Properties

    /// Maximum number of search queries to keep.
    /// 20 is enough to show a useful history without cluttering the UI.
    private let maxSearches = 20

    /// File path for persisting search history as JSON.
    private let historyPath: URL

    // MARK: - Initialization

    /// Create the manager and load existing history from disk.
    ///
    /// Sets up the file path and calls loadHistory() to populate
    /// the `searches` array from the JSON file.
    init() {
        // Get the Documents directory, this is where iOS apps store user data.
        // `FileManager.default` is a shared, ready-to-use file system helper.
        // `.documentDirectory` in `.userDomainMask` is the app's own private,
        // sandboxed folder that survives between app launches. This call
        // returns an array (in theory there could be more than one match),
        // but for this combination there's always exactly one, hence `[0]`.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.historyPath = documents.appendingPathComponent("search_history.json")

        // Load any existing history from disk
        loadHistory()
    }

    // MARK: - Public Methods

    /// Add a search query to the history.
    ///
    /// - Parameter query: The search text to save
    ///
    /// BEHAVIOR:
    /// 1. Trims whitespace and ignores empty queries
    /// 2. Removes the query if it already exists (to move it to the top)
    /// 3. Prepends the new query (most recent first)
    /// 4. Trims to maxSearches (removes oldest entries)
    /// 5. Saves to disk
    func addSearch(_ query: String) {
        let trimmed = trimmedNonEmptyQuery(query)
        guard let trimmed else { return }

        moveToFront(trimmed)
        enforceMaxHistorySize()
        saveHistory()
    }

    /// Remove a single search query from the history.
    ///
    /// - Parameter query: The exact query string to remove
    func removeSearch(_ query: String) {
        // `caseInsensitiveCompare` compares two strings while ignoring
        // upper/lowercase differences, so removing "Beatles" also removes a
        // saved "beatles" entry. `removeAll(where:)` deletes every element
        // in the array for which the closure returns true.
        searches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        saveHistory()
    }

    /// Clear all search history.
    ///
    /// Called when the user taps "Clear All" in the search view.
    func clearHistory() {
        searches = []
        saveHistory()
    }

    // MARK: - Private Helpers

    /// Trims whitespace/newlines from `query` and returns `nil` if nothing
    /// meaningful is left, so callers can bail out on empty searches with a
    /// single `guard let`.
    private func trimmedNonEmptyQuery(_ query: String) -> String? {
        // `.trimmingCharacters(in:)` strips leading/trailing characters that
        // match a given set, `.whitespacesAndNewlines` covers spaces, tabs,
        // and line breaks, so " rock  " becomes "rock".
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes any existing case-insensitive match for `query`, then inserts
    /// it at the front of the list. This both de-duplicates and "bumps"
    /// a re-searched query back to the top of recents.
    private func moveToFront(_ query: String) {
        searches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        // `insert(_:at: 0)` puts the new element at the very start of the
        // array, shifting everything else back by one position.
        searches.insert(query, at: 0)
    }

    /// Drops the oldest entries so the list never grows past `maxSearches`.
    private func enforceMaxHistorySize() {
        if searches.count > maxSearches {
            // `.prefix(n)` takes the first `n` elements (the newest ones,
            // since the newest are always inserted at the front). Wrapping
            // it in `Array(...)` converts the resulting slice back into a
            // regular array we can assign to `searches`.
            searches = Array(searches.prefix(maxSearches))
        }
    }

    /// Save the current search history to disk as JSON.
    ///
    /// Uses JSONEncoder to convert the [String] array to Data,
    /// then writes it to the history file. If encoding fails,
    /// we log the error but don't crash, history is nice-to-have.
    private func saveHistory() {
        // `do`/`catch` is Swift's error-handling construct: statements
        // marked `try` inside `do` can "throw" an error, which jumps
        // execution to `catch` instead of crashing the app.
        do {
            let encoder = JSONEncoder()
            // `Codable` is a protocol (a promise a type makes: "I know how
            // to turn myself into JSON and back"). `[String]` automatically
            // conforms because `String` does, so `encode` just works here.
            let data = try encoder.encode(searches)
            try data.write(to: historyPath)
        } catch {
            print("Failed to save search history: \(error)")
        }
    }

    /// Load search history from disk.
    ///
    /// Reads the JSON file and decodes it back to [String].
    /// If the file doesn't exist or decoding fails, starts with empty history.
    private func loadHistory() {
        // Check if file exists, first launch won't have one.
        guard FileManager.default.fileExists(atPath: historyPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: historyPath)
            searches = try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("Failed to load search history: \(error)")
            searches = []
        }
    }
}
