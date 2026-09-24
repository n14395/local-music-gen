// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import Observation

/// The one shared AVPlayer behind the player bar; Compare panes use their own.
@MainActor @Observable
final class PlaybackController {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    /// KVO on the current item's `status` — see `observe(item:)`.
    private var statusObservation: NSKeyValueObservation?
    /// Bumped by every `play`, so a status that arrives after the item was
    /// replaced is known to be about the old one and dropped.
    private var itemGeneration = 0

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

    /// Why the current track will not play, or nil. Set from the item's own
    /// `status`, and also written over `currentSubtitle` so it is visible in
    /// the transport bar rather than being a string nothing reads: a file
    /// CoreAudio cannot decode (an `.ogg`, a truncated `.wav` — both import
    /// through `AudioImporter`'s passthrough branch) used to leave the bar
    /// claiming to play a silent track forever.
    private(set) var lastError: String?

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
        // A track that failed to decode gets a fresh item rather than a
        // toggle: pressing Play on it again is a retry, and toggling a player
        // that never started is how the bar came to claim it was playing.
        if songId == currentSongId, lastError == nil {
            toggle()
            return
        }
        currentURL = url
        currentSubtitle = subtitle
        lastError = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentSongId = songId
        currentTitle = title
        self.duration = duration
        itemGeneration += 1
        observe(item: item, generation: itemGeneration)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player.seek(to: .zero)
            }
        }
        // Playback that dies part-way — the decoder giving up on a malformed
        // file it opened happily. Same treatment as a status of `.failed`.
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                .localizedDescription
            MainActor.assumeIsolated {
                self?.failCurrent(reason: reason)
            }
        }
        // The level belongs to the player rather than to the item, so this is
        // belt and braces — but a track that arrived at the wrong volume would
        // be a bug nobody could explain from the transport bar.
        applyLevel()
        player.play()
        isPlaying = true
    }

    /// Watch one item's `status`.
    ///
    /// `AVPlayer.play()` used to be followed by `isPlaying = true` and nothing
    /// else, so a file AVFoundation cannot decode left the transport claiming
    /// to play a track that never made a sound — and with `duration` taken
    /// verbatim from the row, a passthrough import whose metadata read as
    /// zeroes also had a dead scrubber.
    ///
    /// KVO delivers on whatever thread changed the value, so the block reads
    /// the two `Sendable` facts it needs and hands them to the actor. The
    /// item itself is the block's parameter, never captured.
    private func observe(item: AVPlayerItem, generation: Int) {
        statusObservation?.invalidate()
        statusObservation = item.observe(
            \.status, options: [.initial, .new]
        ) { [weak self] item, _ in
            let status = item.status
            let reason = item.error?.localizedDescription
            let itemDuration = item.duration.seconds
            Task { @MainActor in
                self?.noteStatus(status, reason: reason,
                                 itemDuration: itemDuration,
                                 generation: generation)
            }
        }
    }

    private func noteStatus(_ status: AVPlayerItem.Status, reason: String?,
                            itemDuration: Double, generation: Int) {
        // The item may already have been replaced while this hopped actors.
        guard generation == itemGeneration else { return }
        switch status {
        case .failed:
            failCurrent(reason: reason)
        case .readyToPlay:
            // The row's duration is authoritative when it has one; a zero is
            // what `AudioImporter.metadata(of:)` records when CoreAudio could
            // not read the container, and the item knows better.
            if duration <= 0, itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
        default:
            break
        }
    }

    /// The current item cannot be played: stop claiming that it is, and say so
    /// where the transport bar draws it.
    private func failCurrent(reason: String?) {
        guard currentSongId != nil else { return }
        player.pause()
        isPlaying = false
        let message = reason ?? "the file could not be decoded"
        lastError = "Cannot play \(currentTitle): \(message)"
        currentSubtitle = "Cannot play — \(message)"
    }

    func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if currentSongId != nil {
            // Pressing Play again on a track that already failed to decode
            // would set `isPlaying` back to true over a silent player.
            guard lastError == nil else { return }
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
        statusObservation?.invalidate()
        statusObservation = nil
        lastError = nil
        currentSongId = nil
        currentTitle = ""
        currentSubtitle = ""
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
