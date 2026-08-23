import AppKit
import Foundation
import MediaPlayer
import Observation

/// Bridges the system transport — the ⏯ key on the keyboard, Control Centre's
/// Now Playing tile, the menu-bar widget — to whichever of the app's players is
/// actually making sound.
///
/// Two players share one pair of media keys: the song player (`AVPlayer`,
/// behind the transport bar) and the Editor's preview (`AVAudioEngine`). A
/// media key should pause what you can *hear*, so the subject is resolved on
/// every publish rather than bound to one player for good.
///
/// There is no play queue in this app — every play is a one-off from whichever
/// list you clicked — so next/previous are explicitly *disabled* rather than
/// left to look available and do nothing.
@MainActor
final class NowPlayingBridge {
    /// One player flattened to what the system transport needs. Closures
    /// rather than a reference: this lives in Core, and the Editor lives in
    /// Features, which Core must not import.
    struct Source {
        var title: String
        var subtitle: String
        var durationS: Double
        var elapsedS: Double
        var isPlaying: Bool
        var toggle: () -> Void
        var stop: () -> Void
        var seek: (Double) -> Void
    }

    enum Subject: String { case song, editor }

    /// Wired by AppEnvironment. Each returns nil when that player is not a
    /// candidate — nothing loaded, or (for the Editor) loaded but never played.
    var songSource: (() -> Source?)?
    var editorSource: (() -> Source?)?

    private var subject: Subject = .song
    private var started = false
    private var publishedKey: String?
    private var publishedPosition: (elapsed: Double, rate: Double, at: Date)?
    private var artwork: MPMediaItemArtwork?

    // MARK: pure decisions

    /// Which player the system transport should be about.
    ///
    /// Sound wins. When nothing is sounding the last one to sound keeps the
    /// panel, so pausing the Editor and pressing play again resumes the Editor
    /// rather than jumping to whatever song happened to be loaded before it.
    nonisolated static func subject(previous: Subject, songPlaying: Bool,
                                    editorPlaying: Bool, songLoaded: Bool,
                                    editorLoaded: Bool) -> Subject? {
        if editorPlaying { return .editor }
        if songPlaying { return .song }
        switch previous {
        case .editor where editorLoaded: return .editor
        case .song where songLoaded: return .song
        default: break
        }
        if editorLoaded { return .editor }
        if songLoaded { return .song }
        return nil
    }

    /// Whether the system's extrapolated playhead has fallen out of step with
    /// ours — which happens on a seek, and not otherwise.
    ///
    /// The info centre advances the position itself from the rate we publish,
    /// so without this check we would rewrite it four times a second, all the
    /// way through every track, for a number it already knows.
    nonisolated static func positionDrifted(elapsed: Double, from published: Double,
                                            rate: Double, secondsSince: Double,
                                            tolerance: Double = 1.0) -> Bool {
        abs(elapsed - (published + rate * secondsSince)) > tolerance
    }

    // MARK: lifecycle

    /// Settings' Now Playing toggle. Off, the bridge stops claiming the tile
    /// and ignores transport commands; the observation loop keeps running so
    /// turning it back on re-publishes at the next change — `relinquish()`
    /// alone would be undone by that same loop.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { relinquish() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        registerCommands()
        observe()
        refresh()
    }

    /// Hand the Now Playing slot back. Called on quit so the widget does not
    /// keep showing a track from a process that has gone.
    func relinquish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: commands

    /// Internal rather than private so tests can drive the same path the
    /// system does, without a second code path to keep honest.
    enum Command { case play, pause, toggle, stop }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Every handler below is explicitly `@Sendable`. A closure written
        // inside a `@MainActor` method inherits that isolation, and the system
        // calls these from a queue of its choosing — an inherited one traps in
        // `swift_task_checkIsolated` the first time a key is pressed. So each
        // returns immediately and hops to the main actor deliberately.
        for (command, kind) in [(center.playCommand, Command.play),
                                (center.pauseCommand, .pause),
                                (center.togglePlayPauseCommand, .toggle),
                                (center.stopCommand, .stop)] {
            command.removeTarget(nil)
            command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.perform(kind) }
                return .success
            }
            command.isEnabled = true
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            // Only the Double crosses the hop; the event itself is not Sendable
            // and has no business outliving this call.
            let position = event.positionTime
            Task { @MainActor in
                self?.current()?.seek(position)
                self?.refresh()
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true

        // No queue exists, so these would be buttons that do nothing. Saying so
        // greys them out instead of leaving them live and inert.
        for command in [center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }

    func perform(_ kind: Command) {
        guard isEnabled, let source = current() else { return }
        switch kind {
        case .play: if !source.isPlaying { source.toggle() }
        case .pause: if source.isPlaying { source.toggle() }
        case .toggle: source.toggle()
        case .stop: source.stop()
        }
        refresh()
    }

    // MARK: publishing

    /// The player the system transport is about, resolving (and remembering)
    /// the subject as a side effect.
    private func current() -> Source? {
        let song = songSource?()
        let editor = editorSource?()
        subject = Self.subject(previous: subject,
                               songPlaying: song?.isPlaying ?? false,
                               editorPlaying: editor?.isPlaying ?? false,
                               songLoaded: song != nil,
                               editorLoaded: editor != nil) ?? subject
        switch subject {
        case .song: return song ?? editor
        case .editor: return editor ?? song
        }
    }

    private func refresh() {
        let centre = MPNowPlayingInfoCenter.default()
        guard isEnabled, let source = current() else {
            // Nothing has played: leave the slot alone rather than claiming it
            // with an empty tile.
            centre.nowPlayingInfo = nil
            centre.playbackState = .stopped
            publishedKey = nil
            publishedPosition = nil
            return
        }

        let rate = source.isPlaying ? 1.0 : 0.0
        let key = [subject.rawValue, source.title, source.subtitle,
                   String(source.durationS), String(source.isPlaying)].joined(separator: "|")
        if key == publishedKey, let last = publishedPosition,
           !Self.positionDrifted(elapsed: source.elapsedS, from: last.elapsed,
                                 rate: last.rate,
                                 secondsSince: Date().timeIntervalSince(last.at)) {
            return
        }

        var fields: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPMediaItemPropertyTitle: source.title,
            MPMediaItemPropertyPlaybackDuration: source.durationS,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: source.elapsedS,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        // The subtitle is already the line that identifies a take — "MUSICGEN
        // SMALL · TAKE 1" — which is the closest thing here to an artist. Empty
        // means we have nothing to say, so we say nothing.
        if !source.subtitle.isEmpty {
            fields[MPMediaItemPropertyArtist] = source.subtitle
        }
        if let artwork = iconArtwork() {
            fields[MPMediaItemPropertyArtwork] = artwork
        }
        centre.nowPlayingInfo = fields
        // macOS only treats an app as the Now Playing app once it sets this;
        // without it the tile stays empty and the media keys never arrive.
        centre.playbackState = source.isPlaying ? .playing : .paused
        publishedKey = key
        publishedPosition = (source.elapsedS, rate, Date())
    }

    /// Re-publish whenever either player changes.
    ///
    /// `withObservationTracking` fires once per change and has to be re-armed,
    /// and its callback runs *before* the new value is stored — hence the hop
    /// to the next turn before reading anything.
    private func observe() {
        withObservationTracking {
            _ = songSource?()
            _ = editorSource?()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// The app icon, since nothing here has per-track artwork and a blank Now
    /// Playing tile reads as a broken one. Built once — `MPMediaItemArtwork`
    /// keeps its own cache, and rebuilding it per publish is pure churn.
    ///
    /// The request handler is `@Sendable` for the same reason the remote
    /// command handlers are: MediaPlayer calls it on its own access queue while
    /// rendering the tile, and a closure that inherited `@MainActor` from this
    /// method traps there rather than returning an image.
    private func iconArtwork() -> MPMediaItemArtwork? {
        if let artwork { return artwork }
        guard let icon = NSApplication.shared.applicationIconImage,
              icon.size.width > 0 else { return nil }
        nonisolated(unsafe) let image = icon
        let built = MPMediaItemArtwork(boundsSize: icon.size) { @Sendable _ in
            image
        }
        artwork = built
        return built
    }
}
