import AVFoundation
import Foundation

/// Owns the `AVAudioSession`: the piece that actually makes audio keep playing
/// when the screen locks, and that tells us when the system takes the audio
/// away (a call, an alarm, Siri) or when headphones are unplugged.
@MainActor
final class AudioSessionManager {

    /// Something else took over the session; the caller should pause.
    var onInterruptionBegan: (() -> Void)?
    /// The interruption ended and the system says resuming is appropriate.
    var onInterruptionEndedShouldResume: (() -> Void)?
    /// Headphones or Bluetooth went away. Silence beats blasting the speaker.
    var onRouteDisconnected: (() -> Void)?

    private var isConfigured = false
    private var observers: [any NSObjectProtocol] = []

    // Block-based notification observers are not removed automatically, so the
    // deinit has to run somewhere it can touch main-actor state.
    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Category `.playback` is what pairs with the `audio` background mode:
    /// it keeps playing while locked and does not duck for other apps.
    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            // Non-fatal: playback may still work, just without long-form policy.
            try? session.setCategory(.playback, mode: .default)
        }
        observeNotifications()
    }

    /// Activated lazily on first play, so merely opening the app does not
    /// interrupt whatever the user is already listening to.
    func activate() {
        configure()
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // `Notification` cannot cross an isolation boundary, so the raw values
        // are pulled out here — they are plain integers — and only those are
        // handed to the main actor.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            // Only resume when the system explicitly says so — resuming after a
            // phone call is welcome, resuming over another app's audio is not.
            if options.contains(.shouldResume) {
                onInterruptionEndedShouldResume?()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        if reason == .oldDeviceUnavailable {
            onRouteDisconnected?()
        }
    }
}
