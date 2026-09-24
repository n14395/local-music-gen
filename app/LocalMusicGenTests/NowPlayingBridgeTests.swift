// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import MediaPlayer
import XCTest
@testable import LocalMusicGen

@MainActor
final class NowPlayingBridgeTests: XCTestCase {
    private typealias Bridge = NowPlayingBridge

    // MARK: which player the keys speak for

    func testSoundBeatsEverything() {
        XCTAssertEqual(Bridge.subject(previous: .song, songPlaying: false,
                                      editorPlaying: true, songLoaded: true,
                                      editorLoaded: true), .editor)
        XCTAssertEqual(Bridge.subject(previous: .editor, songPlaying: true,
                                      editorPlaying: false, songLoaded: true,
                                      editorLoaded: true), .song)
    }

    /// The point of the sticky rule: pause the Editor, press play again, and
    /// the Editor resumes. Without it the keys would silently switch to
    /// whatever song was loaded before the edit started.
    func testPausedSubjectKeepsThePanel() {
        XCTAssertEqual(Bridge.subject(previous: .editor, songPlaying: false,
                                      editorPlaying: false, songLoaded: true,
                                      editorLoaded: true), .editor)
        XCTAssertEqual(Bridge.subject(previous: .song, songPlaying: false,
                                      editorPlaying: false, songLoaded: true,
                                      editorLoaded: true), .song)
    }

    func testSubjectFallsBackWhenItsPlayerUnloads() {
        // The Editor was the subject, then its track was closed.
        XCTAssertEqual(Bridge.subject(previous: .editor, songPlaying: false,
                                      editorPlaying: false, songLoaded: true,
                                      editorLoaded: false), .song)
        XCTAssertEqual(Bridge.subject(previous: .song, songPlaying: false,
                                      editorPlaying: false, songLoaded: false,
                                      editorLoaded: true), .editor)
    }

    func testNothingLoadedClaimsNothing() {
        XCTAssertNil(Bridge.subject(previous: .song, songPlaying: false,
                                    editorPlaying: false, songLoaded: false,
                                    editorLoaded: false))
    }

    // MARK: when to rewrite the info centre

    /// Normal playback must NOT republish: the info centre advances the
    /// position itself from the rate, and rewriting it four times a second all
    /// through a track is churn for a number it already knows.
    func testSteadyPlaybackDoesNotDrift() {
        XCTAssertFalse(Bridge.positionDrifted(elapsed: 30.0, from: 20.0,
                                              rate: 1.0, secondsSince: 10.0))
        XCTAssertFalse(Bridge.positionDrifted(elapsed: 30.4, from: 20.0,
                                              rate: 1.0, secondsSince: 10.0))
    }

    func testPausedPositionDoesNotDrift() {
        XCTAssertFalse(Bridge.positionDrifted(elapsed: 20.0, from: 20.0,
                                              rate: 0, secondsSince: 45.0))
    }

    /// A seek is exactly the case that must republish, in both directions.
    func testSeekDrifts() {
        XCTAssertTrue(Bridge.positionDrifted(elapsed: 95.0, from: 20.0,
                                             rate: 1.0, secondsSince: 10.0))
        XCTAssertTrue(Bridge.positionDrifted(elapsed: 2.0, from: 20.0,
                                             rate: 1.0, secondsSince: 10.0))
        // Scrubbed while paused.
        XCTAssertTrue(Bridge.positionDrifted(elapsed: 60.0, from: 20.0,
                                             rate: 0, secondsSince: 1.0))
    }

    // MARK: registration

    /// The app has no play queue, so the system must not offer skip buttons
    /// that would do nothing. Also covers `start()` surviving real command
    /// registration, which is where the isolation of the handlers would bite.
    func testStartDisablesTheCommandsWeCannotHonour() {
        let bridge = Bridge()
        bridge.start()
        let centre = MPRemoteCommandCenter.shared()
        XCTAssertFalse(centre.nextTrackCommand.isEnabled)
        XCTAssertFalse(centre.previousTrackCommand.isEnabled)
        XCTAssertFalse(centre.skipForwardCommand.isEnabled)
        XCTAssertFalse(centre.seekBackwardCommand.isEnabled)
        XCTAssertTrue(centre.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(centre.playCommand.isEnabled)
        XCTAssertTrue(centre.pauseCommand.isEnabled)
        XCTAssertTrue(centre.changePlaybackPositionCommand.isEnabled)
        bridge.relinquish()
    }

    /// With no source wired, the bridge must leave the Now Playing slot empty
    /// rather than claiming it with a blank tile.
    func testNothingPlayingClaimsNoSlot() {
        let bridge = Bridge()
        bridge.start()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
    }

    /// End to end through the real info centre: a wired source is published,
    /// and a media command reaches the player it names.
    func testWiredSourceIsPublishedAndCommandsReachIt() throws {
        let bridge = Bridge()
        let player = FakePlayer(title: "Night Drive", subtitle: "MUSICGEN · TAKE 2")
        bridge.songSource = { player.source }
        bridge.start()

        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Night Drive")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String,
                       "MUSICGEN · TAKE 2")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        bridge.perform(.pause)
        XCTAssertFalse(player.isPlaying, "pause must reach the sounding player")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        bridge.perform(.toggle)
        XCTAssertTrue(player.isPlaying)
        bridge.relinquish()
    }

    /// The Editor is the subject while it sounds, even with a song loaded —
    /// the key pauses what you can hear.
    func testEditorWinsWhileItSounds() {
        let bridge = Bridge()
        let song = FakePlayer(title: "Night Drive", subtitle: "")
        let editor = FakePlayer(title: "Night Drive (editing)", subtitle: "Editing")
        song.isPlaying = false
        bridge.songSource = { song.source }
        bridge.editorSource = { editor.source }
        bridge.start()

        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[
            MPMediaItemPropertyTitle] as? String, "Night Drive (editing)")
        bridge.perform(.pause)
        XCTAssertFalse(editor.isPlaying, "the Editor was the thing sounding")
        XCTAssertFalse(song.isPlaying, "the song player must not be touched")
        bridge.relinquish()
    }

    // MARK: helpers

    @MainActor
    private final class FakePlayer {
        var isPlaying = true
        var stopped = false
        var seekedTo: Double?
        let title: String
        let subtitle: String

        init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }

        var source: NowPlayingBridge.Source {
            NowPlayingBridge.Source(
                title: title, subtitle: subtitle, durationS: 180,
                elapsedS: 12, isPlaying: isPlaying,
                toggle: { [self] in isPlaying.toggle() },
                stop: { [self] in stopped = true; isPlaying = false },
                seek: { [self] in seekedTo = $0 })
        }
    }
}
