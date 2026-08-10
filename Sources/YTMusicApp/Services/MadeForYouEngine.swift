import Foundation

// MARK: - Made For You Engine

/// Builds a "Made For You" style auto-generated mix from listening history.
///
/// NOT an ObservableObject / NOT a long-lived shared instance, this is a
/// stateless, one-shot builder. HomeView calls `build(...)` once (in a
/// `.task`) and stores the result in local `@State`, the same way it already
/// handles `apiClient.getRelated` elsewhere. There's nothing here that needs
/// to persist or be observed continuously.
///
/// HOW THE MIX IS BUILT (item #1 from the research pass):
/// 1. Take the user's top artists from StatsManager (real listening data,
///    now skip-aware, see StatsManager's reconciliation notes).
/// 2. For each top artist, use one of their most-played songs as a "seed"
///    and fetch YouTube's own related-songs graph for it (`getRelated`).
/// 3. Merge all the candidates, drop duplicates and anything already in the
///    user's top-played list (a "Made For You" mix should surface things
///    adjacent to what's loved, not just replay it, `MostPlayedSection`
///    already covers replaying).
/// 4. Drop anything StatsManager knows the user tends to skip.
/// 5. Interleave (round-robin across seed artists) instead of concatenating,
///    so the mix doesn't front-load 5 songs related to the #1 artist before
///    ever mentioning artist #2.
enum MadeForYouEngine {

    /// Build a "Made For You" mix.
    ///
    /// - Parameters:
    ///   - stats: Source of top artists / most played / skip signal.
    ///   - apiClient: Used to fetch YouTube's related-songs graph per seed.
    ///   - seedArtists: How many top artists to seed from.
    ///   - limit: Max songs in the final mix.
    /// - Returns: A blended list of `SearchResult`s, ready to display and
    ///   play (streaming URL is resolved lazily on tap, same as every other
    ///   browse card in the app).
    @MainActor
    static func build(
        stats: StatsManager,
        apiClient: APIClient,
        seedArtists: Int = 5,
        limit: Int = 20
    ) async -> [SearchResult] {
        // Need at least a little listening history to have any signal,
        // below this, "Made For You" would just be noise. HomeView hides
        // the section entirely when this returns empty.
        guard stats.totalSongsPlayed >= 5 else { return [] }

        let topArtists = Set(stats.topArtists(limit: seedArtists).map { $0.artist })
        guard !topArtists.isEmpty else { return [] }

        // Pick one seed song per top artist: their single most-played track.
        let mostPlayed = stats.mostPlayedSongs(limit: 50)
        var seeds: [(artist: String, videoId: String)] = []
        for artist in stats.topArtists(limit: seedArtists).map({ $0.artist }) {
            if let seedSong = mostPlayed.first(where: { $0.artist == artist }) {
                seeds.append((artist: artist, videoId: seedSong.videoId))
            }
        }
        guard !seeds.isEmpty else { return [] }

        // Fetch related songs for every seed concurrently rather than one
        // at a time, this is a handful of network calls (≤ seedArtists),
        // and doing them in parallel keeps the section from feeling slow to
        // populate on a cold Home screen load.
        let alreadyPlayedIds = Set(mostPlayed.map { $0.videoId })
        var perSeedResults: [[SearchResult]] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for seed in seeds {
                group.addTask {
                    (try? await apiClient.getRelated(videoId: seed.videoId)) ?? []
                }
            }
            for await results in group {
                perSeedResults.append(results)
            }
        }

        // Round-robin interleave across seeds so the mix is varied, not one
        // artist's related songs followed by the next artist's.
        var mix: [SearchResult] = []
        var seen: Set<String> = []
        var index = 0
        while mix.count < limit {
            var addedAny = false
            for candidates in perSeedResults {
                guard index < candidates.count else { continue }
                let candidate = candidates[index]
                addedAny = true
                guard !seen.contains(candidate.id),
                      !alreadyPlayedIds.contains(candidate.id),
                      !stats.isFrequentlySkipped(videoId: candidate.id) else {
                    continue
                }
                seen.insert(candidate.id)
                mix.append(candidate)
                if mix.count >= limit { break }
            }
            if !addedAny { break } // Every seed's candidate list is exhausted
            index += 1
        }

        return mix
    }
}
