import UIKit

// MARK: - Haptic Feedback Utility

/// Provides haptic feedback (vibration) for button taps and interactions.
///
/// WHAT IS HAPTIC FEEDBACK?
/// Haptic feedback is the subtle vibration your iPhone makes when you tap
/// certain buttons. It provides tactile confirmation that an action occurred,
/// making the app feel more responsive and physical.
///
/// HOW IT WORKS:
/// - UIKit's UIImpactFeedbackGenerator creates vibrations using the Taptic Engine
/// - Different styles produce different vibration patterns
/// - We use .light for most taps and .medium for important actions
///
/// USAGE:
/// Just call `Haptics.tap()` anywhere you want a vibration.
/// It's safe to call from any thread, the generator handles threading internally.
struct Haptics {
    
    /// Trigger a light tap haptic (for most button presses).
    ///
    /// Use this for:
    /// - Play/pause button
    /// - Skip forward/backward
    /// - Shuffle/repeat toggles
    /// - Tapping search suggestions
    static func tap() {
        // UIImpactFeedbackGenerator creates a physical vibration
        // .light = subtle tap, like pressing a soft button
        let generator = UIImpactFeedbackGenerator(style: .light)
        // .impactOccurred() triggers the vibration immediately
        generator.impactOccurred()
    }
    
    /// Trigger a medium tap haptic (for important actions).
    ///
    /// Use this for:
    /// - Adding a song to queue
    /// - Starting a download
    /// - Significant state changes
    static func mediumTap() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    /// Trigger a notification haptic (for success/error feedback).
    ///
    /// Use this for:
    /// - Download completed
    /// - Error occurred
    /// - Timer started/stopped
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}
