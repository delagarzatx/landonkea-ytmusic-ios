import SwiftUI

// MARK: - Error Banner

/// A dismissible error banner that slides down from the top of the screen.
///
/// Shows a red banner with an error message and a "Retry" button.
/// Used throughout the app to display API errors, network failures, etc.
///
/// USAGE:
/// ```swift
/// .overlay {
///     if let error = apiClient.errorMessage {
///         ErrorBanner(message: error) {
///             // Retry action
///             Task { await apiClient.search(query: "test") }
///         }
///     }
/// }
/// ```
struct ErrorBanner: View {
    
    /// The error message to display
    let message: String
    
    /// Optional retry action, if provided, shows a "Retry" button
    var onRetry: (() -> Void)?
    
    /// Whether to show the banner (controls dismiss animation)
    @State private var isShowing = true
    
    var body: some View {
        if isShowing {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Error icon
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                    
                    // Error message text
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    
                    Spacer()
                    
                    // Retry button (only if retry action provided)
                    if let onRetry = onRetry {
                        Button(action: {
                            isShowing = false
                            onRetry()
                        }) {
                            Text("Retry")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }
                    
                    // Dismiss button
                    Button(action: {
                        withAnimation {
                            isShowing = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(6)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                
                // Progress bar that auto-dismisses after 5 seconds
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: geometry.size.width, height: 2)
                }
                .frame(height: 2)
            }
            .background(Color.red)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.top, 8)
            // Slide down from top when appearing
            .transition(.move(edge: .top))
            .onAppear {
                // Auto-dismiss after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation {
                        isShowing = false
                    }
                }
            }
        }
    }
}

// MARK: - Toast Notification

/// A temporary notification that slides up from the bottom of the screen.
///
/// Used for success messages like "Song added to queue" or "Download started".
///
/// USAGE:
/// ```swift
/// .overlay {
///     if let toast = toastMessage {
///         ToastView(message: toast)
///     }
/// }
/// ```
struct ToastView: View {
    
    /// The message to display
    let message: String
    
    /// Optional icon name (defaults to checkmark)
    var iconName: String = "checkmark.circle.fill"
    
    /// Whether to show the toast
    @State private var isShowing = true
    
    var body: some View {
        if isShowing {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray6).opacity(0.95))
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // Auto-dismiss after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        isShowing = false
                    }
                }
            }
        }
    }
}
