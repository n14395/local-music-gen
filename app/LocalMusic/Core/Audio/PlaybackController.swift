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

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
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
