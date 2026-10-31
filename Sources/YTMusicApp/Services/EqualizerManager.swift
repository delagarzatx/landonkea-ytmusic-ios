import AVFoundation
import SwiftUI

// MARK: - Equalizer Manager

/// Manages equalizer settings (presets, band gains) and pushes them
/// to the active playback engine.
///
/// WHAT IS AN EQUALIZER?
/// An equalizer (EQ) adjusts the volume of different frequency ranges in audio.
/// - Bass (low frequencies): 60Hz-250Hz, the "thump" you feel in your chest
/// - Mids (mid frequencies): 250Hz-4kHz, vocals, guitars, most instruments
/// - Treble (high frequencies): 4kHz-16kHz, cymbals, hi-hats, sparkle
///
/// HOW IT WORKS:
/// This class is the "brains" of the EQ, it stores the settings and
/// exposes methods the UI calls (applyPreset, setBand, toggle). It does
/// NOT own the audio processing itself. The actual equalizer lives in
/// EqualizerEngine (AVAudioUnitEQ inside an AVAudioEngine), which is used
/// by AudioPlayer for LOCAL file playback. This manager pushes the gains
/// to that engine through the `onGainsChanged` callback.
///
/// WHY NOT EVERYTHING?
/// iOS does not let apps insert an equalizer into AVPlayer's audio path.
/// Streamed songs therefore cannot be equalized, the equalizer only
/// affects downloaded (offline) songs played through EqualizerEngine.
///
/// We provide presets (Flat, Bass Boost, etc.) that set all 31 bands at
/// once for common listening scenarios (authored at 10 anchor frequencies
/// and interpolated onto the 31 ISO bands).
///
/// WHAT IS "ObservableObject"?
/// This is a protocol (a contract a type promises to follow) from SwiftUI's
/// Combine-based data flow. Conforming to it means SwiftUI views can
/// "subscribe" to this object and automatically redraw themselves whenever
/// one of its `@Published` properties changes, we never have to manually
/// tell the UI to refresh.
class EqualizerManager: ObservableObject {
    
    // MARK: - Shared Instance
    
    /// The single app-wide equalizer manager.
    /// AudioPlayer looks this up when it needs to know whether the EQ is on
    /// and what gains to apply. This mirrors the PlayCountManager.shared pattern.
    static var shared: EqualizerManager?
    
    // MARK: - Published Properties
    
    /// Whether the equalizer is enabled.
    /// When disabled, audio passes through unprocessed.
    ///
    /// WHAT IS "@Published"?
    /// This property wrapper (a special annotation that adds behavior to a
    /// stored property) automatically announces changes to this value to
    /// anything observing this object (like a SwiftUI view). Whenever
    /// `isEnabled` is set to a new value, every view reading it re-renders.
    @Published var isEnabled: Bool = false
    
    /// The name of the currently active preset.
    @Published var activePreset: String = "Flat"
    
    /// Individual band gains (in decibels) for the 31 frequency bands.
    /// Range: -12.0 to +12.0 dB. 0.0 = no change (flat).
    @Published var bandGains: [Double] = Array(repeating: 0.0, count: 31)

    /// Preamp gain in decibels (-12 to +12), applied on top of the bands
    /// via the EQ node's globalGain. The classic Winamp EQ has a preamp
    /// slider on the far left; this is that slider's value.
    @Published var preamp: Double = 0.0

    /// User-saved custom presets: name → 31 band gains, e.g.
    /// `["Gym Mix": [8, 6, 4, ...]]`. Unlike the built-in `presets`
    /// dictionary (a `static let`, baked into the app), these are created
    /// by the user from whatever they've dialed in on the sliders and
    /// persisted to UserDefaults so they survive a relaunch, previously
    /// there was only a transient, unsaveable "Custom" state that reverted
    /// the moment you picked a different preset or restarted the app.
    @Published private(set) var customPresets: [String: [Double]] = [:]
    
    // MARK: - Callback
    
    /// Called whenever the gains change (preset applied, band dragged, toggle).
    /// AudioPlayer registers this to push the new gains into the live
    /// EqualizerEngine node, so changes apply while a song is playing.
    var onGainsChanged: (([Double]) -> Void)?

    /// Called whenever the preamp changes. AudioPlayer registers this to
    /// push the value into the live EqualizerEngine's globalGain.
    var onPreampChanged: ((Double) -> Void)?

    // MARK: - Frequency Band Definitions

    /// The center frequencies for each of the 31 EQ bands.
    /// These are the standard ISO 1/3-octave frequencies used by
    /// professional 31-band graphic equalizers (20 Hz to 20 kHz).
    static let bandFrequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
        20000
    ]

    /// Human-readable labels for each frequency band.
    static let bandLabels: [String] = [
        "20", "25", "31", "40", "50", "63", "80", "100", "125", "160",
        "200", "250", "315", "400", "500", "630", "800", "1K", "1.2K", "1.6K",
        "2K", "2.5K", "3.1K", "4K", "5K", "6.3K", "8K", "10K", "12K", "16K",
        "20K"
    ]

    /// The 10 anchor frequencies the preset curves below were authored at
    /// (the classic 10-band layout). Preset anchor gains are interpolated
    /// in log-frequency space onto the 31 ISO bands by `expandToFullBands`.
    static let presetAnchorFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Interpolate a 10-anchor gain curve onto all 31 bands.
    /// Frequencies below/above the anchor range clamp to the end anchors.
    static func expandToFullBands(_ anchors: [Double]) -> [Double] {
        guard anchors.count == presetAnchorFrequencies.count else {
            return Array(repeating: 0.0, count: bandFrequencies.count)
        }
        return bandFrequencies.map { freq in
            if freq <= presetAnchorFrequencies.first! {
                return anchors.first!
            }
            if freq >= presetAnchorFrequencies.last! {
                return anchors.last!
            }
            for i in 0..<(presetAnchorFrequencies.count - 1) {
                let f0 = presetAnchorFrequencies[i]
                let f1 = presetAnchorFrequencies[i + 1]
                if freq >= f0 && freq <= f1 {
                    let t = (log2(freq) - log2(f0)) / (log2(f1) - log2(f0))
                    return anchors[i] + t * (anchors[i + 1] - anchors[i])
                }
            }
            return 0.0
        }
    }

    // MARK: - Equalizer Presets

    /// Pre-configured EQ settings for common listening scenarios, stored
    /// as 10 anchor gains and expanded to the full 31 bands on access.
    /// Values are in decibels: -12.0 to +12.0.
    static let presetAnchors: [String: [Double]] = [
        // Flat, no change, all bands at 0 dB
        "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        
        // Bass Boost, boosts low frequencies for more thump
        "Bass Boost": [8, 6, 4, 2, 0, 0, 0, 0, 0, 0],
        
        // Treble Boost, boosts high frequencies for more sparkle
        "Treble Boost": [0, 0, 0, 0, 0, 2, 4, 6, 8, 8],
        
        // Vocal, emphasizes mid-range for clearer speech/lyrics
        "Vocal": [0, 0, 0, 2, 4, 4, 2, 0, 0, 0],
        
        // Rock, boosts bass and treble, cuts mids slightly (classic "smile" curve)
        "Rock": [6, 4, 0, -2, 0, 2, 4, 6, 6, 4],
        
        // Pop, boosts bass and treble for a punchy sound
        "Pop": [4, 2, 0, 0, 2, 4, 4, 2, 2, 0],
        
        // Jazz, warm mids and smooth treble
        "Jazz": [0, 2, 4, 4, 2, 0, 2, 4, 2, 0],
        
        // Classical, wide dynamic range, gentle boost across spectrum
        "Classical": [4, 2, 0, 0, 0, 0, 0, 2, 4, 6],
        
        // Electronic, heavy bass, crisp highs for EDM/dance
        "Electronic": [8, 6, 2, 0, 0, 0, 2, 4, 6, 8],
        
        // Acoustic, warm, natural sound for acoustic instruments
        "Acoustic": [2, 4, 4, 2, 0, 0, 2, 4, 2, 0],
        
        // Hip-Hop, deep bass, clear mids for vocals
        "Hip-Hop": [8, 6, 2, 0, 2, 0, 0, 2, 4, 2],
        
        // Loudness, boosts everything for low-volume listening
        "Loudness": [6, 4, 0, -2, 0, 0, -2, 2, 6, 8]
    ]

    /// The built-in presets expanded onto all 31 bands.
    static let presets: [String: [Double]] = presetAnchors.mapValues { expandToFullBands($0) }
    
    // MARK: - Initialization
    
    /// Create the equalizer manager and load saved settings.
    init() {
        loadSettings()
        loadCustomPresets()
    }

    // MARK: - Public Methods

    /// Apply a preset by name.
    ///
    /// Checks the built-in `presets` dictionary first, then the user's
    /// saved `customPresets`, so this one method works for either kind,
    /// and callers (EqualizerView) don't need to know which list a given
    /// preset name came from.
    ///
    /// - Parameter preset: The name of the preset (e.g. "Bass Boost" or a
    ///   user-created custom preset name)
    func applyPreset(_ preset: String) {
        guard let raw = EqualizerManager.presets[preset] ?? customPresets[preset] else { return }

        // Built-in presets and new custom presets already carry 31 gains;
        // custom presets saved by older versions carry 10 and are expanded.
        let gains: [Double]
        if raw.count == EqualizerManager.bandFrequencies.count {
            gains = raw
        } else if raw.count == EqualizerManager.presetAnchorFrequencies.count {
            gains = EqualizerManager.expandToFullBands(raw)
        } else {
            return
        }

        activePreset = preset
        bandGains = gains
        applyGains()
        saveSettings()
    }

    /// Save the CURRENT band gains as a new named custom preset (or
    /// overwrite an existing custom preset with the same name).
    ///
    /// - Parameter name: The user-chosen preset name. Ignored (no-op) if
    ///   empty/whitespace-only after trimming.
    func saveCustomPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        customPresets[trimmed] = bandGains
        // Saving effectively "names" whatever was in the transient
        // "Custom" state, so make the newly-saved preset the active one.
        activePreset = trimmed
        saveCustomPresets()
        saveSettings()
    }

    /// Delete a previously saved custom preset.
    ///
    /// If the deleted preset was the currently active one, falls back to
    /// "Flat" rather than leaving `activePreset` pointing at a name that no
    /// longer exists in `customPresets`.
    func deleteCustomPreset(name: String) {
        customPresets.removeValue(forKey: name)

        if activePreset == name {
            applyPreset("Flat")
        }

        saveCustomPresets()
    }

    /// Set the gain for a specific frequency band.
    ///
    /// - Parameters:
    ///   - band: Band index (0-30)
    ///   - gain: Gain in decibels (-12.0 to +12.0)
    func setBand(_ band: Int, gain: Double) {
        guard band >= 0 && band < EqualizerManager.bandFrequencies.count else { return }
        
        // Clamp gain to valid range
        let clampedGain = min(max(gain, -12.0), 12.0)
        bandGains[band] = clampedGain
        
        // When user manually adjusts a band, switch to "Custom" preset
        activePreset = "Custom"
        
        applyGains()
        saveSettings()
    }
    
    /// Set the preamp gain in decibels (-12 to +12) and push it live.
    func setPreamp(_ newValue: Double) {
        preamp = min(max(newValue, -12.0), 12.0)
        if isEnabled {
            onPreampChanged?(preamp)
        }
        saveSettings()
    }

    /// Toggle the equalizer on/off.
    func toggle() {
        isEnabled.toggle()

        if isEnabled {
            applyGains()
            onPreampChanged?(preamp)
        } else {
            // Reset all bands to flat when disabled
            let flatGains = Array(repeating: 0.0, count: EqualizerManager.bandFrequencies.count)
            applyGainsToEQ(flatGains)
            onPreampChanged?(0.0)
        }

        saveSettings()
    }
    
    // MARK: - Private Methods
    
    /// Apply the current bandGains to the equalizer node.
    private func applyGains() {
        applyGainsToEQ(bandGains)
    }
    
    /// Apply specific gain values to the equalizer.
    ///
    /// The actual audio processing lives in EqualizerEngine (which owns the
    /// AVAudioUnitEQ). This manager's job is to PUSH the new gains there,
    /// via the onGainsChanged callback, so they take effect immediately
    /// even while a song is playing.
    private func applyGainsToEQ(_ gains: [Double]) {
        // Notify the active EqualizerEngine (set up by AudioPlayer)
        // with the new gains, so its EQ node updates live
        onGainsChanged?(gains)
    }
    
    /// Save equalizer settings to UserDefaults.
    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "eqEnabled")
        UserDefaults.standard.set(activePreset, forKey: "eqPreset")
        UserDefaults.standard.set(bandGains, forKey: "eqBandGains")
        UserDefaults.standard.set(preamp, forKey: "eqPreamp")
    }

    /// Load equalizer settings from UserDefaults.
    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        activePreset = UserDefaults.standard.string(forKey: "eqPreset") ?? "Flat"
        preamp = UserDefaults.standard.double(forKey: "eqPreamp")

        if let savedGains = UserDefaults.standard.array(forKey: "eqBandGains") as? [Double] {
            if savedGains.count == EqualizerManager.bandFrequencies.count {
                bandGains = savedGains
            } else if savedGains.count == EqualizerManager.presetAnchorFrequencies.count {
                // Settings saved by the old 10-band version: expand the
                // curve onto the 31 bands instead of discarding it.
                bandGains = EqualizerManager.expandToFullBands(savedGains)
            }
        }
    }

    /// Save `customPresets` to UserDefaults.
    ///
    /// `[String: [Double]]` is a "property list" compatible type (only
    /// Strings, Numbers, and nested collections of those), `UserDefaults`
    /// can store it directly, no manual JSON encoding needed, the same way
    /// `isEnabled`/`activePreset`/`bandGains` are stored above.
    private func saveCustomPresets() {
        UserDefaults.standard.set(customPresets, forKey: "eqCustomPresets")
    }

    /// Load `customPresets` from UserDefaults.
    private func loadCustomPresets() {
        if let saved = UserDefaults.standard.dictionary(forKey: "eqCustomPresets") as? [String: [Double]] {
            customPresets = saved
        }
    }
}
