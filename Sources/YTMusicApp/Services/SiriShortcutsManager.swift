import Foundation  // NSObject, String, etc.
import Intents     // INInteraction, INPlayMediaIntent
import SwiftUI     // @MainActor

/// Donates Siri Shortcut activities so Siri learns user habits.
///
/// HOW IT WORKS:
/// iOS records "donated" activities and uses them to suggest Siri Shortcuts.
/// For example, if you always play "Workout Playlist" at 6 PM, Siri will
/// suggest it automatically. Users can also assign voice commands in
/// Settings → Siri & Search → Shortcuts.
///
/// This is a lightweight approach, no custom intent definition files needed.
/// We use NSUserActivity which is the simplest form of Siri integration.
///
/// This is a `struct` with only `static` members, it never gets
/// instantiated (nobody ever writes `SiriShortcutsManager()`). It exists
/// purely as a namespace grouping related functions together, the same way
/// `Foundation`'s `FileManager.default` groups file operations.
///
/// `@MainActor` is a concurrency annotation meaning "this type's code must
/// run on the main thread" (the thread responsible for UI and most
/// Apple-framework work). Marking the whole struct this way guarantees the
/// UIKit/Intents calls below never accidentally run on a background thread,
/// which some system frameworks don't tolerate.
@MainActor
struct SiriShortcutsManager {

    /// The activity type identifier, must be unique to the app.
    /// Reverse domain format: com.yourcompany.appname.action
    static let playMusicActivityType = "com.landonkea.ytmusic.play"

    /// Donate a "Play Music" shortcut whenever the user plays a song.
    ///
    /// Siri learns from repeated donations. NSUserActivity ensures the
    /// system knows this app can handle "play music" requests.
    ///
    /// - Parameters:
    ///   - title: Song title (e.g. "Bohemian Rhapsody")
    ///   - artist: Artist name (e.g. "Queen")
    ///   - videoId: YouTube video ID for deep linking
    static func donatePlaySong(title: String, artist: String, videoId: String) {
        let activity = makeDiscoverableActivity(
            title: "Play \(title)",
            invocationPhrase: "Play \(title)"
        )

        // `userInfo` stores custom data as a dictionary of [String: Any].
        // This is handed back to the app if the user later triggers this
        // shortcut, so we can know exactly which song to play without
        // re-searching for it.
        activity.userInfo = [
            "videoId": videoId,
            "title": title,
            "artist": artist
        ]

        donate(activity, logLabel: "Play \(title)")
    }

    /// Donate a shortcut for resuming playback.
    ///
    /// Called when the user starts/resumes listening. Siri can learn
    /// "Resume my music" as a common pattern.
    static func donateResumePlayback() {
        let activity = makeDiscoverableActivity(
            title: "Resume Music",
            invocationPhrase: "Play my music"
        )
        donate(activity, logLabel: "Resume Music")
    }

    /// Donate a shortcut for a specific playlist.
    ///
    /// - Parameter playlistName: The name of the playlist (e.g. "Workout Jams")
    static func donatePlayPlaylist(name: String) {
        let activity = makeDiscoverableActivity(
            title: "Play \(name)",
            invocationPhrase: "Play \(name)"
        )
        activity.userInfo = [
            "playlist": name
        ]
        donate(activity, logLabel: "Play \(name)")
    }

    // MARK: - Private Helpers

    /// Builds an `NSUserActivity`, "a thing the user did that Siri/Spotlight
    /// can learn about", configured so it's eligible to be surfaced by both
    /// Siri suggestions and Spotlight search.
    ///
    /// Every donation method above needs an activity with the same
    /// discoverability flags set, so that shared setup lives here once
    /// instead of being copy-pasted three times (which previously made it
    /// easy for the copies to drift out of sync with each other).
    ///
    /// - Parameters:
    ///   - title: Text shown to the user in the Shortcuts app / Siri suggestion UI.
    ///   - invocationPhrase: The phrase Siri suggests the user say aloud.
    /// - Returns: A configured (but not yet donated) `NSUserActivity`.
    private static func makeDiscoverableActivity(
        title: String,
        invocationPhrase: String
    ) -> NSUserActivity {
        // `NSUserActivity(activityType:)` creates a new activity tagged with
        // our app-specific identifier, so iOS knows which app owns it.
        let activity = NSUserActivity(activityType: playMusicActivityType)

        // Title appears in Siri Shortcuts UI.
        activity.title = title

        // Suggested invocation phrase, what the user can say to Siri.
        activity.suggestedInvocationPhrase = invocationPhrase

        // Make it eligible for Siri suggestions.
        activity.isEligibleForSearch = true      // Appears in Spotlight search results.
        activity.isEligibleForPrediction = true  // Siri can proactively predict/suggest it.

        return activity
    }

    /// Persists (`becomeCurrent()`) the activity so Siri remembers it
    /// happened, and logs it for debugging. Centralizing this means every
    /// donation call is logged consistently and none can forget the
    /// `becomeCurrent()` call, which is the step that actually registers the
    /// donation with the system, without it, none of the flags set above
    /// have any effect.
    private static func donate(_ activity: NSUserActivity, logLabel: String) {
        activity.becomeCurrent()
        print("Donated Siri shortcut: \(logLabel)")
    }
}
