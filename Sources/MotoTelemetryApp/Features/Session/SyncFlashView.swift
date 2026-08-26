import os
import SwiftUI

/// White fullscreen flash (~50ms) at ride start for cross-camera sync.
/// Logs the exact display timestamp for later correlation with video footage.
struct SyncFlashView: View {
    @Binding var isFlashing: Bool
    var onFlashTimestamp: ((Date) -> Void)?

    @State private var opacity: Double = 0

    private let log = Logger(subsystem: "com.mototelemetry.app", category: "SyncFlash")
    private let flashDuration: TimeInterval = 0.05 // 50ms

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: isFlashing) { _, shouldFlash in
                if shouldFlash {
                    triggerFlash()
                }
            }
            .accessibilityHidden(true)
    }

    private func triggerFlash() {
        let timestamp = Date.now
        opacity = 1.0
        log.info("Sync flash fired at \(timestamp.timeIntervalSince1970, format: .fixed(precision: 6))")
        onFlashTimestamp?(timestamp)

        DispatchQueue.main.asyncAfter(deadline: .now() + flashDuration) {
            withAnimation(.easeOut(duration: 0.05)) {
                opacity = 0
            }
            isFlashing = false
        }
    }
}
