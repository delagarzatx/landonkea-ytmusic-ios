import Foundation
import CloudKit

// MARK: - CloudKit Sync, Playlists & Liked Songs Only
//
// SCOPE: This syncs exactly two things across a user's devices via their
// private iCloud database: user-created `Playlist`s (PlaylistManager) and
// liked/favorited song IDs (LikedSongsManager). It intentionally does NOT
// sync play counts, listening stats, queue history, or anything else,
// that's out of scope by design, see StatsManager/PlayCountManager which
// remain purely local.
//
// DESIGN DECISION, raw CloudKit (CKContainer/CKRecord), NOT
// NSPersistentCloudKitContainer / Core Data:
//
// This app does not use Core Data anywhere. Playlists are a JSON file in
// the Documents directory (see PlaylistManager.swift) and liked songs are a
// UserDefaults-backed Set<String> (see LikedSongsManager.swift). Migrating
// either to Core Data purely to get NSPersistentCloudKitContainer's
// automatic sync would mean:
//   1. Rewriting `Playlist`/`NowPlaying` as NSManagedObject subclasses (or a
//      value-type facade over them), which ripples into every view that
//      touches `Playlist.songs`, `PlaylistManager.playlists`, etc., a wide,
//      app-touching refactor exactly of the kind this session was asked to
//      avoid (a concurrent session is editing lyrics/sleep-timer files;
//      minimizing overlap in shared/app-wide files matters).
//   2. Discarding a working, simple, well-tested JSON/UserDefaults storage
//      layer that has nothing wrong with it, CloudKit sync doesn't need
//      Core Data underneath it; NSPersistentCloudKitContainer is a
//      convenience for apps that were ALREADY on Core Data, not a
//      prerequisite for CloudKit sync in general.
//
// Instead, this file layers a sync engine directly on top of the existing
// storage: it reads/writes the same `Playlist` and liked-song data
// PlaylistManager/LikedSongsManager already own, encodes it into CKRecords,
// and merges local vs. remote with an explicit (and unit-testable) conflict
// resolution rule. The two managers gained the minimum surface needed to
// participate (a `modifiedAt` stamp on `Playlist`, per-ID like timestamps in
// LikedSongsManager, and a change notification each), see the comments in
// PlaylistManager.swift and LikedSongsManager.swift for exactly what
// changed there.

// MARK: - CloudRecordStore

/// The subset of CKDatabase operations CloudKitSyncManager needs, expressed
/// as a protocol so tests can swap in an in-memory fake instead of a real
/// CKDatabase. This environment has no signed-in iCloud account / Apple
/// Developer team available, so nothing that talks to `CKContainer.default()`
/// can be exercised for real here, see CloudKitSyncTests.swift for what
/// IS covered (record encode/decode + conflict-resolution merge logic +
/// the orchestration in this file, all run against `InMemoryCloudRecordStore`).
protocol CloudRecordStore {
    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws
    /// Fetches every record of the given type in the given zone. The real
    /// dataset here (a user's playlists + liked songs) is small, hundreds
    /// of records at most, so a single query-based fetch is simpler and
    /// good enough; a larger-scale app would use
    /// CKFetchRecordZoneChangesOperation with a persisted server change
    /// token to fetch only what changed since the last sync.
    func fetchAllRecords(ofType recordType: CKRecord.RecordType, zoneID: CKRecordZone.ID) async throws -> [CKRecord]
    func createZoneIfNeeded(_ zoneID: CKRecordZone.ID) async throws
}

/// Real CloudKit backing, thin adapter over CKDatabase's async API.
/// Exercised only by a real device/simulator signed into iCloud with a real
/// Apple Developer team provisioning `iCloud.com.landonkea.ytmusic`; not
/// unit-tested in this environment (see README's CloudKit Sync section).
struct CKDatabaseRecordStore: CloudRecordStore {
    let database: CKDatabase

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await database.save(record)
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws {
        _ = try await database.deleteRecord(withID: recordID)
    }

    func fetchAllRecords(ofType recordType: CKRecord.RecordType, zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var results: [CKRecord] = []
        var cursor: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        cursor = try await database.records(matching: query, inZoneWith: zoneID)
        results.append(contentsOf: cursor.matchResults.compactMap { try? $0.1.get() })
        while let next = cursor.queryCursor {
            cursor = try await database.records(continuingMatchFrom: next)
            results.append(contentsOf: cursor.matchResults.compactMap { try? $0.1.get() })
        }
        return results
    }

    func createZoneIfNeeded(_ zoneID: CKRecordZone.ID) async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }
}

// MARK: - Record type / field names

/// Centralizes the CKRecord schema so encode and decode can't drift apart,
/// every field name is written once, here, and referenced by both
/// `CloudKitRecordCoding.playlistRecord(from:)` and
/// `CloudKitRecordCoding.playlist(from:)`.
enum CloudKitSchema {
    static let zoneName = "PlaylistSyncZone"
    static let playlistRecordType = "SyncedPlaylist"
    static let likedSongRecordType = "SyncedLikedSong"

    enum PlaylistField {
        static let name = "name"
        static let songsData = "songsData"
        static let createdAt = "createdAt"
        static let isPinned = "isPinned"
        static let modifiedAt = "modifiedAt"
    }

    enum LikedSongField {
        static let videoId = "videoId"
        static let likedAt = "likedAt"
    }
}

// MARK: - Record encode/decode (pure, unit-testable)

/// Converts between the app's local models (`Playlist`, liked-song entries)
/// and `CKRecord`. `CKRecord` itself can be constructed with no network or
/// entitlements, only actually *saving* one to a database requires a real
/// container, so this conversion logic is fully exercised by
/// CloudKitSyncTests.swift without touching CloudKit's network layer.
enum CloudKitRecordCoding {

    static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: CloudKitSchema.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: Playlist <-> CKRecord

    static func record(from playlist: Playlist, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: playlist.id, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.playlistRecordType, recordID: recordID)
        record[CloudKitSchema.PlaylistField.name] = playlist.name as CKRecordValue
        record[CloudKitSchema.PlaylistField.createdAt] = playlist.createdAt as CKRecordValue
        record[CloudKitSchema.PlaylistField.isPinned] = playlist.isPinned as CKRecordValue
        record[CloudKitSchema.PlaylistField.modifiedAt] = playlist.modifiedAt as CKRecordValue
        // Songs are stored as one JSON blob (same Codable NowPlaying array
        // PlaylistManager already persists to disk) rather than as CKAssets
        // or child records, playlists here are small (dozens of songs,
        // not thousands), so one field keeps the sync model simple and
        // avoids needing CKReference bookkeeping for song ordering.
        if let songsData = try? JSONEncoder.cloudKitDefault.encode(playlist.songs) {
            record[CloudKitSchema.PlaylistField.songsData] = songsData as CKRecordValue
        }
        return record
    }

    /// Returns nil if the record is missing required fields (defensively,
    /// a partially-synced or corrupted record shouldn't crash the merge).
    static func playlist(from record: CKRecord) -> Playlist? {
        guard record.recordType == CloudKitSchema.playlistRecordType else { return nil }
        guard
            let name = record[CloudKitSchema.PlaylistField.name] as? String,
            let createdAt = record[CloudKitSchema.PlaylistField.createdAt] as? Date,
            let songsData = record[CloudKitSchema.PlaylistField.songsData] as? Data,
            let songs = try? JSONDecoder.cloudKitDefault.decode([NowPlaying].self, from: songsData)
        else {
            return nil
        }
        let isPinned = (record[CloudKitSchema.PlaylistField.isPinned] as? Bool) ?? false
        // Older/partial records might not have modifiedAt yet, fall back
        // to createdAt so they still sort deterministically in a merge.
        let modifiedAt = (record[CloudKitSchema.PlaylistField.modifiedAt] as? Date) ?? createdAt
        return Playlist(
            id: record.recordID.recordName,
            name: name,
            songs: songs,
            createdAt: createdAt,
            isPinned: isPinned,
            modifiedAt: modifiedAt
        )
    }

    // MARK: LikedSongEntry <-> CKRecord

    static func record(from entry: LikedSongEntry, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: entry.videoId, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.likedSongRecordType, recordID: recordID)
        record[CloudKitSchema.LikedSongField.videoId] = entry.videoId as CKRecordValue
        record[CloudKitSchema.LikedSongField.likedAt] = entry.likedAt as CKRecordValue
        return record
    }

    static func likedSongEntry(from record: CKRecord) -> LikedSongEntry? {
        guard record.recordType == CloudKitSchema.likedSongRecordType else { return nil }
        guard let likedAt = record[CloudKitSchema.LikedSongField.likedAt] as? Date else { return nil }
        let videoId = (record[CloudKitSchema.LikedSongField.videoId] as? String) ?? record.recordID.recordName
        return LikedSongEntry(videoId: videoId, likedAt: likedAt)
    }
}

/// A liked song plus the timestamp it was liked at. The timestamp is what
/// makes cross-device conflict resolution possible, a plain Set<String>
/// (which is all LikedSongsManager stored before CloudKit sync existed) has
/// no way to tell "liked on device A at 2pm" apart from "liked on device B
/// at 3pm" when merging, so ties would be arbitrary. See
/// LikedSongConflictResolver below.
struct LikedSongEntry: Equatable, Codable {
    let videoId: String
    let likedAt: Date
}

private extension JSONEncoder {
    static let cloudKitDefault: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let cloudKitDefault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Conflict resolution (pure, unit-testable)

/// Merge rules used when the same playlist or liked-song ID exists both
/// locally and in the cloud with different content. Both resolvers are
/// last-write-wins by timestamp, the simplest rule that's still correct
/// for this data: a playlist rename/reorder on device A should not be
/// silently discarded in favor of a stale copy from device B just because
/// device B happened to sync first, and vice versa; whichever edit
/// actually happened more recently wins.
enum PlaylistConflictResolver {

    /// Resolves a single ID present on both sides.
    static func resolve(local: Playlist, remote: Playlist) -> Playlist {
        remote.modifiedAt > local.modifiedAt ? remote : local
    }

    /// Merges two full playlist lists into one: IDs unique to either side
    /// are kept as-is (a playlist created on one device and never yet
    /// synced isn't a "conflict"), and IDs present on both sides are
    /// resolved with `resolve(local:remote:)`. Deletions are NOT handled
    /// here, this merge is additive/update-only; see the note on
    /// `CloudKitSyncManager` about deletion being out of scope for this
    /// pass (tracked as a known limitation, see README).
    static func merge(local: [Playlist], remote: [Playlist]) -> [Playlist] {
        var byId: [String: Playlist] = [:]
        for playlist in local { byId[playlist.id] = playlist }
        for remotePlaylist in remote {
            if let existingLocal = byId[remotePlaylist.id] {
                byId[remotePlaylist.id] = resolve(local: existingLocal, remote: remotePlaylist)
            } else {
                byId[remotePlaylist.id] = remotePlaylist
            }
        }
        return Array(byId.values)
    }
}

enum LikedSongConflictResolver {

    /// Merges local and remote liked-song entries into one set of entries.
    /// A song's "liked" state is inherently a single boolean per device at
    /// sync time (this app doesn't track un-like timestamps separately,
    /// unliking simply removes the entry), so the merge rule is: for any
    /// video ID present in only one side, keep it (nothing to conflict
    /// with); for a video ID present on both sides, keep whichever
    /// `likedAt` is newer, this matters once un-like round-trips through
    /// tombstones are added (tracked as a future improvement, not required
    /// for this pass since both sides currently only ever ADD entries here;
    /// removal-merge is handled by `LikedSongsManager.applyMergedEntries`
    /// treating "remote no longer has an ID we also no longer have locally"
    /// as already-consistent, and a fresh local unlike always wins locally
    /// since it's applied after the merge, not before).
    static func merge(local: [LikedSongEntry], remote: [LikedSongEntry]) -> [LikedSongEntry] {
        var byId: [String: LikedSongEntry] = [:]
        for entry in local { byId[entry.videoId] = entry }
        for remoteEntry in remote {
            if let existingLocal = byId[remoteEntry.videoId] {
                byId[remoteEntry.videoId] = remoteEntry.likedAt > existingLocal.likedAt ? remoteEntry : existingLocal
            } else {
                byId[remoteEntry.videoId] = remoteEntry
            }
        }
        return Array(byId.values)
    }
}

// MARK: - CloudKitSyncManager

/// Orchestrates pulling remote playlists/liked songs, merging with local
/// state, applying the merge locally, and pushing anything local-only or
/// newer back up. Talks to CloudKit only through the `CloudRecordStore`
/// protocol, so `CloudKitSyncTests.swift` can inject
/// `InMemoryCloudRecordStore` and exercise the full orchestration,
/// including a simulated two-device conflict, without any real network or
/// iCloud account.
///
/// WHAT THIS DOESN'T DO (by design, kept out of scope):
/// - No listening stats / play counts (see task scope).
/// - No CKSubscription-based push sync, this is pull-driven, triggered on
///   app launch and after local playlist/liked-song changes (see
///   `PlaylistManager`'s and `LikedSongsManager`'s change notifications).
///   A production-grade version would add a CKQuerySubscription + remote
///   push handling in the App Delegate for near-real-time cross-device
///   updates; that requires push entitlements and a real device to test,
///   so it's noted as a follow-up rather than built blind.
/// - No deletion sync, deleting a playlist locally doesn't yet delete its
///   CKRecord. Tracked as a known limitation (see README) rather than
///   silently mis-implemented; it needs tombstone records to do correctly
///   for a merge-based (not authoritative-server) sync design like this one.
@MainActor
final class CloudKitSyncManager {

    private let store: CloudRecordStore
    private let zoneID: CKRecordZone.ID
    private var didCreateZone = false

    /// True while a sync is in flight; used to coalesce rapid-fire triggers
    /// (e.g. several playlist edits in a row) into a single follow-up sync
    /// rather than running them concurrently or dropping them.
    private var isSyncing = false
    private var syncPending = false

    /// Hooks back into the two managers. Set once at app launch
    /// (YTMusicApp.swift). Using closures rather than a hard dependency on
    /// `PlaylistManager`/`LikedSongsManager` types keeps this file
    /// self-contained and keeps the managers ignorant of CloudKit specifics
    /// beyond "here's my current data" / "here's merged data, please apply it."
    var getLocalPlaylists: (() -> [Playlist])?
    var applyMergedPlaylists: (([Playlist]) -> Void)?
    var getLocalLikedEntries: (() -> [LikedSongEntry])?
    var applyMergedLikedEntries: (([LikedSongEntry]) -> Void)?

    init(store: CloudRecordStore, zoneID: CKRecordZone.ID = CloudKitRecordCoding.zoneID()) {
        self.store = store
        self.zoneID = zoneID
    }

    /// Convenience initializer for real app use, wraps
    /// `CKContainer(identifier:).privateCloudDatabase`. The container
    /// identifier matches the entitlement declared in
    /// YTMusicApp.entitlements and project.yml.
    convenience init(containerIdentifier: String = "iCloud.com.landonkea.ytmusic") {
        let container = CKContainer(identifier: containerIdentifier)
        self.init(store: CKDatabaseRecordStore(database: container.privateCloudDatabase))
    }

    /// Runs one full sync pass: pull remote, merge with local, apply merged
    /// result locally, push anything the merge changed back up. Safe to
    /// call repeatedly/concurrently, overlapping calls are coalesced.
    func syncNow() {
        guard !isSyncing else {
            syncPending = true
            return
        }
        isSyncing = true
        Task {
            await performSync()
            isSyncing = false
            if syncPending {
                syncPending = false
                syncNow()
            }
        }
    }

    private func performSync() async {
        do {
            try await store.createZoneIfNeeded(zoneID)
        } catch {
            // No real iCloud account / entitlement in this environment (or
            // the user simply isn't signed in / sync is unavailable), fail
            // soft, exactly like NowPlayingSnapshotStore's App Group
            // no-signing-team fallback documented in this repo. Local
            // playlists/liked songs remain fully usable offline.
            print("CloudKit sync unavailable, skipping: \(error)")
            return
        }

        await syncPlaylists()
        await syncLikedSongs()
    }

    private func syncPlaylists() async {
        guard let getLocalPlaylists, let applyMergedPlaylists else { return }
        let local = getLocalPlaylists()
        do {
            let remoteRecords = try await store.fetchAllRecords(ofType: CloudKitSchema.playlistRecordType, zoneID: zoneID)
            let remote = remoteRecords.compactMap { CloudKitRecordCoding.playlist(from: $0) }
            let merged = PlaylistConflictResolver.merge(local: local, remote: remote)

            if merged != local {
                applyMergedPlaylists(merged)
            }

            // Push every playlist whose local copy is newer than (or absent
            // from) the merged remote snapshot. Since `merged` already
            // reflects "whichever side is newer," anything in `merged`
            // that doesn't byte-for-byte match what's remote needs pushing;
            // we push the full merged set for simplicity, CKRecord.save
            // on an unchanged record is a harmless no-op cost, not a
            // correctness issue.
            for playlist in merged {
                let record = CloudKitRecordCoding.record(from: playlist, zoneID: zoneID)
                _ = try? await store.save(record)
            }
        } catch {
            print("Playlist sync failed: \(error)")
        }
    }

    private func syncLikedSongs() async {
        guard let getLocalLikedEntries, let applyMergedLikedEntries else { return }
        let local = getLocalLikedEntries()
        do {
            let remoteRecords = try await store.fetchAllRecords(ofType: CloudKitSchema.likedSongRecordType, zoneID: zoneID)
            let remote = remoteRecords.compactMap { CloudKitRecordCoding.likedSongEntry(from: $0) }
            let merged = LikedSongConflictResolver.merge(local: local, remote: remote)

            if Set(merged) != Set(local) {
                applyMergedLikedEntries(merged)
            }

            for entry in merged {
                let record = CloudKitRecordCoding.record(from: entry, zoneID: zoneID)
                _ = try? await store.save(record)
            }
        } catch {
            print("Liked songs sync failed: \(error)")
        }
    }
}

extension LikedSongEntry: Hashable {}
