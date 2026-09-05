import AVFoundation
import Foundation
import Observation

/// The one shared AVPlayer behind the player bar; Compare panes use their own.
@MainActor @Observable
final class PlaybackController {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private(set) var currentSongId: String?
    private(set) var currentTitle = ""
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// The file being played, so the transport bar can draw its waveform. The
    /// bar is the only scrubber in the app that isn't already sitting next to
    /// the row it belongs to, so without this it is the one place you scrub
    /// blind.
    private(set) var currentURL: URL?
    /// The mono second line in the transport bar: `MUSICGEN SMALL · TAKE 1`,
    /// `ROUGH MIX · NOT RENDERED`. Callers pass whatever identifies the source.
    private(set) var currentSubtitle = ""

    /// Progress through the current track, 0…1 — what every waveform in the
    /// app tints against.
    var playedFraction: Double {
        guard duration > 0 else { return 0 }
        return (currentTime / duration).clamped(to: 0...1)
    }

    // MARK: - Level

    /// How loud the transport is, 0…1.
    ///
    /// Persisted, unlike everything else here: a level is a setting rather
    /// than a session accident — somebody who turned the app down at midnight
    /// does not want it loud again at breakfast. Mute is deliberately *not*
    /// persisted, because it is a thing you do for a minute.
    private(set) var volume: Double
    private(set) var isMuted = false

    /// What Volume Up and Volume Down move by. A tenth gives ten steps across
    /// the range, which is few enough to reach either end by holding the key
    /// and coarse enough that one press is audible.
    static let volumeStep = 0.1

    /// The level a step lands on, as pure arithmetic so the menu's two items
    /// can be tested without an audio device.
    ///
    /// Rounded to the step rather than merely clamped: repeatedly adding 0.1
    /// to a level that started at 0.35 would otherwise walk the whole scale
    /// half a step out of alignment and never land on 1.0 exactly.
    static func stepped(_ volume: Double, by delta: Double) -> Double {
        let raw = volume + delta
        guard delta != 0 else { return volume.clamped(to: 0...1) }
        let steps = (raw / abs(delta)).rounded()
        return (steps * abs(delta)).clamped(to: 0...1)
    }

    private let defaults: UserDefaults
    private static let volumeKey = "playback.volume"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key reads as 0, which would start the app silent — so a
        // never-written preference means full, not nothing.
        let stored = defaults.object(forKey: Self.volumeKey) as? Double
        self.volume = (stored ?? 1).clamped(to: 0...1)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        applyLevel()
    }

    func setVolume(_ next: Double) {
        let clamped = next.clamped(to: 0...1)
        guard clamped != volume || isMuted else { return }
        volume = clamped
        // Moving the level is how you un-mute by hand: a menu that turned the
        // volume up on a muted player and stayed silent would look broken.
        isMuted = false
        defaults.set(volume, forKey: Self.volumeKey)
        applyLevel()
    }

    func adjustVolume(by delta: Double) {
        setVolume(Self.stepped(volume, by: delta))
    }

    /// Silence without forgetting the level, so unmuting comes back where it
    /// was rather than at whatever the last drag happened to leave.
    func toggleMute() {
        isMuted.toggle()
        applyLevel()
    }

    private func applyLevel() {
        player.volume = Float(isMuted ? 0 : volume)
    }

    func play(url: URL, songId: String, title: String, duration: Double,
              subtitle: String = "") {
        if songId == currentSongId {
            toggle()
            return
        }
        currentURL = url
        currentSubtitle = subtitle
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentSongId = songId
        currentTitle = title
        self.duration = duration
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player.seek(to: .zero)
            }
        }
        // The level belongs to the player rather than to the item, so this is
        // belt and braces — but a track that arrived at the wrong volume would
        // be a bug nobody could explain from the transport bar.
        applyLevel()
        player.play()
        isPlaying = true
    }

    func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if currentSongId != nil {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop(songId: String? = nil) {
        if let songId, songId != currentSongId { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentSongId = nil
        currentTitle = ""
        currentSubtitle = ""
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
