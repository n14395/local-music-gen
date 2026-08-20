import Foundation

/// Consumes /v1/events (SSE) with automatic reconnection and Last-Event-ID resume.
///
/// Yields `.connected` after each (re)connect — consumers must then re-fetch
/// /v1/models, /v1/downloads, and /v1/jobs, because ring-buffer replay is best-effort.
struct EventStreamClient: Sendable {
    enum StreamItem: Sendable {
        case connected
        case event(EngineEvent)
        case disconnected
    }

    let port: Int
    let token: String

    func items() -> AsyncStream<StreamItem> {
        AsyncStream { continuation in
            let task = Task {
                // SSE streams stay open indefinitely: the default 60 s request timeout
                // would kill an idle stream between heartbeats.
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = .infinity
                config.timeoutIntervalForResource = .infinity
                let session = URLSession(configuration: config)
                var lastEventID: String?
                var attempt = 0

                while !Task.isCancelled {
                    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/events")!)
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID {
                        req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                    }
                    do {
                        let (bytes, response) = try await session.bytes(for: req)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw APIError.notConnected
                        }
                        attempt = 0
                        continuation.yield(.connected)

                        var eventName = ""
                        var dataLines: [String] = []
                        var lineBuffer: [UInt8] = []
                        // Manual line splitting: AsyncBytes.lines DROPS empty lines,
                        // and an empty line is what terminates an SSE frame.
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            if byte != UInt8(ascii: "\n") {
                                lineBuffer.append(byte)
                                continue
                            }
                            if lineBuffer.last == UInt8(ascii: "\r") {
                                lineBuffer.removeLast()
                            }
                            let line = String(decoding: lineBuffer, as: UTF8.self)
                            lineBuffer.removeAll(keepingCapacity: true)
                            if line.isEmpty {
                                // dispatch frame
                                if !dataLines.isEmpty {
                                    let data = dataLines.joined(separator: "\n")
                                        .data(using: .utf8) ?? Data()
                                    if let event = EngineEvent.parse(
                                        name: eventName, data: data,
                                        decoder: BackendClient.decoder) {
                                        continuation.yield(.event(event))
                                    }
                                }
                                eventName = ""
                                dataLines = []
                            } else if line.hasPrefix("id: ") {
                                lastEventID = String(line.dropFirst(4))
                            } else if line.hasPrefix("event: ") {
                                eventName = String(line.dropFirst(7))
                            } else if line.hasPrefix("data: ") {
                                dataLines.append(String(line.dropFirst(6)))
                            }
                            // comment lines (heartbeats) fall through
                        }
                    } catch {
                        // fall through to reconnect
                    }
                    if Task.isCancelled { break }
                    continuation.yield(.disconnected)
                    attempt += 1
                    let backoff = min(8.0, 0.5 * pow(2.0, Double(attempt)))
                    try? await Task.sleep(for: .seconds(backoff))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
