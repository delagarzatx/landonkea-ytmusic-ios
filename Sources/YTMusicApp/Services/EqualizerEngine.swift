// EqualizerEngine.swift, Plays local audio files through a real 31-band
// equalizer using AVAudioEngine.
//
// WHY THIS EXISTS:
// AVPlayer (used for normal playback) does NOT let apps insert an
// equalizer into its audio pipeline. So this class provides an
// ALTERNATIVE playback path that uses AVAudioEngine + AVAudioPlayerNode +
// AVAudioUnitEQ. AudioPlayer uses this engine only when:
//   1. The user has the equalizer turned ON, AND
//   2. The song is being played from a LOCAL file (a downloaded song).
// Streamed songs keep using AVPlayer, which cannot be equalized on iOS.
//
// AUDIO GRAPH:
//   AVAudioPlayerNode  →  AVAudioUnitTimePitch (playback speed)  →
//   AVAudioUnitEQ (31 bands)  →  mainMixerNode  →  output
//
// All methods are marked @MainActor because the engine is driven from the
// UI thread (timers, play/pause buttons, sliders).

import Accelerate
import AVFoundation

// MARK: - Equalizer Engine

@MainActor
class EqualizerEngine {
    
    // MARK: - Callbacks
    
    /// Called ~4 times per second with the current playback position (seconds).
    /// AudioPlayer uses this to update the progress bar and Control Center.
    var onTimeUpdate: ((Double) -> Void)?
    
    /// Called when the current file finishes playing naturally (not stopped).
    /// AudioPlayer uses this to advance to the next song in the queue.
    var onSongEnded: (() -> Void)?

    /// Called ~15 times per second with 24 spectrum levels (0.0 to 1.0),
    /// computed from a real FFT of the playing audio. AudioPlayer forwards
    /// these to the Winamp-style visualizer in the player screen.
    var onLevels: (([Float]) -> Void)?
    
    // MARK: - Private Properties
    
    /// The audio engine that runs the whole audio graph.
    /// Created lazily the first time we play a file.
    private let engine = AVAudioEngine()
    
    /// The player node, the "source" that feeds audio into the graph.
    /// It reads the audio file and pushes buffers down the chain.
    private let playerNode = AVAudioPlayerNode()
    
    /// The time pitch unit, adjusts playback speed (0.5x, 1.0x, 2.0x).
    /// AVPlayer has built-in rate control, but AVAudioPlayerNode does not,
    /// so we use this AVAudioUnit to get the same feature.
    private let timePitch = AVAudioUnitTimePitch()
    
    /// The actual equalizer node with 31 frequency bands (ISO 1/3-octave,
    /// like a professional graphic EQ). This is the node that makes the
    /// EQ real, it boosts/cuts frequencies.
    private let eqNode = AVAudioUnitEQ(numberOfBands: 31)
    
    /// The currently open audio file being played.
    /// Kept as a property so we can re-schedule segments for seeking.
    private var audioFile: AVAudioFile?
    
    /// True when the user (or AudioPlayer) has stopped playback on purpose.
    /// Used to ignore the completion handler when the stop was intentional,
    /// otherwise stopping a song would look like it "ended naturally".
    private var isStopping = false
    
    /// Prevents the song-ended callback from firing more than once per song.
    private var hasEnded = false
    
    /// A counter that identifies the CURRENT scheduled segment.
    /// Each time we (re)schedule a segment, including after a seek, we
    /// bump this counter. Completion callbacks from OLD segments capture the
    /// counter value from when they were scheduled; if the value no longer
    /// matches, the callback is stale (it was cancelled by a seek) and is
    /// ignored. This prevents a seek from being mistaken for a song ending.
    private var segmentID = 0
    
    /// The timer that polls the playback position and fires onTimeUpdate.
    private var timeTimer: Timer?
    
    /// The playback speed (0.5 - 2.0). 1.0 = normal speed.
    private var rate: Double = 1.0
    
    /// The output volume (0.0 - 1.0). Applied to the main mixer node.
    private var volume: Double = 1.0
    
    /// The current EQ gains in decibels (-12 to +12), one per band.
    private var gains: [Double] = Array(repeating: 0.0, count: 31)

    /// The center frequency for each of the 31 EQ bands.
    /// Must match EqualizerManager.bandFrequencies so the sliders line up.
    private var frequencies: [Double] = EqualizerManager.bandFrequencies

    /// Whether the spectrum tap is already installed on the mixer.
    /// The mixer node lives for the engine's whole lifetime, so the tap
    /// is installed exactly once (installing twice throws).
    private var spectrumTapInstalled = false

    /// Buffer counter used to throttle spectrum callbacks to ~15/second.
    private var spectrumBufferCount = 0

    /// Reusable FFT setup for the spectrum analyzer (1024-point FFT).
    private var fftSetup: FFTSetup?

    /// Smoothed spectrum levels, so the visualizer bars fall gracefully
    /// instead of jittering on every buffer.
    private var smoothedLevels: [Float] = Array(repeating: 0, count: 24)
    
    /// The sample rate of the current audio file (frames per second).
    /// Used to convert between seconds and sample frames when seeking.
    private var sampleRate: Double = 44100
    
    /// The total duration of the current file in seconds.
    /// Used by the time-pitch unit and for seek calculations.
    private var fileDuration: Double = 0

    /// Where in the file the CURRENT scheduled segment starts, in seconds.
    /// playerNode.playerTime(forNodeTime:) (see `currentTime` below) resets
    /// to 0 on every stop()/play() cycle, it measures elapsed time since
    /// the node was last started, not a position within the file. Every
    /// seek stops and restarts the node at a new starting frame, so
    /// without this offset, currentTime would report time-since-the-last-
    /// seek instead of the actual position in the song.
    private var segmentStartSeconds: Double = 0

    // MARK: - Initialization

    /// Attach all three custom nodes to the engine.
    ///
    /// WHY THIS IS REQUIRED: AVAudioEngine.connect(_:to:format:) will THROW
    /// an uncaught Objective-C exception (crashing the app) if either node
    /// passed to it hasn't been attached to the engine first via
    /// engine.attach(_:), attaching and connecting are separate steps.
    /// (engine.mainMixerNode is attached automatically by the engine itself,
    /// so it doesn't need this.)
    ///
    /// We attach exactly once here, in init, rather than in buildGraph().
    /// buildGraph() re-runs every time playFile() is called (including
    /// replays on the same engine instance), and re-attaching an
    /// already-attached node also throws, so attaching must happen exactly
    /// once per node's lifetime, and init is the only place that's true.
    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(eqNode)
    }

    deinit {
        // Engines are created per song; release the FFT setup so a long
        // session doesn't accumulate one setup per track.
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - Public Playback Controls
    
    /// Start playing a local audio file through the equalizer.
    ///
    /// - Parameters:
    ///   - url: The local file URL of the downloaded song.
    ///   - rate: Playback speed (1.0 = normal).
    ///   - volume: Output volume (0.0 - 1.0).
    ///   - gains: 31 EQ gain values in decibels (-12 to +12).
    ///   - frequencies: 31 center frequencies for the EQ bands.
    ///   - preamp: Overall gain in decibels applied via the EQ node's
    ///             globalGain (the Winamp preamp slider).
    ///   - completion: Called once the file is open and playing, with the
    ///                 file's duration in seconds (0 if setup failed).
    func playFile(
        url: URL,
        rate: Double,
        volume: Double,
        gains: [Double],
        frequencies: [Double],
        preamp: Double,
        completion: @escaping (Double) -> Void
    ) {
        // Reset the ended-flag so a fresh song can end cleanly later
        hasEnded = false
        // Reset the intentional-stop flag so completion handlers are honored
        isStopping = false
        // Store the playback speed and volume for later use
        self.rate = rate
        self.volume = volume
        // Store the EQ gains and frequencies (sliders → these values)
        self.gains = gains
        self.frequencies = frequencies
        
        // Open the audio file so we can read its frames and sample rate
        guard let file = try? AVAudioFile(forReading: url) else {
            // If the file can't be opened, report 0 duration so the caller
            // can fall back to whatever it knows
            completion(0)
            return
        }
        
        // Stop any existing playback and clear the graph before reconfiguring.
        //
        // BUG FIX: this used to run AFTER `self.audioFile = file` was set
        // below. stopInternal() sets `audioFile = nil` as part of tearing
        // down the previous playback session, so calling it after
        // assigning the new file immediately wiped the reference right
        // back out again. scheduleSegment() (called further down) reads
        // `audioFile` and silently does nothing if it's nil, which meant
        // the engine would start "playing" with nothing actually
        // scheduled, dead silence, with no error. Running stopInternal()
        // FIRST (before the new file is assigned) means it only ever
        // clears the OLD file, never the one we're about to play.
        stopInternal()

        // Keep a reference to the file (needed for seeking)
        self.audioFile = file
        // Remember the sample rate for second↔frame conversions
        self.sampleRate = file.processingFormat.sampleRate
        // Compute the duration: total frames ÷ frames per second
        self.fileDuration = Double(file.length) / sampleRate

        // Build the audio graph (connect nodes in the right order)
        buildGraph(format: file.processingFormat)
        // Configure the EQ bands with the chosen frequencies and gains
        configureEQ()
        // Apply the preamp as the EQ node's overall gain
        eqNode.globalGain = Float(preamp)
        // Configure the playback speed
        timePitch.rate = Float(rate)
        // Configure the output volume
        engine.mainMixerNode.outputVolume = Float(volume)
        
        // Schedule the entire file (from frame 0 to the end) for playback
        segmentStartSeconds = 0
        scheduleSegment(startingFrame: 0)
        
        // Prepare the engine (allocates resources) and start it running
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // If the engine can't start (rare), report failure
            print("EqualizerEngine failed to start: \(error)")
            completion(0)
            return
        }
        
        // Start the player node, audio now flows through the EQ
        playerNode.play()
        // Feed the spectrum visualizer (tap installed once per engine)
        installSpectrumTapIfNeeded()
        // Start polling the playback position for progress updates
        startTimeTimer()
        
        // Let the caller know how long the song is
        completion(fileDuration)
    }
    
    /// Pause playback (keep the position so resume() can continue from here).
    func pause() {
        // AVAudioPlayerNode.pause() stops output but keeps the playhead
        playerNode.pause()
        // Stop the timer while paused (no movement to report)
        stopTimeTimer()
    }
    
    /// Resume playback from the paused position.
    func resume() {
        // Continue playing from where pause() left off
        playerNode.play()
        // Restart the position polling timer
        startTimeTimer()
    }
    
    /// Stop playback entirely and tear down the engine.
    /// After calling this, the engine is no longer usable until playFile().
    func stop() {
        // Mark the stop as intentional so the completion handler is ignored
        isStopping = true
        // Stop everything and release the graph
        stopInternal()
    }
    
    /// Jump to a specific position in the song.
    ///
    /// - Parameter seconds: The absolute position to jump to (0 = start).
    func seek(toSeconds seconds: Double) {
        // Guard: we can't seek without an open file
        guard let file = audioFile, fileDuration > 0 else { return }
        
        // Clamp the target into the valid range [0, duration]
        let clamped = min(max(seconds, 0), fileDuration)
        
        // Stop the node, this also clears any scheduled buffers
        playerNode.stop()
        
        // Convert the seconds target to a sample frame index
        let startingFrame = AVAudioFramePosition(clamped * sampleRate)
        // Remember where this segment starts so currentTime (below) can
        // add elapsed time on top of it instead of reporting time-since-
        // this-seek.
        segmentStartSeconds = clamped
        // Re-schedule the file from that frame to the end
        scheduleSegment(startingFrame: startingFrame)
        
        // Resume playing from the new position
        if !playerNode.isPlaying {
            playerNode.play()
        }
        
        // Immediately report the new position to the caller
        onTimeUpdate?(clamped)
    }
    
    /// Change the playback speed (0.5 - 2.0).
    func setRate(_ newRate: Double) {
        // Store it so it survives future plays
        rate = newRate
        // Apply it live to the time-pitch unit
        timePitch.rate = Float(newRate)
    }
    
    /// Change the output volume (0.0 - 1.0).
    func setVolume(_ newVolume: Double) {
        // Store it for later use
        volume = newVolume
        // Apply it to the main mixer (the final output stage)
        engine.mainMixerNode.outputVolume = Float(newVolume)
    }
    
    /// Update the EQ band gains live (while a song is playing).
    ///
    /// - Parameter newGains: 31 gain values in decibels (-12 to +12).
    func setGains(_ newGains: [Double]) {
        // Store the new values
        gains = newGains
        // Apply them to the EQ node's bands immediately
        for (index, band) in eqNode.bands.enumerated() {
            // Guard against a mismatched array length
            if index < newGains.count {
                // Set the gain in decibels on this band
                band.gain = Float(newGains[index])
            }
        }
    }
    
    /// Update the preamp (the EQ node's global gain) live.
    ///
    /// - Parameter decibels: Overall gain in decibels (-12 to +12).
    func setPreamp(_ decibels: Double) {
        eqNode.globalGain = Float(decibels)
    }

    /// Set the stereo balance (-1.0 = full left, 0 = center, 1.0 = right).
    /// The Winamp player's BAL slider drives this.
    func setPan(_ pan: Double) {
        playerNode.pan = Float(min(max(pan, -1.0), 1.0))
    }

    /// How many bands the EQ node actually has. The UI drives its slider
    /// count from EqualizerManager.bandFrequencies (also 31); this is here
    /// so a mismatch would be visible in one place instead of silently
    /// dropping bands.
    var bandCount: Int { eqNode.bands.count }

    // MARK: - Spectrum Analyzer

    /// Install a tap on the main mixer's output that runs a real FFT over
    /// the playing audio and reports 24 log-spaced band levels through
    /// `onLevels`. Installed once: the mixer outlives individual songs.
    private func installSpectrumTapIfNeeded() {
        guard !spectrumTapInstalled else { return }
        spectrumTapInstalled = true

        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processSpectrumBuffer(buffer)
        }
    }

    /// FFT one audio buffer into 24 smoothed levels (0.0 to 1.0).
    /// Runs on the audio render thread: no allocation-heavy work beyond
    /// fixed-size scratch arrays, and the callback out is throttled.
    private func processSpectrumBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= 512 else { return }
        // Degenerate formats would poison the math below (division by a
        // zero channel count or a zero-width FFT bin); real files never
        // produce them, but the guard is one line.
        guard buffer.format.channelCount > 0, buffer.format.sampleRate > 0 else { return }

        let log2n: vDSP_Length = 10 // 1024-point FFT
        let n = 1 << log2n
        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        }
        guard let setup = fftSetup else { return }

        // Mono-mix the first 1024 frames into a real input array.
        var realInput = [Float](repeating: 0, count: n)
        let frames = min(frameCount, n)
        let channelCount = Int(buffer.format.channelCount)
        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<min(channelCount, 2) {
                sum += channelData[ch][i]
            }
            realInput[i] = sum / Float(min(channelCount, 2))
        }

        // Forward FFT via the split-complex API.
        var magnitudes = [Float](repeating: 0, count: n / 2)
        realInput.withUnsafeMutableBufferPointer { realPtr in
            var imag = [Float](repeating: 0, count: n)
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Bin the FFT magnitudes into 24 log-spaced bands from ~40 Hz to
        // ~16 kHz, convert to a 0..1 perceptual level, and smooth.
        let sampleRate = buffer.format.sampleRate
        let binWidth = sampleRate / Double(n)
        var levels = [Float](repeating: 0, count: 24)
        for band in 0..<24 {
            let lowFreq = 40.0 * pow(1.335, Double(band))
            let highFreq = 40.0 * pow(1.335, Double(band + 1))
            let lowBin = max(1, Int(lowFreq / binWidth))
            let highBin = min(n / 2 - 1, max(lowBin + 1, Int(highFreq / binWidth)))
            var peak: Float = 0
            for bin in lowBin..<highBin {
                peak = max(peak, magnitudes[bin])
            }
            // magnitudes are squared; sqrt back to amplitude, then map
            // -60 dB..0 dB onto 0..1.
            let amplitude = sqrt(peak)
            let db = 20 * log10(max(amplitude, 1e-6))
            levels[band] = Float(min(max((db + 60) / 60, 0), 1))
        }

        // Attack fast, release slow, like the classic Winamp bars.
        for band in 0..<24 {
            if levels[band] > smoothedLevels[band] {
                smoothedLevels[band] = levels[band]
            } else {
                smoothedLevels[band] = smoothedLevels[band] * 0.72 + levels[band] * 0.28
            }
        }

        spectrumBufferCount += 1
        if spectrumBufferCount % 3 == 0 {
            let snapshot = smoothedLevels
            DispatchQueue.main.async { [weak self] in
                self?.onLevels?(snapshot)
            }
        }
    }

    // MARK: - Private Setup Helpers
    
    /// Connect all nodes in the audio graph in the correct order:
    /// player → timePitch → eq → mainMixer → output.
    ///
    /// - Parameter format: The audio format of the file being played.
    ///                      All nodes use this format so data flows cleanly.
    private func buildGraph(format: AVAudioFormat) {
        // Player feeds into the time-pitch unit
        engine.connect(playerNode, to: timePitch, format: format)
        // Time-pitch feeds into the equalizer
        engine.connect(timePitch, to: eqNode, format: format)
        // Equalizer feeds into the main mixer (final output stage)
        engine.connect(eqNode, to: engine.mainMixerNode, format: format)
    }
    
    /// Configure the 10 EQ bands with their frequencies and gains.
    private func configureEQ() {
        // Loop over every band in the equalizer node
        for (index, band) in eqNode.bands.enumerated() {
            // Guard against a band without a matching frequency
            guard index < frequencies.count else { break }
            
            // Set the center frequency (e.g. 32, 1000, 16000 Hz)
            band.frequency = Float(frequencies[index])
            // Parametric filters are the standard "shelf/peak" EQ shape
            band.filterType = .parametric
            // Bandwidth of 0.35 octaves ≈ the 1/3-octave spacing of the
            // 31 ISO bands, so adjacent bands overlap just enough to sum
            // into a smooth graphic-EQ curve.
            band.bandwidth = 0.35
            // Apply this band's gain (0.0 = flat when gains are all zero)
            if index < gains.count {
                band.gain = Float(gains[index])
            }
        }
    }
    
    /// Schedule a segment of the audio file for playback.
    ///
    /// - Parameter startingFrame: The frame index to start from.
    ///                            The segment runs to the end of the file.
    private func scheduleSegment(startingFrame: AVAudioFramePosition) {
        // Guard: we need a file to schedule
        guard let file = audioFile else { return }
        
        // Bump the generation counter so any OLD scheduled segments become
        // stale and their completion callbacks are ignored (they were
        // cancelled by this reschedule)
        segmentID += 1
        // Capture the current generation for THIS segment
        let myID = segmentID
        
        // Figure out how many frames are left in the file from this point
        let framesRemaining = AVAudioFrameCount(file.length - startingFrame)
        
        // Schedule the remaining segment; when it finishes, notify the caller
        // NOTE: we use the `completionCallbackType:` variant so the callback
        // receives the reason (.dataPlayedBack = finished) in its argument.
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: framesRemaining,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] (callbackType: AVAudioPlayerNodeCompletionCallbackType) in
            // This closure runs on an internal audio thread
            Task { @MainActor [weak self] in
                // Ignore completions caused by an intentional stop
                guard let self = self, !self.isStopping else { return }
                // Ignore completions from stale (cancelled-by-seek) segments
                guard myID == self.segmentID else { return }
                // Only treat "finished playing" as a song end
                if callbackType == .dataPlayedBack || callbackType == .dataConsumed {
                    // Make sure we only fire the ended callback once
                    if !self.hasEnded {
                        self.hasEnded = true
                        // Tell the caller the song is done
                        self.onSongEnded?()
                    }
                }
            }
        })  // close the completionHandler closure AND the scheduleSegment call
    }
    
    /// Start a repeating timer that polls the playback position.
    /// Fires onTimeUpdate ~4 times per second (every 0.25s).
    private func startTimeTimer() {
        // Guard: don't create a second timer if one is already running
        guard timeTimer == nil else { return }
        
        // Create a repeating timer on the main run loop
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // The timer closure runs on the main thread
            Task { @MainActor [weak self] in
                // Report the current playback position to the caller
                self?.onTimeUpdate?(self?.currentTime ?? 0)
            }
        }
    }
    
    /// Stop the position-polling timer.
    private func stopTimeTimer() {
        // Invalidate the timer so it stops firing
        timeTimer?.invalidate()
        // Clear the reference so startTimeTimer can create a new one
        timeTimer = nil
    }
    
    /// Tear down playback: stop the timer, stop the nodes, stop the engine.
    private func stopInternal() {
        // Stop polling the playback position
        stopTimeTimer()
        // Stop the player node (halts audio output)
        playerNode.stop()
        // Stop the engine and disconnect everything
        engine.stop()
        // Release the file reference so it can be closed by the system
        audioFile = nil
        // Flatline the visualizer so it doesn't freeze on the last frame
        smoothedLevels = Array(repeating: 0, count: 24)
        onLevels?(smoothedLevels)
    }
    
    // MARK: - Current Position
    
    /// The current playback position in seconds.
    ///
    /// HOW IT'S CALCULATED:
    /// AVAudioPlayerNode tracks how many sample frames it has rendered
    /// SINCE THE NODE WAS LAST STARTED (playerTime resets to 0 on every
    /// stop()/play() cycle, it does not track a position within the file).
    /// lastRenderTime = the node's internal clock at the last render.
    /// playerTime(forNodeTime:) converts that clock value into sample
    /// frames elapsed since that start. Dividing frames by the sample rate
    /// gives elapsed seconds, which segmentStartSeconds (the file position
    /// the current segment was scheduled from, 0 initially, wherever the
    /// last seek landed after that) turns into an absolute position.
    private var currentTime: Double {
        // Get the node's latest render time
        guard let nodeTime = playerNode.lastRenderTime,
              // Convert it to a player time (sample frames + sample rate)
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            // If either conversion fails, report the last known segment
            // start rather than 0, so a fresh seek's position isn't lost
            // just because a render time isn't available yet.
            return segmentStartSeconds
        }
        // Convert sample frames to seconds, then offset by where this
        // segment actually starts in the file.
        return segmentStartSeconds + Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
