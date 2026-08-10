# Xcode Setup & Next Steps

## Current Setup (working, verified)

The Xcode project is **generated from `project.yml` with [xcodegen](https://github.com/yonaskolb/XcodeGen)**.
`.xcodeproj` is gitignored, so it must be regenerated whenever source files are
added/removed or `project.yml` changes.

- **Single monolithic target** named `YTMusicApp` compiling BOTH
  `Sources/YTMusicApp` and `Sources/YTMusicAPI` as one module.
  The API types have no `public` access modifiers, so they cannot live in a
  separate module.
- **Bundle ID:** `com.landonkea.ytmusic`
- **Deployment target:** iOS 17.0
- **Privacy usage strings** live in `project.yml` (they must stay there, the
  app crashes without `NSSpeechRecognitionUsageDescription` and
  `NSMicrophoneUsageDescription`).
- **Secrets** (currently just the InnerTube API key) are injected via
  `Config/Secrets.xcconfig`, which is gitignored. Before your first build,
  copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`, the
  example file documents every key and has the real (public) InnerTube key
  value in its comments. Without this file the app builds but crashes on
  launch with a clear `fatalError` message telling you what to do.

### 0. One-time secrets setup
```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# then edit Config/Secrets.xcconfig and fill in INNERTUBE_API_KEY
# (see the comment in Secrets.example.xcconfig for the value/explanation)
```

### 1. Build & Run (command line)
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # required for every non-interactive build
xcodegen generate                                                 # recreate the .xcodeproj
xcodebuild -project YTMusicApp.xcodeproj -scheme YTMusicApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build
```

### 2. Install & Launch on a Simulator
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Point APP at the DerivedData build product:
APP=~/Library/Developer/Xcode/DerivedData/YTMusicApp-*/Build/Products/Debug-iphonesimulator/YTMusicApp.app
xcrun simctl boot "iPhone 17" || true
xcrun simctl install "iPhone 17" "$APP"
xcrun simctl launch "iPhone 17" com.landonkea.ytmusic
```

### 3. Open in Xcode
```bash
xcodegen generate
open YTMusicApp.xcodeproj
```
Product → Run (Cmd+R). If signing is needed, set your Apple ID team and the
bundle ID stays `com.landonkea.ytmusic`.

### 4. Run Tests
```bash
xcodebuild test -scheme YTMusicApp -destination 'platform=iOS Simulator,name=iPhone 17'
```
Or use the test navigator in Xcode.

### Package.swift / Swift Package Manager
`Package.swift` mirrors the single-module structure (one executable target that
compiles both `Sources/YTMusicApp` and `Sources/YTMusicAPI`). It exists so the
package layout stays valid and tools that parse the package work.

**Note:** `swift build` on a Mac cannot produce a runnable iOS app, SwiftPM
lacks a bundled iOS destination, so it cannot cross-link iOS executables. This
is an Apple tooling limitation, not a project bug. The real build path is
`xcodegen generate` + `xcodebuild` above.

---

## Resolved Gaps (log of known gaps that have been fixed)

### SongDetailView download
- **Before:** the download button called `offlineManager.download(...)` with the
  thumbnail URL as the audio URL, so downloads had no real audio.
- **Fixed:** the button now fetches a real stream URL via
  `apiClient.getPlayerInfoForDownload(videoId:)` (a per-song download variant
  of the player API) and passes that audio URL to
  `offlineManager.download(videoId:title:artist:audioUrl:thumbnailUrl:)`.
- The button shows a spinner + "Downloading..." and guards against starting a
  second download for the same song.

### Equalizer (real audio processing)
- **Before:** `EqualizerManager.applyGainsToEQ()` was a stub, sliders updated
  values but nothing reached the audio.
- **Fixed:** new `Services/EqualizerEngine.swift` runs playback through an
  `AVAudioEngine` graph (`playerNode → AVAudioUnitTimePitch → AVAudioUnitEQ(10
  bands) → mainMixer`). It supports play/pause/resume/stop/seek, rate, volume,
  EQ gain updates, a 0.25s position timer, and an end-of-song callback.
- `AudioPlayer` now routes playback through the engine whenever EQ is enabled
  AND the song is a local/downloaded file (`url.isFileURL`). Streamed songs
  still use AVPlayer because AVPlayer cannot be equalized.
- `EqualizerManager.shared` is wired in `YTMusicApp.init`; gain changes flow to
  the active engine via an `onGainsChanged` callback.
- **Known limitation:** because EQ requires the AVAudioEngine path, enabling EQ
  affects only downloaded/local songs (which is also the only place real EQ is
  technically possible on iOS today).

### Package.swift / SPM structure
- **Before:** two targets (`YTMusicApp` depending on `YTMusicAPI`), which could
  never build because the API module's types are all internal.
- **Fixed:** single executable target that compiles both source folders as one
  module, matching the xcodegen setup.
- See the "Package.swift / Swift Package Manager" note above for the macOS
  cross-link limitation.

---

## Features Blocked by Xcode

### Must-Do Before Release

#### 1. Notification Center Widget
- Add a Widget Extension target
- Create a `NowPlayingWidget` that shows current song + play/pause
- Use `WidgetKit` with `AppEntity` for configuration
- Timeline provider refreshes every 5 minutes while playing
- Deep link taps open the app to the player

#### 2. Live Activities (Dynamic Island)
- Add a `LiveActivity` extension target
- Show now-playing info on the Dynamic Island / Lock Screen
- Use `ActivityAttributes` with song title, artist, album art
- Update via `LiveActivityManager` when the song changes

#### 3. CarPlay
- Add a `CPTemplateApplicationScene` to the Info.plist
- Create a `CarPlaySceneDelegate` with `CPListTemplate` for now-playing
- Implement `CPNowPlayingTemplate` for playback controls
- Wire up `MPRemoteCommandCenter` (already set up in AudioPlayer)

#### 4. SharePlay
- Add `GroupActivity` support for shared listening sessions
- Create a `YTMusicGroupActivity` with song metadata
- Use `AVPlayer`'s coordinated playback for sync
- Requires `GroupActivities` entitlement

#### 5. Handoff
- Add `NSUserActivity` support to `ContentView`
- Set `isEligibleForHandoff` on activity
- Implement `restoreUserActivityState` in the scene delegate
- Already partially set up via `SiriShortcutsManager`

#### 6. Spotlight Search
- Add `CSSearchableItem` indexing for songs and artists
- Index songs when they're played (in `addToRecentlyPlayed`)
- Index playlists when they're created
- Use `CSSearchableIndex` for batch updates

#### 7. App Store Connect
- Create app listing at https://appstoreconnect.apple.com
- Upload screenshots (iPhone + iPad + Mac)
- Write description, keywords, privacy policy
- Submit for review (requires Apple Developer Program)

---

## Features to Add After Xcode Setup

### Phase 8: Short Session (1-2 days)

#### 8.1 Listening Party / SharePlay
- Real-time sync via `GroupActivity`
- Share queue with friends
- Chat/messages in-app

#### 8.2 Custom Themes
- Accent color picker in Settings
- 10+ preset color palettes (like Metrolist's Material You)
- Album art-based dynamic coloring

#### 8.3 Canvas/Artwork Display
- Full-screen album art view on tap (like Apple Music)
- Zoom, pan, share artwork as image
- Crossfade between album arts in queue

### Phase 9: Medium Session (3-5 days)

#### 9.1 Song Credits
- Browse endpoint with `getSongCredits` 
- Show producers, writers, engineers
- Link to related artists

#### 9.2 Podcast Support
- Browse `FEmusic_podcasts` endpoint
- Podcast detail view with episodes
- Playback speed remembers per-podcast

#### 9.3 Smart Playlists
- "Recently Added" auto-playlist
- "Most Played" auto-playlist (already in HomeView)
- "Liked Songs" auto-playlist (data ready in LikedSongsManager)

#### 9.4 Import/Export Playlists
- Import from URL/text
- Export as text, JSON, or share link
- Share playlist as image

#### 9.5 Offline Mode Improvements
- Smart caching (cache on play)
- Offline-only toggle in Settings
- Storage management UI with per-song delete

### Phase 10: Long Session (1-2 weeks)

#### 10.1 Account Login (YouTube Music)
- Google Sign-In via `GoogleSignIn` SDK
- Liked songs sync
- Library sync (albums, artists, playlists)
- Subscriptions/followed artists
- Like/dislike via API (`like/like`, `like/dislike`)
- Subscribe/unsubscribe via API

#### 10.2 Audio Enhancements
- ~~EQ wiring~~ **DONE**, `EqualizerEngine` (AVAudioEngine + 10-band
  `AVAudioUnitEQ`) now processes local/downloaded files when EQ is enabled.
  AVPlayer cannot be EQ'd, so streamed playback keeps using AVPlayer.
- Tempo/pitch control (independent of speed)
- Audio normalization / loudness
- Skip silence
- Gapless playback

#### 10.3 Algorithmic Recommendations
- Taste profile setup (`getTasteprofile`/`setTasteprofile`)
- Personalized mixes (Daily Mix, Discover Weekly-style)
- Radio station builder (`FEmusic_radio_builder`)

#### 10.4 Analytics Dashboard
- Full stats view with charts
- Time listened per day/week/month
- Top genres (if we could determine genre)
- Year in Review feature

### Phase 11: Polish (ongoing)

#### 11.1 UI Touch-Ups
- Haptic feedback on all interactions
- Fluid animations (matched geometry, transitions)
- Drag to reorder queue with haptic
- Mini player drag up to expand
- Landscape/tablet adaptive layouts

#### 11.2 Performance
- Lazy loading all images
- Pagination for long lists
- Memory management for large queues
- Profile with Instruments

#### 11.3 Accessibility
- Dynamic Type testing
- VoiceOver audit on every screen
- Reduce Motion support
- Keyboard navigation (iPad/Mac)

---

## Testing Checklist

Before every release:

- [ ] `npm run test:run` equivalent in Xcode (Cmd+U)
- [ ] Build with no warnings
- [ ] Test on iPhone (compact) and iPad (regular) size classes
- [ ] Test light and dark mode
- [ ] Test with VoiceOver enabled
- [ ] Test background audio (press home, lock screen controls)
- [ ] Test offline mode (airplane mode)
- [ ] Test downloads (start, cancel, play offline)
- [ ] Test queue operations (add, remove, reorder, shuffle, repeat)
- [ ] Test sleep timer
- [ ] Test crossfade
- [ ] Test equalizer
- [ ] Test search (text + voice)
- [ ] Test playlists (create, rename, delete, reorder)
- [ ] Test Siri Shortcuts
- [ ] Test on iOS 17 minimum

---

## Git Workflow

1. Feature branch from `dev`: `git checkout -b feature/your-feature dev`
2. Commit with conventional commit messages (`feat:`, `fix:`, `chore:`)
3. Push feature branch: `git push origin feature/your-feature`
4. Create PR into `dev` (via GitHub CLI or web)
5. After review, merge into `dev`
6. Test on `dev`
7. Merge `dev` → `main`
8. Push `main`: `git push origin main`

---

## File Reference

Key files to know:

| File | Purpose |
|------|---------|
| `Sources/YTMusicApp/YTMusicApp.swift` | App entry, environment objects, APIClient |
| `Sources/YTMusicApp/Services/AudioPlayer.swift` | Full playback engine |
| `Sources/YTMusicAPI/InnerTubeClient.swift` | All YouTube Music API calls |
| `Sources/YTMusicAPI/Models.swift` | Simple UI models |
| `Sources/YTMusicAPI/InnerTubeModels.swift` | Raw API response models |

Feature files:
| File | What it does |
|------|--------------|
| `Views/ArtistView.swift` | Artist page |
| `Views/AlbumView.swift` | Album page |
| `Views/ExploreView.swift` | Explore/Discover tab |
| `Services/LikedSongsManager.swift` | Local liked songs |
| `Services/StatsManager.swift` | Listening stats |
| `Views/PlayerView.swift` | Full player with speed control |
| `Views/ContentView.swift` | Root with keyboard shortcuts |
