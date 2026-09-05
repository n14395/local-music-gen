import XCTest
@testable import LocalMusicGen

/// The capture library: a directory of `.nam` files with an index beside them.
///
/// The property that matters most is that the *files* are the library and the
/// index is only what is known about them — a capture copied in by hand still
/// shows up, and an index entry whose file has gone does not.
@MainActor
final class ToneLibraryTests: XCTestCase {
    private var root: URL!
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private let suiteName = "ToneLibraryTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tones-\(UUID().uuidString)")
        settings = AppSettings(defaults: defaults)
        settings.auxCachePath = root.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> ToneLibraryStore {
        ToneLibraryStore(settings: settings)
    }

    func testCapturesLandInTheAuxRoot() {
        let s = store()
        XCTAssertEqual(s.directory.path,
                       root.appendingPathComponent("tone3000-tones").path)
        let url = s.add(data: Data("{}".utf8), name: "Fender Deluxe — crunch",
                        toneId: 7, modelId: 42, author: "mrampguy",
                        gear: "amp", license: "CC-BY")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
        XCTAssertEqual(s.tones.count, 1)
        XCTAssertEqual(s.downloadedModelIds, [42])
        // Attribution survives the download, because the licence is the
        // author's and the row has to keep saying so.
        XCTAssertEqual(s.tones[0].attribution, "mrampguy · AMP · CC-BY")
    }

    /// The same TONE3000 capture fetched twice is one file, not two: the model
    /// id is in the name, so the second write lands on the first.
    func testTheSameCaptureTwiceIsOneFile() {
        let s = store()
        s.add(data: Data("{}".utf8), name: "Klon", toneId: 1, modelId: 9,
              author: nil, gear: nil, license: nil)
        s.add(data: Data("{\"v\":2}".utf8), name: "Klon", toneId: 1, modelId: 9,
              author: nil, gear: nil, license: nil)
        s.reload()
        XCTAssertEqual(s.tones.count, 1)
    }

    /// Two imported files that happen to share a name both survive — there is
    /// no id to collapse them onto, and silently overwriting someone's own
    /// capture with another of the same name would lose it.
    func testImportedNamesAreDisambiguated() {
        let s = store()
        s.add(data: Data("{}".utf8), name: "my rig", toneId: nil, modelId: nil,
              author: nil, gear: nil, license: nil)
        s.add(data: Data("{}".utf8), name: "my rig", toneId: nil, modelId: nil,
              author: nil, gear: nil, license: nil)
        XCTAssertEqual(s.tones.count, 2)
        XCTAssertEqual(Set(s.tones.map(\.fileName)).count, 2)
    }

    func testTheDirectoryWinsOverTheIndex() throws {
        let s = store()
        s.add(data: Data("{}".utf8), name: "Vox", toneId: nil, modelId: nil,
              author: nil, gear: nil, license: nil)
        // A file that arrived some other way — copied in the Finder — is
        // adopted under its own name.
        try Data("{}".utf8).write(to: s.directory
            .appendingPathComponent("hand-copied.nam"))
        // And one the index still claims is gone.
        try FileManager.default.removeItem(
            at: s.directory.appendingPathComponent(s.tones[0].fileName))

        let fresh = store()
        fresh.reload()
        XCTAssertEqual(fresh.tones.map(\.fileName), ["hand-copied.nam"])
        XCTAssertEqual(fresh.tones[0].title, "hand-copied")
    }

    func testRemovingTakesTheFileWithIt() {
        let s = store()
        s.add(data: Data("{}".utf8), name: "Twin", toneId: nil, modelId: nil,
              author: nil, gear: nil, license: nil)
        let path = s.url(for: s.tones[0]).path
        s.remove(s.tones[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(s.tones.isEmpty)
        let fresh = store()
        fresh.reload()
        XCTAssertTrue(fresh.tones.isEmpty)
    }

    /// A relocate moves the auxiliary root; the library is wherever the
    /// setting now points, with no state of its own to migrate.
    func testTheLibraryFollowsTheAuxRoot() {
        let s = store()
        s.add(data: Data("{}".utf8), name: "Bassman", toneId: nil,
              modelId: nil, author: nil, gear: nil, license: nil)
        let moved = root.appendingPathComponent("moved")
        try? FileManager.default.createDirectory(
            at: moved.appendingPathComponent("tone3000-tones"),
            withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: s.directory.appendingPathComponent(s.tones[0].fileName),
            to: moved.appendingPathComponent("tone3000-tones")
                .appendingPathComponent(s.tones[0].fileName))
        settings.auxCachePath = moved.path

        let fresh = store()
        fresh.reload()
        XCTAssertEqual(fresh.tones.count, 1)
        XCTAssertEqual(fresh.tones[0].title, "Bassman")
    }
}
