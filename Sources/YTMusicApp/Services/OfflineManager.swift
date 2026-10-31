import Foundation
import SwiftUI
import BackgroundTasks  // BGTaskScheduler for requesting background time
import Network          // NWPathMonitor, used to enforce "Wi-Fi Only" downloads

/// Manages offline song caching, downloading, storing, and playing cached songs.
///
/// HOW IT WORKS:
/// - Songs are downloaded to the app's Documents/Downloads/ directory
/// - A JSON file tracks which songs are downloaded (metadata + file paths)
/// - When playing a song, we check if it's cached first (saves data + works offline)
/// - Users can delete individual downloads or clear all
///
/// BACKGROUND DOWNLOADS:
/// - Uses a URLSession with a background identifier so iOS continues
///   downloading even when the app is suspended or in the background
/// - The system wakes the app briefly when a download finishes
/// - On cellular, respects the "Wi-Fi Only" setting
///
/// STORAGE LOCATION:
/// iOS apps have a "Documents" directory that persists between launches.
/// We store downloads in Documents/Downloads/ and the index in Documents/downloads.json.
///
/// LIMITATIONS:
/// - Cached songs are deleted if the user uninstalls the app
/// - Stream URLs expire after a few hours, so cached audio files are the only
///   thing that persists, we can't re-download with the same URL
/// - Storage is limited by the device's available space
@MainActor
class OfflineManager: NSObject, ObservableObject {
    /// The app-wide instance, wired in YTMusicApp.init (same
    /// pattern as the other managers) so AudioPlayer can save a
    /// local copy of whatever it plays.
    static var shared: OfflineManager?
    
    // MARK: - Published Properties
    
    /// List of all downloaded songs. Updated when downloads complete or are deleted.
    @Published var downloads: [DownloadedSong] = []
    
    /// Currently downloading songs (video ID → progress 0.0-1.0)
    @Published var downloading: [String: Double] = [:]

    /// Whether the device currently has a Wi-Fi (or wired) connection.
    /// Updated by `pathMonitor` below. `download()` checks this, together
    /// with the "Wi-Fi Only" setting, before starting any transfer.
    @Published private(set) var isOnWifi: Bool = true

    /// Set whenever a download is skipped because "Wi-Fi Only" is enabled
    /// in Settings and the device isn't on Wi-Fi. Views observe this
    /// (see ContentView) to surface an alert; it's cleared after being shown.
    @Published var wifiOnlyBlockedMessage: String?

    // MARK: - Private Properties

    /// Watches the device's current network path (Wi-Fi vs. cellular vs.
    /// none) so we can enforce the "Wi-Fi Only" downloads setting in real
    /// time, instead of only checking once at app launch.
    private let pathMonitor = NWPathMonitor()
    
    /// The app's Documents directory (persists between launches)
    private let documentsPath: URL
    
    /// The Downloads subdirectory where audio files are stored
    private let downloadsPath: URL
    
    /// The JSON file that stores the download index
    private let indexFilePath: URL
    
    /// URL session for downloads, uses background config so downloads
    /// continue when the app is in the background.
    private var session: URLSession!
    
    /// Background completion handler registered by the system when a
    /// background download task finishes while the app was suspended.
    private var backgroundCompletionHandler: (() -> Void)?
    
    /// Track which background download task maps to which video ID.
    /// When the delegate callback fires, we look up the video ID
    /// from this dictionary using the task identifier.
    private var taskIdToVideoId: [Int: String] = [:]
    
    /// Continuations for bridging delegate-based background downloads
    /// to async/await. Each active task gets a continuation that is
    /// resumed when the download completes or fails.
    private var downloadContinuations: [Int: CheckedContinuation<URL, Error>] = [:]
    
    /// Set the background completion handler (called from AppDelegate/SceneDelegate).
    ///
    /// The system calls this when a background download completes while
    /// the app was suspended. We store the handler and call it after
    /// processing all completed downloads.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        self.backgroundCompletionHandler = handler
    }
    
    // MARK: - Initialization
    
    override init() {
        // We override NSObject's init() because OfflineManager subclasses
        // NSObject, this is required so it can conform to
        // URLSessionDownloadDelegate below (a protocol that, like many
        // older Apple APIs, only works with NSObject-based classes).
        // The `override` keyword is required by Swift whenever a subclass
        // provides its own version of a method/initializer the superclass
        // already defines.
        //
        // Get the app's Documents directory.
        // `FileManager.default` is a shared, ready-to-use instance for
        // interacting with the filesystem. `.urls(for:in:)` returns an
        // array of matching directory URLs; we take `[0]` because on iOS
        // there's always exactly one Documents directory per app.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documentsPath = documents
        self.downloadsPath = documents.appendingPathComponent("Downloads")
        self.indexFilePath = documents.appendingPathComponent("downloads.json")

        // Call super.init() AFTER all of OUR stored properties are set.
        // Swift requires this ordering: a subclass must finish
        // initializing its own properties before handing control to the
        // superclass's initializer.
        super.init()

        // Now that `self` is fully initialized, finish the rest of setup
        // in small, focused helper methods.
        prepareDownloadsDirectory()
        loadIndex()
        session = Self.makeBackgroundSession(delegate: self)
        startPathMonitor()
    }

    /// Start watching the device's network path so `isOnWifi` always
    /// reflects the current connection type.
    ///
    /// `NWPathMonitor`'s `pathUpdateHandler` fires on whatever queue we hand
    /// it (never the main thread by default), so, same as the
    /// URLSessionDownloadDelegate methods below, we hop to the main actor
    /// before touching the `@Published` property.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // `.wifi` covers actual Wi-Fi; `.wiredEthernet` covers a wired
            // adapter (common on iPad), both are effectively "unmetered",
            // which is what a "Wi-Fi Only" setting is really asking about.
            // Cellular (including a cellular personal hotspot) reports
            // neither, so `isOnWifi` correctly becomes false for it.
            let onWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                self?.isOnWifi = onWifi
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.landonkea.ytmusic.pathmonitor"))
    }

    /// Create the Downloads subdirectory on disk if it doesn't already exist.
    /// `try?` converts a throwing call into an optional-discarding one,
    /// if directory creation fails (e.g. it already exists), we simply
    /// ignore the error rather than crashing the app at launch.
    private func prepareDownloadsDirectory() {
        try? FileManager.default.createDirectory(at: downloadsPath, withIntermediateDirectories: true)
    }

    /// Build the background URLSession used for all downloads.
    ///
    /// WHAT IS A "background URLSession"? A normal URLSession's transfers
    /// stop if the app is suspended or terminated by the system. A
    /// background session hands the actual networking off to a separate OS
    /// process, so downloads keep progressing even while our app isn't
    /// running in the foreground, iOS briefly wakes the app to deliver
    /// delegate callbacks when a transfer finishes.
    ///
    /// This is a `static` function (rather than an instance method) so it
    /// can be called from `init()` before `self` has a `session` property
    /// value yet, taking the delegate as an explicit parameter instead of
    /// implicitly capturing `self`.
    private static func makeBackgroundSession(delegate: URLSessionDownloadDelegate) -> URLSession {
        // Background sessions use a unique identifier string so iOS can
        // reconnect to the same session when the app relaunches after
        // being suspended or terminated mid-download.
        let config = URLSessionConfiguration.background(withIdentifier: "com.landonkea.ytmusic.downloads")
        config.isDiscretionary = false  // Download immediately, not when the system decides
        config.shouldUseExtendedBackgroundIdleMode = true  // Keep network alive longer
        config.timeoutIntervalForRequest = 600    // The song service can take minutes to fetch an uncached song
        config.timeoutIntervalForResource = 7200  // Allow up to two hours for a full download

        // `delegateQueue: nil` tells URLSession to create its own private
        // background queue for delegate callbacks (progress, completion,
        // etc.) rather than using the main queue, which is exactly why
        // every delegate method below is `nonisolated` and hops back to
        // the main actor via `DispatchQueue.main.async` before touching
        // any of this class's main-actor-isolated state.
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    
    // MARK: - Public Methods
    
    /// Check if a song is already downloaded.
    ///
    /// - Parameter videoId: YouTube video ID
    /// - Returns: true if the audio file exists locally
    func isDownloaded(_ videoId: String) -> Bool {
        return downloads.contains { $0.videoId == videoId }
    }
    
    /// Check if a song is currently being downloaded.
    func isDownloading(_ videoId: String) -> Bool {
        return downloading[videoId] != nil
    }
    
    /// Get the local file URL for a downloaded song.
    ///
    /// - Parameter videoId: YouTube video ID
    /// - Returns: File URL if downloaded, nil otherwise
    func localURL(for videoId: String) -> URL? {
        guard let song = downloads.first(where: { $0.videoId == videoId }) else {
            return nil
        }
        let fileURL = downloadsPath.appendingPathComponent(song.fileName)
        // Verify the file actually exists (it might have been deleted externally)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }
    
    /// Download a song's audio file for offline playback.
    ///
    /// FLOW:
    /// 1. Check if already downloaded (skip if so)
    /// 2. Create a temporary file path
    /// 3. Start the download task
    /// 4. On completion, move the file to the Downloads directory
    /// 5. Add the song to the download index
    ///
    /// - Parameters:
    ///   - videoId: YouTube video ID (used as unique identifier)
    ///   - title: Song title (for display)
    ///   - artist: Artist name (for display)
    ///   - audioUrl: Direct URL to the audio stream
    ///   - thumbnailUrl: URL to album art (for display in downloads list)
    func download(
        videoId: String,
        title: String,
        artist: String,
        audioUrl: String,
        thumbnailUrl: String
    ) async {
        // Don't download if already downloaded or currently downloading
        guard !isDownloaded(videoId), !isDownloading(videoId) else { return }

        guard let url = URL(string: audioUrl) else { return }

        // BUG FIX: enforce the "Wi-Fi Only" setting (SettingsView's
        // `downloadOverWifiOnly` toggle). Previously this setting was
        // stored but never read anywhere, downloads always went ahead
        // over cellular regardless of the toggle. We now check the current
        // network path before starting.
        //
        // We read the raw UserDefaults value with `object(forKey:)` rather
        // than `bool(forKey:)`: `bool(forKey:)` returns `false` for a key
        // that was never written, but SettingsView's `@AppStorage(...) =
        // true` means the *intended* default is "on", a user who never
        // opens Settings should still get Wi-Fi-only protection by default,
        // not silently download over cellular.
        let wifiOnly = (UserDefaults.standard.object(forKey: "downloadOverWifiOnly") as? Bool) ?? false
        if wifiOnly && !isOnWifi {
            wifiOnlyBlockedMessage = "\"\(title)\" wasn't downloaded because Wi-Fi Only is enabled in Settings and you're not connected to Wi-Fi."
            return
        }

        // Start with 0% progress. Setting this before the `await` below is
        // what makes `isDownloading(videoId)` return true immediately.
        downloading[videoId] = 0.0

        do {
            let tempURL = try await runDownloadTask(for: url, videoId: videoId)
            let fileName = try storeDownloadedFile(from: tempURL, videoId: videoId)
            recordDownload(videoId: videoId, title: title, artist: artist, thumbnailUrl: thumbnailUrl, fileName: fileName)
        } catch {
            print("Download failed: \(error)")
        }

        // Whether we succeeded or failed, this video is no longer "in
        // progress", always clear it so the UI stops showing a progress bar.
        downloading.removeValue(forKey: videoId)
    }

    /// Start a URLSession background download task for `url` and suspend
    /// until it finishes, using a checked continuation to bridge the
    /// delegate-based (callback-style) URLSession API into async/await.
    ///
    /// WHAT IS "withCheckedThrowingContinuation"? Some older or
    /// callback-based Apple APIs (like URLSessionDownloadDelegate below)
    /// don't support `async`/`await` natively. This function lets us wrap
    /// such an API: we get a `continuation` object, hand it off to be
    /// "resumed" later (from the delegate callback, possibly on a totally
    /// different thread/queue), and our `await` here doesn't return until
    /// someone calls `continuation.resume(...)`. "Checked" means Swift
    /// verifies at runtime that we resume it exactly once, resuming twice,
    /// or never resuming it at all, is a programming error it will flag.
    ///
    /// - Returns: The temporary file URL where the OS placed the downloaded data.
    private func runDownloadTask(for url: URL, videoId: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // Create a download task, this works with background sessions.
            let task = session.downloadTask(with: url)

            // Store the continuation associated with this task's unique ID
            // so the delegate methods (which only receive a task, not our
            // `continuation` variable) can look it up and resume it later.
            downloadContinuations[task.taskIdentifier] = continuation
            // Track which video this task belongs to, so progress/completion
            // callbacks (identified only by task ID) can update the right
            // entry in `downloading`.
            taskIdToVideoId[task.taskIdentifier] = videoId

            // Start the download (system continues it in the background).
            task.resume()
        }
    }

    /// Move a freshly downloaded temp file into our permanent Downloads
    /// directory, using the video ID as the filename.
    ///
    /// - Returns: The filename the file was stored under (for the index record).
    private func storeDownloadedFile(from tempURL: URL, videoId: String) throws -> String {
        // Create a unique filename using the video ID.
        // We add the .m4a extension because YouTube streams are typically
        // AAC audio in an MP4 container.
        let fileName = "\(videoId).m4a"
        let fileURL = downloadsPath.appendingPathComponent(fileName)

        // `moveItem` throws if the destination already exists, so remove
        // any stale leftover file first (e.g. from a previous failed run).
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        // Sanity floor: even at the lowest quality a full song is
        // hundreds of KB. Anything smaller is an error page or a
        // truncated transfer, not audio — don't keep it.
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if fileSize < 20_000 {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(
                domain: "OfflineManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded file is only \(fileSize) bytes — not audio"]
            )
        }
        return fileName
    }

    /// Append a new DownloadedSong record to `downloads` and persist the
    /// updated index to disk.
    private func recordDownload(videoId: String, title: String, artist: String, thumbnailUrl: String, fileName: String) {
        let song = DownloadedSong(
            videoId: videoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            downloadDate: Date()
        )
        downloads.append(song)
        saveIndex()
    }
    
    /// Delete a downloaded song.
    ///
    /// Removes the audio file from disk and the entry from the index.
    func delete(videoId: String) {
        guard let index = downloads.firstIndex(where: { $0.videoId == videoId }) else { return }
        
        let song = downloads[index]
        let fileURL = downloadsPath.appendingPathComponent(song.fileName)
        
        // Delete the file from disk
        try? FileManager.default.removeItem(at: fileURL)
        
        // Remove from our list and save
        downloads.remove(at: index)
        saveIndex()
    }
    
    /// Delete all downloaded songs.
    func deleteAll() {
        // Delete all files in the Downloads directory
        try? FileManager.default.removeItem(at: downloadsPath)
        try? FileManager.default.createDirectory(at: downloadsPath, withIntermediateDirectories: true)
        
        // Clear the list and save
        downloads = []
        saveIndex()
    }
    
    /// Get total storage used by downloads (in bytes).
    func totalStorageUsed() -> Int64 {
        var total: Int64 = 0
        for song in downloads {
            let fileURL = downloadsPath.appendingPathComponent(song.fileName)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
    
    /// Cancel an active download.
    ///
    /// This cancels the URLSession task. The system stops downloading
    /// and removes any partially downloaded data.
    func cancelDownload(videoId: String) {
        // Remove from progress tracking
        downloading.removeValue(forKey: videoId)

        // Find and cancel the URLSession task.
        // `getAllTasks` is itself asynchronous (it calls back with the
        // list of tasks once available), and, importantly, its
        // completion closure runs on the URLSession's own background
        // delegate queue, NOT the main thread. Since OfflineManager is
        // `@MainActor` (all its stored properties are expected to only be
        // touched from the main thread), we must hop back to the main
        // actor with `Task { @MainActor in ... }` before reading or
        // mutating `taskIdToVideoId` / `downloadContinuations`.
        // (This mirrors the DispatchQueue.main.async hops used by the
        // URLSessionDownloadDelegate methods below, for the same reason.)
        session.getAllTasks { [weak self] tasks in
            // `weak self` here means "don't keep OfflineManager alive just
            // because this closure exists" (avoiding a retain cycle if the
            // manager were ever deallocated while this callback is in
            // flight). We resolve it to a plain, temporarily-strong local
            // `self` once via `guard let self`; capturing that local
            // constant in the `Task` below for its brief lifetime is safe
            // and simpler than nesting another `[weak self]`.
            guard let self else { return }
            Task { @MainActor in
                for task in tasks {
                    guard self.taskIdToVideoId[task.taskIdentifier] == videoId else { continue }

                    task.cancel()
                    self.taskIdToVideoId.removeValue(forKey: task.taskIdentifier)

                    // BUG FIX: previously the continuation was removed from
                    // the dictionary here WITHOUT being resumed. A
                    // `CheckedContinuation` that is dropped without ever
                    // calling `resume` never lets its `await`-ing caller
                    // continue, the `Task` inside `download(...)` (and
                    // whatever code is awaiting that call) would hang
                    // forever, leaking memory and, in debug builds, tripping
                    // Swift's "leaking its continuation" runtime warning.
                    // We now resume it with a `CancellationError` so
                    // `download(...)`'s `catch` block runs and cleans up
                    // normally.
                    if let continuation = self.downloadContinuations.removeValue(forKey: task.taskIdentifier) {
                        continuation.resume(throwing: CancellationError())
                    }
                    break
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Save the download index to disk.
    ///
    /// We store a JSON array of DownloadedSong objects in Documents/downloads.json.
    /// This lets us quickly load the list of downloads on app launch
    /// without scanning the entire file system.
    ///
    /// WHAT IS "Codable"/"JSONEncoder"? `DownloadedSong` (below) is declared
    /// `Codable`, meaning Swift knows how to automatically turn it into (and
    /// back from) JSON. `JSONEncoder().encode(downloads)` converts the whole
    /// array into raw JSON bytes (`Data`) with no manual string-building.
    /// `dateEncodingStrategy = .iso8601` tells it to write `downloadDate` as
    /// a standard "2026-08-02T10:00:00Z"-style string rather than a raw
    /// number, which is both human-readable and unambiguous across devices.
    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(downloads)
            // `Data.write(to:)` writes the raw bytes to disk at the given
            // file URL, overwriting anything already there.
            try data.write(to: indexFilePath)
        } catch {
            print("Failed to save download index: \(error)")
        }
    }

    /// Load the download index from disk.
    ///
    /// Called on init to populate the downloads array.
    /// Also verifies that each file actually exists (in case files were deleted externally).
    private func loadIndex() {
        // If we've never saved an index before (e.g. first launch), there's
        // nothing to load, leave `downloads` as its default empty array.
        guard FileManager.default.fileExists(atPath: indexFilePath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: indexFilePath)
            let decoder = JSONDecoder()
            // Must match the `.iso8601` strategy used in `saveIndex()` above,
            // or decoding dates would fail.
            decoder.dateDecodingStrategy = .iso8601
            downloads = try decoder.decode([DownloadedSong].self, from: data)

            // Verify files exist, remove any entries whose files are
            // missing (e.g. deleted by iOS to free up storage, or removed
            // outside the app). `filter` keeps only the elements for which
            // the closure returns true.
            downloads = downloads.filter { song in
                let fileURL = downloadsPath.appendingPathComponent(song.fileName)
                return FileManager.default.fileExists(atPath: fileURL.path)
            }
        } catch {
            print("Failed to load download index: \(error)")
            downloads = []
        }
    }
}

// MARK: - URLSession Delegate

/// Delegate methods for the background URLSession.
///
/// These methods are called by the system when download tasks make progress,
/// complete, or fail. They run on a background queue, so we dispatch to
/// the main actor when updating @Published properties.
extension OfflineManager: URLSessionDownloadDelegate {
    
    /// Called periodically during download to report progress.
    ///
    /// `bytesWritten` is how many bytes were written since the last call.
    /// `totalBytesExpectedToWrite` is the total file size (or -1 if unknown).
    /// We use this to update the progress bar in the UI.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Calculate progress as a fraction (0.0 to 1.0)
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        // Look up the video ID and update the published dictionary.
        // We do this on the main actor (inside DispatchQueue.main.async)
        // because taskIdToVideoId and downloading are main-actor-isolated.
        let taskId = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let videoId = self.taskIdToVideoId[taskId] else { return }
            self.downloading[videoId] = progress
        }
    }
    
    /// Called when a download completes successfully.
    ///
    /// `location` is a temporary file URL where the downloaded data is stored.
    /// We must move this file before returning (it's deleted after this method).
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier

        // A download task "succeeds" at the URLSession level even
        // when the server answered an error — YouTube's bot wall,
        // for example, serves a tiny error page instead of the song.
        // Recording that page as the download produced phantom
        // downloads (listed as Downloaded, but Zero KB and silent).
        // Refuse anything that is not HTTP 200.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            let error = NSError(
                domain: "OfflineManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server answered HTTP \(http.statusCode) instead of the audio file"]
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                    continuation.resume(throwing: error)
                }
                self.taskIdToVideoId.removeValue(forKey: taskId)
            }
            return
        }

        // BUG FIX: Apple's documentation for this delegate method is very
        // explicit, the file at `location` is a temporary file that the
        // system deletes as soon as THIS METHOD RETURNS. The previous code
        // just hopped to the main actor with `DispatchQueue.main.async` and
        // resumed the continuation with `location` itself; by the time that
        // async block actually ran (and `download(...)` later tried to
        // `moveItem` from it), the OS may well have already deleted the
        // file out from under us, causing sporadic, hard-to-reproduce
        // "download failed" errors.
        //
        // The fix: synchronously (before returning from this method) move
        // the file into a location WE control, the system temp directory,
        // under a name it won't touch, and only then hop to the main
        // actor to resume the continuation with that safe URL.
        let safeTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        do {
            try FileManager.default.moveItem(at: location, to: safeTempURL)
        } catch {
            // Couldn't even rescue the file, report the failure instead.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                    continuation.resume(throwing: error)
                }
                self.taskIdToVideoId.removeValue(forKey: taskId)
            }
            return
        }

        // Now that the file is safely relocated, hop to the main actor
        // (where `downloadContinuations`/`taskIdToVideoId` live) to resume
        // the continuation and finish bookkeeping.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                continuation.resume(returning: safeTempURL)
            } else {
                // Nobody is waiting for this anymore, e.g. the download
                // was cancelled after the file already finished. Clean up
                // our rescued temp file ourselves so it doesn't linger on
                // disk forever.
                try? FileManager.default.removeItem(at: safeTempURL)
            }
            self.taskIdToVideoId.removeValue(forKey: taskId)
        }
    }
    
    /// Called when a download task finishes for ANY reason, success or
    /// failure. iOS calls this even after a successful download (in
    /// addition to `didFinishDownloadingTo` above), but with `error == nil`
    /// in that case. Since we only care about failures here (the success
    /// path is already handled above), we only act when `error` is non-nil.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let error = error {
                // Resume the continuation with the error
                if let continuation = self.downloadContinuations.removeValue(forKey: taskId) {
                    continuation.resume(throwing: error)
                }
            }
            // Clean up
            if let videoId = self.taskIdToVideoId.removeValue(forKey: taskId) {
                if error != nil {
                    self.downloading.removeValue(forKey: videoId)
                }
            }
        }
    }
    
    /// Called when all background tasks complete and the session
    /// has no more work to do.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Call the background completion handler to let the system know
        // we've processed all completed downloads
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Downloaded Song Model

/// A song that has been downloaded for offline playback.
///
/// Stored in the download index JSON file. Contains metadata for display
/// in the downloads list, plus the filename for locating the audio file.
struct DownloadedSong: Codable, Identifiable {
    /// YouTube video ID (unique identifier)
    let videoId: String
    
    /// Song title (for display in the downloads list)
    let title: String
    
    /// Artist name (for display)
    let artist: String
    
    /// URL to the album art thumbnail (for display)
    let thumbnailUrl: String
    
    /// Filename in the Downloads directory (e.g. "dQw4w9WgXcQ.m4a")
    let fileName: String
    
    /// When the song was downloaded
    let downloadDate: Date
    
    /// Identifiable conformance, use videoId as the unique ID
    var id: String { videoId }
}
