# landonkea-ytmusic-ios

A free, open-source YouTube Music client for iPhone, iPad, and Mac.

## Features

- Search for songs, artists, and albums
- Play music from YouTube's vast library
- Background audio playback
- Mini player with playback controls
- Full-screen player with progress bar
- AirPlay support
- No ads, no subscription required

## Requirements

- iOS 17.0+ / macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Setup

1. Open Xcode
2. File → New → Project
3. Choose "iOS" → "App"
4. Product Name: `YTMusic`
5. Organization Identifier: `com.landonkea`
6. Interface: SwiftUI
7. Language: Swift
8. Save the project in this folder
9. In Xcode, go to File → Add Package Dependencies
10. Add this local package (the folder you're in)

## How It Works

This app uses YouTube's InnerTube API, the same internal API that the official YouTube Music app uses. By pretending to be the official iOS YouTube Music client, we can:

- Search for any song
- Get streaming URLs
- Play audio without ads

## Technical Details

- **API Client**: Talks directly to YouTube's InnerTube servers
- **Audio Playback**: Uses AVFoundation for native audio playback
- **UI**: Built with SwiftUI for a native Apple feel
- **Architecture**: MVVM (Model-View-ViewModel)

## Project Structure

```
Sources/
├── YTMusicAPI/           # The API client library
│   ├── InnerTubeClient.swift    # Main API client
│   ├── InnerTubeModels.swift    # Data models for API
│   └── Models.swift            # Simple models for UI
│
└── YTMusicApp/           # The iOS/macOS app
    ├── YTMusicApp.swift         # App entry point
    ├── Services/
    │   └── AudioPlayer.swift    # Audio playback manager
    └── Views/
        ├── ContentView.swift    # Main tab view
        ├── HomeView.swift       # Home screen
        ├── SearchView.swift     # Search screen
        └── PlayerView.swift     # Full-screen player
```

## Mac Catalyst

The app builds as a native Mac app via Mac Catalyst, same codebase, no
separate macOS target. Build it with:

```
xcodegen generate
xcodebuild -scheme YTMusicApp -destination 'platform=macOS,variant=Mac Catalyst' build
```

**Local builds need an ad-hoc signing override.** Unlike the iOS
Simulator, Xcode's "Automatic" signing with no development team refuses to
sign a Mac Catalyst build ("Signing for ... requires a development team").
This repo has no committed signing team (see `Setup` above), so build/test
locally with:

```
xcodebuild -scheme YTMusicApp -destination 'platform=macOS,variant=Mac Catalyst' \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

(the same override works with `test` in place of `build`; all 13 unit
tests pass under Catalyst). With a real Apple Developer team configured in
Xcode, plain "Automatic" signing works with no extra flags.

### What works

- Playback, search, browse, downloads, lyrics, equalizer, playlists, the
  app compiled and ran under Catalyst with **no source changes**. UIKit,
  AVFoundation/AVAudioSession, MediaPlayer, BackgroundTasks, Speech, and
  Intents all link and run fine in the Catalyst runtime.
- The Home Screen / Lock Screen Now Playing widget (`YTMusicWidgetExtension`)
  embeds and builds for Catalyst too, WidgetKit widgets from a Catalyst
  app surface in macOS's Notification Center widget gallery the same way
  Home Screen widgets do on iOS, with no extension-specific code changes
  required.

### Known limitations (not verified beyond compiling/running locally)

- **Lock screen / Control Center semantics differ.** `MPRemoteCommandCenter`
  and `MPNowPlayingInfoCenter` still work under Catalyst, but there's no
  literal "lock screen" on a Mac, the same remote-command wiring instead
  surfaces playback controls in macOS's Control Center / media widget and
  the Touch Bar (where present). This was not manually verified on real
  Mac hardware in this change, only confirmed to build/link.
- **`AVAudioSession` category/options are largely advisory on Mac**, there
  is no silent switch and background-audio behavior is governed by normal
  macOS app lifecycle rules, not iOS's background modes. `setupAudioSession()`
  and `VoiceSearchManager`'s `activateAudioSession()` still call
  `AVAudioSession.sharedInstance()` and don't throw, but the `.mixWithOthers`
  / `.duckOthers` options may have no visible effect on Mac.
- **App Group-backed widget sync has the same no-signing-team caveat as iOS**
  (see `YTMusicApp.entitlements`): without a real Apple Developer team and
  provisioning profile, `UserDefaults(suiteName:)` may resolve to nil on
  Mac too, so the widget's shared "now playing" state should be considered
  unverified until built with real signing.
- Haptics (`UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` in
  `Haptics.swift`) compile unchanged and no-op silently on Mac (no Taptic
  Engine), confirmed by reading Apple's documented Catalyst behavior, not
  by feeling for a vibration that can't exist on this hardware.

## CloudKit Sync

Playlists and liked songs (only, not listening stats/play counts) sync
across a user's devices via their private iCloud database. See
`Sources/YTMusicApp/Services/CloudKitSyncManager.swift` for the full
design writeup (why raw CloudKit instead of `NSPersistentCloudKitContainer`,
the conflict-resolution rules, and known limitations like no deletion sync
and no push-based `CKSubscription`).

**What's verified in this environment (no signing team, no iCloud account):**
- `CloudKitRecordCoding`'s `Playlist`/`LikedSongEntry` <-> `CKRecord`
  encode/decode round trips (`CKRecord` can be constructed with no network
  or entitlements).
- `PlaylistConflictResolver` / `LikedSongConflictResolver`: pure
  last-write-wins-by-timestamp merge logic, no CloudKit types involved.
- `CloudKitSyncManager`'s full pull/merge/apply/push orchestration, run
  against `InMemoryCloudRecordStore` (an in-memory fake conforming to the
  same `CloudRecordStore` protocol the real `CKDatabaseRecordStore` does).
- `xcodegen generate` + `xcodebuild build`/`test` compile and pass cleanly
  with the `CloudKit.framework` link and the iCloud container entitlement
  in place.

See `Tests/YTMusicAppTests/CloudKitSyncTests.swift` for all of the above.

**What is NOT verified here, and needs a real device/simulator signed into
iCloud with a real Apple Developer team provisioning
`iCloud.com.landonkea.ytmusic`:**
- That `CKDatabaseRecordStore` (the thin adapter over a real `CKDatabase`)
  actually talks to CloudKit correctly: zone creation, record
  save/fetch/delete against Apple's servers.
- Real cross-device sync behavior (two physical/simulated devices
  converging on the same merged state).
- `com.apple.developer.icloud-container-identifiers` / `-icloud-services`
  entitlements resolving to a real, usable container. In local/CI builds
  without a signing team, `CKContainer` operations fail with a
  "not authenticated"/no-account error, which `performSync()` catches and
  logs, skipping the sync pass rather than crashing. Local playlists/liked
  songs remain fully usable offline either way. This only affects
  cross-device sync, the same category of caveat as the widget's App Group
  (see Mac Catalyst section above).

## Running Tests

```
scripts/run_tests.sh
```

This runs `xcodegen generate` followed by `xcodebuild test` against the
first available iPhone simulator, then writes a summary report to
`test-results/latest.md` (pass/fail counts, timestamp, and any failures).
The full raw `xcodebuild` log is saved alongside it at
`test-results/raw.log`. Both are gitignored, generated locally and, in CI,
uploaded as a workflow artifact (see `.github/workflows/ci.yml`).

## What's Next

- [ ] Playlist support
- [ ] Lyrics display
- [ ] Offline caching
- [ ] Queue management
- [ ] Dark mode support
- [ ] Widget for home screen

## Disclaimer

This project is not affiliated with YouTube or Google. It uses an unofficial API that may stop working at any time.

## License

MIT License
