// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Splits a server-sent-events byte stream into frames, across whatever chunk
/// boundaries the network happened to choose.
///
/// A type of its own because the reader above it changed shape: the stream
/// used to be consumed one `UInt8` at a time — one async suspension per byte
/// of a render's stderr — and is now consumed in whole `Data` blocks. Whether
/// a frame arrives in one block, in six, or split down the middle of a `\r\n`
/// is now the network's business rather than the parser's, so the seam is
/// worth having somewhere it can be fed deliberately awkward input.
///
/// Deliberately not `AsyncBytes.lines`: that drops empty lines, and an empty
/// line is precisely what terminates an SSE frame.
struct SSEParser {
    struct Frame: Equatable {
        let name: String
        let data: Data
    }

    /// The last `id:` seen, which is what a reconnect resumes from.
    private(set) var lastEventID: String?

    /// Whatever came after the final newline of the last chunk, waiting for
    /// the rest of itself.
    private var buffer: [UInt8] = []
    private var eventName = ""
    private var dataLines: [String] = []

    /// Frames completed by this chunk, in order. A chunk that completes none
    /// returns empty; a chunk that completes six returns six.
    mutating func consume(_ chunk: Data) -> [Frame] {
        buffer.append(contentsOf: chunk)
        var frames: [Frame] = []
        var start = buffer.startIndex

        while let end = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[start..<end]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            start = buffer.index(after: end)

            if line.isEmpty {
                if !dataLines.isEmpty {
                    let joined = dataLines.joined(separator: "\n")
                    frames.append(Frame(name: eventName,
                                        data: Data(joined.utf8)))
                }
                eventName = ""
                dataLines = []
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("id: ") {
                lastEventID = String(text.dropFirst(4))
            } else if text.hasPrefix("event: ") {
                eventName = String(text.dropFirst(7))
            } else if text.hasPrefix("data: ") {
                dataLines.append(String(text.dropFirst(6)))
            }
            // comment lines (heartbeats) fall through
        }

        // Drop the consumed prefix once per chunk rather than once per line,
        // which is what keeps a busy read linear instead of quadratic.
        if start > buffer.startIndex {
            buffer.removeFirst(start - buffer.startIndex)
        }
        return frames
    }
}
