# Feature Ideas

Concrete, scoped ideas for what to build next, specific to this app (an
InnerTube-based YouTube Music client for iOS/Mac Catalyst), not a generic
music-app wishlist. Each one names the existing code it would build on so
it's clear this isn't starting from zero.

Already shipped, so left off this list: playlists, liked songs, offline
downloads with Wi-Fi enforcement, an equalizer with named presets, sleep
timer with fade, crossfade, a persisted queue with history, listening
stats and a Most Played view, a Made For You mix, Siri Shortcuts, voice
search, lyrics with a fallback provider and translation, a Home Screen
widget, Mac Catalyst, CloudKit sync for playlists/liked songs, and an
in-app "Car Mode" screen with oversized touch targets.

## Platform integration

**1. Real CarPlay support.** The existing `CarModeView` is an in-app
screen with big buttons, useful, but it's not CarPlay: it still requires
holding the phone. A `CPTemplateApplicationSceneDelegate` with
`CPNowPlayingTemplate` would put playback on the car's own screen, wired
to the `MPRemoteCommandCenter` handlers `AudioPlayer` already implements
for the lock screen. The two features could coexist: CarMode for a phone
mounted on a dash without CarPlay, real CarPlay for cars that have it.

**2. Live Activity for the lock screen and Dynamic Island.** The widget
extension already reads a `NowPlayingSnapshot` written to a shared App
Group container every time the song or play state changes. A
`LiveActivity` (via `ActivityAttributes` + `ActivityKit`) could read the
same snapshot instead of duplicating that plumbing, giving Dynamic
Island/always-on-display now-playing info on top of what the widget and
lock screen controls already provide.

**3. Interactive widget controls.** iOS 17's WidgetKit added
`Button`/`Toggle` support inside widgets via App Intents. Right now
`YTMusicWidgetExtension` is read-only, tapping it opens the app. A
play/pause button that fires an `AppIntent` without launching the app
would make the widget actually useful for a quick skip.

**4. Spotlight indexing.** `CSSearchableItem`/`CSSearchableIndex` for
songs (index on play, the same moment `StatsManager` records a session)
and playlists (index on create/rename). Lets a user jump straight from
iOS search into a song without opening the app first.

**5. Handoff between devices.** Mac Catalyst support already means the
same binary runs on iPhone, iPad, and Mac. `NSUserActivity` with
`isEligibleForHandoff` on the currently playing song, updated wherever
`AudioPlayer` already publishes song changes, would let someone start a
song on their phone and pick it up on their Mac without touching the
Now Playing screen twice.

## Social and sharing

**6. SharePlay listening party.** A `GroupActivity` wrapping the current
queue, using `AVPlayer`'s coordinated playback for iOS clients (the
existing streamed-playback path; local EQ playback would need to fall
back to non-coordinated `AVAudioEngine` since that path can't sync
across devices the same way). Biggest scope item on this list, but the
app already has the queue model and remote-command plumbing a shared
session would reuse.

**7. Playlist import/export.** `PlaylistManager` already has
`createPlaylist(name:songs:)`. Pasting a block of "Artist - Title" lines
or a YouTube Music playlist URL, resolving each line through the
existing `search(query:)` call, and building a playlist from the results
covers import. Export is the easy half: a `ShareLink` dumping a
playlist's songs as plain text or JSON.

## Smarter library

**8. "Recently Added" and "Forgotten Favorites" smart playlists.**
`MostPlayedSection` in `HomeView` already proves the pattern: compute a
list from stored data, render it like any other row. "Recently Added"
sorts `PlaylistManager`'s liked-songs timestamps; "Forgotten Favorites"
would use `StatsManager`'s play history to surface songs that were
played a lot once but haven't come up recently, something Most Played
alone doesn't distinguish (a song played 50 times two years ago currently
ranks the same as one played 50 times last week).

**9. Taste-profile onboarding for empty libraries.** `MadeForYouEngine`
needs real listening history to build a mix, so a brand-new install has
nothing to seed it with. A short first-run quiz built from
`getMoodCategories()`/`getExplore()` results (pick a few genres/moods you
like) would give `MadeForYouEngine` a synthetic starting point instead
of an empty state on day one.

**10. Radio / auto-continue from a song.** InnerTube's player response
carries a radio playlist ID alongside each song. "Start radio" on a song
would seed the queue with it and keep extending the queue as it plays
down, the way `getRelated(videoId:)` already builds a one-shot related
list, but continuous instead of a fixed batch.

## Audio

**11. Independent pitch/key shift.** `EqualizerEngine` already attaches
an `AVAudioUnitTimePitch` node and sets its `.rate` property for playback
speed. That same node has an unused `.pitch` property (in cents) that
shifts key without changing tempo, useful for anyone using this to
practice along with a song in a different key. Pure UI addition, the
audio node is already wired in.

**12. Gapless playback.** Crossfade (`AudioPlayer`'s
`isCrossfadeEnabled`/`crossfadeDuration`) overlaps the end of one song
with the start of the next. Gapless is the opposite problem: some
albums are mixed with zero silence between tracks, and crossfading them
adds an overlap that wasn't in the original mix. Scheduling the next
buffer to start the instant the current one ends, rather than crossfading
it in, would need its own toggle in `EqualizerEngine`'s local-file path.

**13. Loudness normalization for downloads.** Some songs come in
noticeably louder or quieter than others. During `OfflineManager`'s
download step, a quick RMS pass over the downloaded audio file could
compute a gain offset and store it alongside the existing
`DownloadedSong` metadata, then `EqualizerEngine` applies it automatically
on playback so downloaded songs don't swing between whisper-quiet and
too loud back to back.

## Accounts

**14. YouTube Music account sign-in.** Everything today is local-only or
synced privately through the user's own iCloud account, there's no
connection to an actual YouTube/Google account. Signing in (Google
Sign-In or a cookie-based flow, matching how `yt-dlp` and `ytmusicapi`
authenticate against InnerTube) would unlock reading a user's real
YouTube Music library, subscriptions, and likes, and pushing likes back
through InnerTube's `like/like` endpoint. Sizable feature: it needs
secure token storage and a real privacy story before shipping, not just
an API call, but it's the one thing that would make this feel like a
YouTube Music client rather than a music player that happens to stream
from YouTube.

## Content coverage

**15. Song credits.** `InnerTubeClient` has no credits call today, but
YouTube Music's browse API exposes a credits panel (producers, writers,
composers) alongside a song's detail page. A `getSongCredits(videoId:)`
call plus a section on `SongDetailView` would surface it.

**16. Podcast support.** InnerTube also serves podcasts through a
separate browse endpoint (`FEmusic_podcasts`) that this client doesn't
touch yet. Episode list view, playback through the existing
`AudioPlayer`, and remembering per-podcast playback speed (a `Double`
keyed by podcast ID, the same pattern `EqualizerEngine`'s rate already
uses) would cover the basics without needing a whole new player.

## Polish

**17. Custom accent color.** A handful of preset colors in
`SettingsView`, applied via `.tint()` at the app root. Small, but it's
the kind of thing that makes an app feel like "yours" rather than a
default SwiftUI look.

**18. Full-screen album art viewer.** Tapping the art in `PlayerView`
today does nothing extra. A dedicated view with pinch-to-zoom and pan
(reusing whatever image is already cached from the disk+memory thumbnail
cache) plus a share-as-image action would match what most streaming apps
already offer.

**19. Year in Review.** `StatsManager` already keeps up to 500 listening
sessions with timestamps. A once-a-year (or on-demand) summary card,
total minutes, top artist, top song, longest streak, built entirely from
data already being recorded, with a `ShareLink` to export it as an image.
No new tracking needed, just a new view over existing data.
