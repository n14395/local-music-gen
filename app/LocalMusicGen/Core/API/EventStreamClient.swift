// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
                        let connection = SSEChunks(request: req)
                        var parser = SSEParser()
                        var opened = false
                        func markOpened() {
                            guard !opened else { return }
                            opened = true
                            attempt = 0
                            continuation.yield(.connected)
                        }

                        for try await chunk in connection.stream {
                            if Task.isCancelled { break }
                            // `.connected` is what makes consumers re-fetch
                            // the catalog, the downloads and the jobs, so it
                            // has to fire when the request is *accepted* —
                            // waiting for a first event would leave a freshly
                            // launched app with an empty catalog until
                            // something happened to it. A body is proof of
                            // acceptance too, so the second call here is belt
                            // and braces against a response callback that
                            // never arrives.
                            guard case .data(let block) = chunk else {
                                markOpened()
                                continue
                            }
                            markOpened()
                            for frame in parser.consume(block) {
                                if let event = EngineEvent.parse(
                                    name: frame.name, data: frame.data,
                                    decoder: BackendClient.decoder) {
                                    continuation.yield(.event(event))
                                }
                            }
                            lastEventID = parser.lastEventID ?? lastEventID
                        }
                        // The stream ended without an error — the engine hung
                        // up. Reconnect, as for any other drop.
                        if !opened { throw APIError.notConnected }
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

/// One SSE connection, delivered as the chunks of `Data` the network actually
/// handed over.
///
/// `URLSession.bytes(for:)` is less code and was what this used, but it yields
/// the body one `UInt8` at a time and **every one of those is an async
/// suspension**. A model that prints per step sends tens of kilobytes of
/// stderr through here during a render, which was tens of thousands of
/// resumptions a second spent reassembling lines the network had already
/// delivered in blocks. A delegate hands over each block whole.
///
/// `@unchecked Sendable`: `session` and `task` are written once during `init`,
/// before the task is resumed and before the stream can be iterated, and only
/// read afterwards.
private final class SSEChunks: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The response being accepted is itself news — see `.connected` in the
    /// caller — so it travels in the same stream as the body rather than
    /// through a second channel that would have to be ordered against it.
    enum Chunk: Sendable {
        case opened
        case data(Data)
    }

    let stream: AsyncThrowingStream<Chunk, any Error>
    private let continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(request: URLRequest) {
        var handle: AsyncThrowingStream<Chunk, any Error>.Continuation!
        stream = AsyncThrowingStream { handle = $0 }
        continuation = handle
        super.init()

        // SSE streams stay open indefinitely: the default 60 s request timeout
        // would kill an idle stream between heartbeats.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        // A nil queue gets a serial one of URLSession's own, so the callbacks
        // below never overlap and the buffer above stays in order.
        let session = URLSession(configuration: config, delegate: self,
                                 delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        // Covers cancellation and normal completion alike — a session with a
        // delegate holds it until invalidated, so this is also what lets both
        // of them go.
        continuation.onTermination = { [weak self] _ in
            self?.task?.cancel()
            self?.session?.invalidateAndCancel()
        }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            continuation.finish(throwing: APIError.notConnected)
            return .cancel
        }
        continuation.yield(.opened)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}
