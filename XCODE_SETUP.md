# Xcode Setup

Quick command reference for building, running, and testing this project.
For how the project got to its current state and why the build is set up
this way, see `BUILD_LOG.md`. For what to build next, see
`FEATURE_IDEAS.md`.

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
- **Four schemes:** `YTMusicApp` for day-to-day development (Cmd+R, and
  what `scripts/run_tests.sh` and `.github/workflows/ci.yml` build
  against), plus `YTMusicApp-Dev`, `YTMusicApp-TestFlight`, and
  `YTMusicApp-Release`, one per CI build channel. See `BUILD_LOG.md`'s
  "CI build channels" section for what triggers each one.

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

## Testing Checklist

Before every release:

- [ ] Full test suite passes (`scripts/run_tests.sh`, or Cmd+U in Xcode)
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
