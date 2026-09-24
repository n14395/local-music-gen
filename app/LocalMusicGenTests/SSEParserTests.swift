// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Framing the engine's event stream.
///
/// The reader above this used to consume the stream one `UInt8` at a time —
/// one async suspension per byte of a render's stderr — and now takes whole
/// `Data` blocks off a `URLSession` delegate. That moves the choice of where a
/// frame is cut from "never" to "wherever the network felt like it", so these
/// feed the same bytes at every boundary that choice can produce and require
/// the same frames out.
final class SSEParserTests: XCTestCase {
    private let stream = """
        event: job.progress
        data: {"job_id":"j1","stage":"generating"}

        : heartbeat

        id: 42
        event: job.log
        data: [DiT] Step 1/8

        event: job.completed
        data: {"job_id":"j1"}


        """.replacingOccurrences(of: "\n", with: "\r\n")

    private func frames(chunkedInto size: Int) -> [SSEParser.Frame] {
        var parser = SSEParser()
        var out: [SSEParser.Frame] = []
        let bytes = Array(stream.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            out += parser.consume(Data(bytes[index..<end]))
            index = end
        }
        return out
    }

    private var expected: [SSEParser.Frame] {
        [.init(name: "job.progress",
               data: Data(#"{"job_id":"j1","stage":"generating"}"#.utf8)),
         .init(name: "job.log", data: Data("[DiT] Step 1/8".utf8)),
         .init(name: "job.completed", data: Data(#"{"job_id":"j1"}"#.utf8))]
    }

    /// One block, the easy case — and the shape every other case must match.
    func testAWholeStreamInOneChunk() {
        XCTAssertEqual(frames(chunkedInto: .max), expected)
    }

    /// Every boundary there is, including down the middle of each `\r\n`.
    /// This is what the old byte-at-a-time reader did, and the answer must not
    /// have changed with the reader.
    func testOneByteAtATime() {
        XCTAssertEqual(frames(chunkedInto: 1), expected)
    }

    /// Sweeping the chunk size walks the split across every field name, every
    /// blank frame terminator and every line ending in turn.
    func testEveryChunkSizeAgrees() {
        for size in 2...97 {
            XCTAssertEqual(frames(chunkedInto: size), expected,
                           "disagreed at a chunk size of \(size)")
        }
    }

    /// The resume token, which a reconnect sends back as `Last-Event-ID`.
    func testTheLastEventIDIsKept() {
        var parser = SSEParser()
        _ = parser.consume(Data(stream.utf8))
        XCTAssertEqual(parser.lastEventID, "42")
    }

    /// A frame arriving in halves must not be reported until it is whole —
    /// the failure this rewrite could plausibly have introduced.
    func testAPartialFrameIsHeldBack() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(Data("event: job.log\r\ndata: half".utf8))
            .isEmpty)
        XCTAssertEqual(parser.consume(Data(" a line\r\n\r\n".utf8)),
                       [.init(name: "job.log", data: Data("half a line".utf8))])
    }

    /// Bare `\n`, as a stricter-than-us server might send.
    func testUnixLineEndings() {
        var parser = SSEParser()
        XCTAssertEqual(parser.consume(Data("event: a\ndata: one\n\n".utf8)),
                       [.init(name: "a", data: Data("one".utf8))])
    }

    /// Multi-line `data:` is joined with newlines, per the SSE spec — which is
    /// how a stack trace reaches the render pane in one piece.
    func testMultiLineDataIsJoined() {
        var parser = SSEParser()
        XCTAssertEqual(
            parser.consume(Data("data: one\r\ndata: two\r\n\r\n".utf8)),
            [.init(name: "", data: Data("one\ntwo".utf8))])
    }
}
