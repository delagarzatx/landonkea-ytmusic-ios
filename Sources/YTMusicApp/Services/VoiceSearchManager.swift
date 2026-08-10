import SwiftUI
import Speech

// MARK: - Voice Search Manager

/// Handles voice-to-text conversion for search.
///
/// Uses Apple's Speech framework to convert microphone audio into text
/// that can be used as a search query. The framework works offline (on-device)
/// or online (Apple's servers) depending on the language availability.
///
/// WHY A SEPARATE CLASS:
/// - Speech recognition requires permissions and setup
/// - It runs asynchronously (results come in as the user speaks)
/// - We need to manage the audio session lifecycle
class VoiceSearchManager: ObservableObject {
    
    /// The text recognized from speech. Updated in real-time as user speaks.
    @Published var recognizedText: String = ""
    
    /// Whether speech recognition is currently active
    @Published var isListening: Bool = false
    
    /// Error message if speech recognition fails
    @Published var errorMessage: String?
    
    /// The speech recognizer instance
    private let speechRecognizer = SFSpeechRecognizer()
    
    /// The current recognition request
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    /// The current recognition task
    private var recognitionTask: SFSpeechRecognitionTask?
    
    /// The audio engine captures microphone input
    private let audioEngine = AVAudioEngine()
    
    /// Whether speech recognition is available on this device
    var isAvailable: Bool {
        return speechRecognizer?.isAvailable ?? false
    }
    
    // MARK: - Lifecycle
    
    init() {
        // Request speech recognition authorization on startup
        requestAuthorization()
    }
    
    /// Request permission to use speech recognition.
    ///
    /// This is required by Apple's privacy policy. The user must explicitly
    /// allow the app to use the microphone and send speech data to Apple
    /// (if using server-based recognition).
    private func requestAuthorization() {
        // [weak self]: Apple's Speech framework holds this closure only until
        // the user responds to the permission prompt, then releases it, so this
        // wouldn't be a permanent retain cycle either way. But `self` here is a
        // VoiceSearchManager that could in theory be torn down before the user
        // answers the prompt (e.g. if it were ever recreated), so capturing weakly
        // is still the safer default: it avoids updating a deallocated object.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            // Must update UI on main thread
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied:
                    self?.errorMessage = "Speech recognition denied. Enable it in Settings."
                case .restricted:
                    self?.errorMessage = "Speech recognition restricted on this device."
                case .notDetermined:
                    print("Speech recognition not yet determined")
                @unknown default:
                    break
                }
            }
        }
    }
    
    // MARK: - Start Listening
    
    /// Start listening to microphone input and converting speech to text.
    ///
    /// Steps:
    /// 1. Stop any existing recognition task
    /// 2. Configure the audio session for recording
    /// 3. Create a recognition request
    /// 4. Attach the microphone input to the request
    /// 5. Start the recognition task
    ///
    /// Results come in via the recognitionTask callback as the user speaks.
    /// This method is kept small by delegating each step to a single-purpose
    /// helper below, that way each helper can be read (and tested/reasoned
    /// about) on its own.
    func startListening() {
        // Cancel any existing task first, so we never have two recognition
        // sessions running against the same audio engine at once.
        stopListening()

        // Check if recognition is available
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition not available"
            return
        }

        do {
            try activateAudioSession()
        } catch {
            errorMessage = "Failed to set up audio session: \(error.localizedDescription)"
            return
        }

        let request = makeRecognitionRequest()
        installMicrophoneTap()

        do {
            try startAudioEngine()
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            // The engine never started, so there's nothing actively producing audio,
            // but we already installed a tap and created a recognition request above.
            // Leaving those in place would be a resource leak (a dangling tap callback,
            // an in-flight request nobody will ever finish) and would leave this object
            // in a half-configured state if startListening() is called again later.
            // stopListening() tears all of that back down safely.
            stopListening()
            return
        }

        beginRecognitionTask(recognizer: recognizer, request: request)
        isListening = true
    }

    /// Configure and activate the shared `AVAudioSession` for recording.
    ///
    /// `AVAudioSession` is the system-wide object that arbitrates how apps use
    /// the device's audio hardware (who gets the microphone, whether other
    /// apps' audio should duck/pause, etc). Every app that records or plays
    /// audio must configure it before doing so.
    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // .playAndRecord allows both recording and playback
        // .defaultToSpeaker routes audio through the speaker
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Build the recognition request and store it so the microphone tap
    /// (installed separately below) has somewhere to feed audio into.
    ///
    /// - Returns: the request, so the caller can hand it to
    ///   `recognizer.recognitionTask(with:)` without reaching back through
    ///   the optional `recognitionRequest` property.
    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        // "SFSpeechAudioBufferRecognitionRequest" specifically means: audio will
        // arrive as a series of small buffers we push in ourselves (as opposed to
        // recognizing a pre-recorded audio file all at once).
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true // Show results as user speaks, not just at the end
        // requiresOnDeviceRecognition = false means: use on-device speech recognition
        // when possible, but fall back to sending audio to Apple's servers if the
        // on-device model isn't available for the current language.
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request
        return request
    }

    /// Install a tap on the microphone input that forwards captured audio
    /// buffers into the current recognition request.
    ///
    /// A "tap" is a callback that gets a copy of every audio buffer flowing
    /// through a node, without interrupting the audio itself. Here we tap the
    /// microphone input, the "input node", so we can forward each buffer to
    /// the speech recognizer.
    private func installMicrophoneTap() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024, // Small buffer = low latency (recognizer sees audio sooner)
            format: recordingFormat
        ) { [weak self] buffer, _ in
            // [weak self] avoids a retain cycle: this closure is held by
            // audioEngine.inputNode until removeTap() is called, and
            // audioEngine is itself owned by self, a strong capture here
            // would mean self can never deallocate unless stopListening()
            // always runs first (e.g. the owning view could be dismissed
            // mid-listen without calling it).
            // Append each audio buffer to the recognition request so the
            // recognizer can process it. This runs on an audio callback thread,
            // not the main thread, that's normal for AVAudioEngine taps.
            self?.recognitionRequest?.append(buffer)
        }
    }

    /// Prepare and start the audio engine so audio actually starts flowing
    /// through the tap installed above.
    private func startAudioEngine() throws {
        // "Preparing" the engine allocates its audio resources ahead of time,
        // which makes the following start() call faster and less likely to glitch.
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Ask the recognizer to start transcribing, and store the resulting task
    /// so it can be cancelled later (in `stopListening()`).
    private func beginRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        // [weak self]: this closure is retained by `self.recognitionTask`
        // itself (a strong reference cycle: self → recognitionTask → this
        // closure → self) until the task completes or is cancelled, a
        // strong `self` here would leak the manager if it's ever
        // deallocated while a recognition task is still in flight.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Process recognition results as they come in
            if let result = result {
                // Update the recognized text on the main thread
                DispatchQueue.main.async {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
            }

            // If there's an error or recognition is complete, stop
            if error != nil || (result?.isFinal ?? false) {
                self?.stopListening()
            }
        }
    }
    
    // MARK: - Stop Listening
    
    /// Stop listening and finalize the recognition.
    ///
    /// Stops the audio engine, removes the tap, and cancels the recognition task.
    /// The final recognized text is preserved in recognizedText.
    func stopListening() {
        // This method is safe to call even when nothing is currently running
        // (e.g. from startListening()'s very first line, or twice in a row):
        // stopping an already-stopped engine and removing a tap that was
        // never installed are both harmless no-ops in AVFoundation, and the
        // optionals below (recognitionRequest?, recognitionTask?) simply do
        // nothing if they're already nil.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // End the recognition request (finalizes the result)
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Cancel the recognition task
        recognitionTask?.cancel()
        recognitionTask = nil

        isListening = false
    }
    
    // MARK: - Reset
    
    /// Clear the recognized text and reset the state.
    func reset() {
        recognizedText = ""
        errorMessage = nil
    }
}
