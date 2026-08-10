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
/// We provide presets (Flat, Bass Boost, etc.) that set all 10 bands at once
/// for common listening scenarios.
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
    
    /// Individual band gains (in decibels) for the 10 frequency bands.
    /// Range: -12.0 to +12.0 dB. 0.0 = no change (flat).
    @Published var bandGains: [Double] = Array(repeating: 0.0, count: 10)

    /// User-saved custom presets: name → 10 band gains, e.g.
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
    
    // MARK: - Frequency Band Definitions
    
    /// The center frequencies for each of the 10 EQ bands.
    /// These are the standard frequencies used by most music players.
    /// Each band controls a range around its center frequency.
    static let bandFrequencies: [Double] = [
        32,      // Sub-bass, very low rumble (kick drums, bass guitar)
        64,      // Bass, deep thump (bass guitar, kick drum body)
        125,     // Low-mid bass, warmth (lower vocals, guitar body)
        250,     // Mid, fullness (vocals, guitar, piano)
        500,     // Low-mid treble, clarity (vocal articulation)
        1000,    // Mid treble, presence (vocal brightness, snare)
        2000,    // Upper-mid treble, definition (guitar picking, vocal edge)
        4000,    // Treble, attack (cymbal crash, hi-hat attack)
        8000,    // Upper treble, sparkle (cymbal shimmer, air)
        16000    // Brilliance, ultra-high (harmonic overtones, air)
    ]
    
    /// Human-readable labels for each frequency band.
    static let bandLabels: [String] = [
        "32", "64", "125", "250", "500",
        "1K", "2K", "4K", "8K", "16K"
    ]
    
    // MARK: - Equalizer Presets
    
    /// Pre-configured EQ settings for common listening scenarios.
    /// Each preset is an array of 10 gain values (one per frequency band).
    /// Values are in decibels: -12.0 to +12.0.
    static let presets: [String: [Double]] = [
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
        guard let gains = EqualizerManager.presets[preset] ?? customPresets[preset] else { return }

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
    ///   - band: Band index (0-9)
    ///   - gain: Gain in decibels (-12.0 to +12.0)
    func setBand(_ band: Int, gain: Double) {
        guard band >= 0 && band < 10 else { return }
        
        // Clamp gain to valid range
        let clampedGain = min(max(gain, -12.0), 12.0)
        bandGains[band] = clampedGain
        
        // When user manually adjusts a band, switch to "Custom" preset
        activePreset = "Custom"
        
        applyGains()
        saveSettings()
    }
    
    /// Toggle the equalizer on/off.
    func toggle() {
        isEnabled.toggle()
        
        if isEnabled {
            applyGains()
        } else {
            // Reset all bands to flat when disabled
            let flatGains = Array(repeating: 0.0, count: 10)
            applyGainsToEQ(flatGains)
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
    }
    
    /// Load equalizer settings from UserDefaults.
    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        activePreset = UserDefaults.standard.string(forKey: "eqPreset") ?? "Flat"

        if let savedGains = UserDefaults.standard.array(forKey: "eqBandGains") as? [Double],
           savedGains.count == 10 {
            bandGains = savedGains
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
