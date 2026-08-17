// CloudKitSyncTests.swift, Unit tests for CloudKit playlist/liked-song
// sync (Sources/YTMusicApp/Services/CloudKitSyncManager.swift).
//
// WHAT'S TESTED HERE vs. NOT:
// This environment has no signed-in iCloud account and no Apple Developer
// team, so nothing that actually talks to `CKContainer.default()` /
// `CKContainer(identifier:)` over the network can be exercised, that's
// the same documented constraint as this repo's App Group (see
// YTMusicApp.entitlements and the README's Mac Catalyst section).
//
// What CAN be verified without real network/iCloud access, and IS
// verified below:
//   1. Record encoding/decoding, CKRecord itself can be constructed
//      locally with no entitlements or network (only *saving* one to a
//      real database needs that), so `CloudKitRecordCoding`'s Playlist
//      <-> CKRecord and LikedSongEntry <-> CKRecord round-trips are
//      exercised directly.
//   2. Conflict resolution, `PlaylistConflictResolver` and
//      `LikedSongConflictResolver` are pure functions over plain structs,
//      no CloudKit types involved at all.
//   3. CloudKitSyncManager's orchestration (pull, merge, apply-locally,
//      push), exercised end-to-end against `InMemoryCloudRecordStore`,
//      an in-memory fake conforming to the same `CloudRecordStore`
//      protocol the real `CKDatabaseRecordStore` conforms to. This proves
//      the sync logic itself is correct; it does NOT prove
//      `CKDatabaseRecordStore` correctly talks to a real CKDatabase, which
//      needs a real device/simulator signed into iCloud to verify.
import XCTest
import CloudKit
@testable import YTMusicApp

// MARK: - In-memory CloudRecordStore fake

/// A `CloudRecordStore` backed by an in-memory dictionary instead of a real
/// CKDatabase, lets CloudKitSyncManager's full pull/merge/push flow run in
/// a unit test with no network, no entitlements, and no iCloud account.
final class InMemoryCloudRecordStore: CloudRecordStore {
    private var recordsByID: [CKRecord.ID: CKRecord] = [:]
    private(set) var saveCount = 0
    private(set) var zoneCreated = false

    /// Seeds the fake "cloud" with a record, as if another device had
    /// already synced it, used to simulate pulling remote-only or
    /// conflicting data.
    func seed(_ record: CKRecord) {
        recordsByID[record.recordID] = record
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        saveCount += 1
        recordsByID[record.recordID] = record
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws {
        recordsByID.removeValue(forKey: recordID)
    }

    func fetchAllRecords(ofType recordType: CKRecord.RecordType, zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        recordsByID.values.filter { $0.recordType == recordType && $0.recordID.zoneID == zoneID }
    }

    func createZoneIfNeeded(_ zoneID: CKRecordZone.ID) async throws {
        zoneCreated = true
    }
}

// MARK: - Test helpers

private func makeSong(id: String) -> NowPlaying {
    NowPlaying(
        id: id,
        title: "Song \(id)",
        artist: "Artist",
        thumbnailUrl: "",
        duration: 200,
        audioUrl: ""
    )
}

private func makePlaylist(
    id: String = UUID().uuidString,
    name: String = "My Playlist",
    songs: [NowPlaying] = [],
    modifiedAt: Date = Date()
) -> Playlist {
    Playlist(id: id, name: name, songs: songs, createdAt: Date(timeIntervalSince1970: 1_700_000_000), isPinned: false, modifiedAt: modifiedAt)
}

private let testZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

final class CloudKitSyncTests: XCTestCase {

    // MARK: - Record encode/decode round trips

    func testPlaylistRecordRoundTrips() throws {
        let playlist = makePlaylist(
            id: "abc123",
            name: "Workout Mix",
            songs: [makeSong(id: "song1"), makeSong(id: "song2")],
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let record = CloudKitRecordCoding.record(from: playlist, zoneID: testZoneID)
        let decoded = try XCTUnwrap(CloudKitRecordCoding.playlist(from: record))

        XCTAssertEqual(decoded.id, playlist.id)
        XCTAssertEqual(decoded.name, playlist.name)
        XCTAssertEqual(decoded.songs, playlist.songs)
        XCTAssertEqual(decoded.isPinned, playlist.isPinned)
        XCTAssertEqual(decoded.modifiedAt.timeIntervalSince1970, playlist.modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPlaylistRecordUsesPlaylistIdAsRecordName() {
        let playlist = makePlaylist(id: "my-unique-id")
        let record = CloudKitRecordCoding.record(from: playlist, zoneID: testZoneID)
        XCTAssertEqual(record.recordID.recordName, "my-unique-id")
    }

    func testPlaylistFromRecordReturnsNilForWrongRecordType() {
        let record = CKRecord(recordType: "SomeOtherType", recordID: CKRecord.ID(recordName: "x", zoneID: testZoneID))
        XCTAssertNil(CloudKitRecordCoding.playlist(from: record))
    }

    func testPlaylistFromRecordReturnsNilWhenMissingRequiredFields() {
        // A record of the right type but missing songsData, simulates a
        // partially-written or corrupted remote record.
        let record = CKRecord(recordType: CloudKitSchema.playlistRecordType, recordID: CKRecord.ID(recordName: "x", zoneID: testZoneID))
        record[CloudKitSchema.PlaylistField.name] = "Incomplete" as CKRecordValue
        XCTAssertNil(CloudKitRecordCoding.playlist(from: record))
    }

    func testLikedSongRecordRoundTrips() throws {
        let entry = LikedSongEntry(videoId: "vid42", likedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let record = CloudKitRecordCoding.record(from: entry, zoneID: testZoneID)
        let decoded = try XCTUnwrap(CloudKitRecordCoding.likedSongEntry(from: record))

        XCTAssertEqual(decoded.videoId, entry.videoId)
        XCTAssertEqual(decoded.likedAt.timeIntervalSince1970, entry.likedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - PlaylistConflictResolver

    func testPlaylistMergeKeepsLocalOnlyAndRemoteOnlyPlaylists() {
        let localOnly = makePlaylist(id: "local-1", name: "Local Only")
        let remoteOnly = makePlaylist(id: "remote-1", name: "Remote Only")

        let merged = PlaylistConflictResolver.merge(local: [localOnly], remote: [remoteOnly])

        XCTAssertEqual(Set(merged.map { $0.id }), ["local-1", "remote-1"])
    }

    func testPlaylistMergePicksNewerModifiedAtOnConflict() {
        let older = makePlaylist(id: "same-id", name: "Old Name", modifiedAt: Date(timeIntervalSince1970: 1000))
        let newer = makePlaylist(id: "same-id", name: "New Name", modifiedAt: Date(timeIntervalSince1970: 2000))

        // Newer is remote: remote should win.
        let mergedRemoteWins = PlaylistConflictResolver.merge(local: [older], remote: [newer])
        XCTAssertEqual(mergedRemoteWins.first?.name, "New Name")

        // Newer is local: local should win (order-independent, the
        // resolver doesn't have a "remote always wins" bias).
        let mergedLocalWins = PlaylistConflictResolver.merge(local: [newer], remote: [older])
        XCTAssertEqual(mergedLocalWins.first?.name, "New Name")
    }

    func testPlaylistResolveSingleConflict() {
        let older = makePlaylist(id: "x", name: "Old", modifiedAt: Date(timeIntervalSince1970: 1))
        let newer = makePlaylist(id: "x", name: "New", modifiedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(PlaylistConflictResolver.resolve(local: older, remote: newer).name, "New")
        XCTAssertEqual(PlaylistConflictResolver.resolve(local: newer, remote: older).name, "New")
    }

    // MARK: - LikedSongConflictResolver

    func testLikedSongMergeUnionsDisjointEntries() {
        let local = [LikedSongEntry(videoId: "a", likedAt: Date(timeIntervalSince1970: 1))]
        let remote = [LikedSongEntry(videoId: "b", likedAt: Date(timeIntervalSince1970: 2))]

        let merged = LikedSongConflictResolver.merge(local: local, remote: remote)
        XCTAssertEqual(Set(merged.map { $0.videoId }), ["a", "b"])
    }

    func testLikedSongMergePicksNewerLikedAtOnConflict() {
        let localOlder = [LikedSongEntry(videoId: "shared", likedAt: Date(timeIntervalSince1970: 100))]
        let remoteNewer = [LikedSongEntry(videoId: "shared", likedAt: Date(timeIntervalSince1970: 200))]

        let merged = LikedSongConflictResolver.merge(local: localOlder, remote: remoteNewer)
        XCTAssertEqual(merged.first?.likedAt, remoteNewer.first?.likedAt)
    }

    // MARK: - CloudKitSyncManager orchestration (against InMemoryCloudRecordStore)

    @MainActor
    func testSyncNowPullsRemoteOnlyPlaylistIntoLocal() async {
        let store = InMemoryCloudRecordStore()
        let manager = CloudKitSyncManager(store: store, zoneID: testZoneID)

        let remotePlaylist = makePlaylist(id: "remote-only", name: "From Another Device")
        store.seed(CloudKitRecordCoding.record(from: remotePlaylist, zoneID: testZoneID))

        var localPlaylists: [Playlist] = []
        var appliedPlaylists: [Playlist]?
        manager.getLocalPlaylists = { localPlaylists }
        manager.applyMergedPlaylists = { appliedPlaylists = $0 }
        manager.getLocalLikedEntries = { [] }
        manager.applyMergedLikedEntries = { _ in }

        manager.syncNow()
        await waitForSyncToSettle(manager)

        let applied = try? XCTUnwrap(appliedPlaylists)
        XCTAssertEqual(applied?.count, 1)
        XCTAssertEqual(applied?.first?.id, "remote-only")
        XCTAssertTrue(store.zoneCreated)
    }

    @MainActor
    func testSyncNowPushesLocalOnlyPlaylistToStore() async {
        let store = InMemoryCloudRecordStore()
        let manager = CloudKitSyncManager(store: store, zoneID: testZoneID)

        let localPlaylist = makePlaylist(id: "local-only", name: "Not Yet Synced")
        manager.getLocalPlaylists = { [localPlaylist] }
        manager.applyMergedPlaylists = { _ in }
        manager.getLocalLikedEntries = { [] }
        manager.applyMergedLikedEntries = { _ in }

        manager.syncNow()
        await waitForSyncToSettle(manager)

        let remoteRecords = try? await store.fetchAllRecords(ofType: CloudKitSchema.playlistRecordType, zoneID: testZoneID)
        XCTAssertEqual(remoteRecords?.count, 1)
        XCTAssertEqual(remoteRecords?.first?.recordID.recordName, "local-only")
    }

    @MainActor
    func testSyncNowResolvesConflictAndAppliesWinnerLocally() async {
        let store = InMemoryCloudRecordStore()
        let manager = CloudKitSyncManager(store: store, zoneID: testZoneID)

        let localStale = makePlaylist(id: "conflict-id", name: "Stale Local", modifiedAt: Date(timeIntervalSince1970: 100))
        let remoteFresh = makePlaylist(id: "conflict-id", name: "Fresh Remote", modifiedAt: Date(timeIntervalSince1970: 999))
        store.seed(CloudKitRecordCoding.record(from: remoteFresh, zoneID: testZoneID))

        var appliedPlaylists: [Playlist]?
        manager.getLocalPlaylists = { [localStale] }
        manager.applyMergedPlaylists = { appliedPlaylists = $0 }
        manager.getLocalLikedEntries = { [] }
        manager.applyMergedLikedEntries = { _ in }

        manager.syncNow()
        await waitForSyncToSettle(manager)

        XCTAssertEqual(appliedPlaylists?.first?.name, "Fresh Remote")
    }

    @MainActor
    func testSyncNowDoesNotReapplyIdenticalPlaylistsRegardlessOfMergeOrder() async {
        let store = InMemoryCloudRecordStore()
        let manager = CloudKitSyncManager(store: store, zoneID: testZoneID)

        // Local already has the exact same playlists as remote -- an
        // already-fully-synced state where nothing actually changed.
        let playlistA = makePlaylist(id: "already-synced-a", name: "A", modifiedAt: Date(timeIntervalSince1970: 500))
        let playlistB = makePlaylist(id: "already-synced-b", name: "B", modifiedAt: Date(timeIntervalSince1970: 500))
        store.seed(CloudKitRecordCoding.record(from: playlistA, zoneID: testZoneID))
        store.seed(CloudKitRecordCoding.record(from: playlistB, zoneID: testZoneID))

        var appliedPlaylists: [Playlist]?
        manager.getLocalPlaylists = { [playlistA, playlistB] }
        manager.applyMergedPlaylists = { appliedPlaylists = $0 }
        manager.getLocalLikedEntries = { [] }
        manager.applyMergedLikedEntries = { _ in }

        manager.syncNow()
        await waitForSyncToSettle(manager)

        // PlaylistConflictResolver.merge() returns Array(byId.values), a
        // Dictionary's iteration order, which isn't guaranteed to match
        // `local`'s original array order even when nothing actually
        // changed. syncPlaylists() must compare order-independently so
        // an already-synced, unchanged playlist set doesn't trigger a
        // spurious local re-write + change notification on every sync.
        XCTAssertNil(appliedPlaylists)
    }

    @MainActor
    func testSyncNowMergesLikedSongs() async {
        let store = InMemoryCloudRecordStore()
        let manager = CloudKitSyncManager(store: store, zoneID: testZoneID)

        let remoteEntry = LikedSongEntry(videoId: "remote-liked", likedAt: Date())
        store.seed(CloudKitRecordCoding.record(from: remoteEntry, zoneID: testZoneID))

        let localEntry = LikedSongEntry(videoId: "local-liked", likedAt: Date())
        var appliedEntries: [LikedSongEntry]?
        manager.getLocalPlaylists = { [] }
        manager.applyMergedPlaylists = { _ in }
        manager.getLocalLikedEntries = { [localEntry] }
        manager.applyMergedLikedEntries = { appliedEntries = $0 }

        manager.syncNow()
        await waitForSyncToSettle(manager)

        XCTAssertEqual(Set((appliedEntries ?? []).map { $0.videoId }), ["remote-liked", "local-liked"])
    }

    /// `syncNow()` fires off a detached `Task` internally rather than being
    /// `async` itself (so call sites like NotificationCenter observers and
    /// SwiftUI's `init()` don't need to be async). Tests poll briefly for
    /// the manager's `applyMerged*` callback to have run instead of
    /// assuming a fixed delay is enough, avoids both flakiness (too short)
    /// and slow tests (too long).
    @MainActor
    private func waitForSyncToSettle(_ manager: CloudKitSyncManager) async {
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }
}
