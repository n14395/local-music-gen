import XCTest
@testable import LocalMusicGen

/// The event stream against a real socket.
///
/// `SSEParserTests` pins the framing; this pins the transport under it, which
/// is the half that changed shape. The reader is a `URLSessionDataDelegate`
/// now rather than `URLSession.bytes`, and a delegate method that is never
/// called fails silently — the app would simply never hear from the engine.
/// So this stands a server up and requires the three things the app depends
/// on: that `.connected` arrives on the response rather than on the first
/// event, that events are delivered, and that the bearer token is sent.
final class EventStreamClientTests: XCTestCase {
    /// A one-connection SSE server. Writes the port it bound to on stdout, so
    /// the test never has to guess a free one.
    private static let server = """
        import http.server, sys, threading, time

        BODY = [
            b': hello\\r\\n\\r\\n',
            b'event: job.progress\\r\\ndata: {"job_id":"j1","stage":"generating",'
            b'"fraction":0.5}\\r\\n\\r\\n',
            b'id: 7\\r\\nevent: job.completed\\r\\ndata: {"job_id":"j1"}\\r\\n\\r\\n',
        ]

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/v1/events':
                    self.send_response(404); self.end_headers(); return
                if self.headers.get('Authorization') != 'Bearer tok':
                    self.send_response(401); self.end_headers(); return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                # Deliberately one write per frame with a pause between, so
                # the frames arrive in separate chunks the way they do live.
                for part in BODY:
                    self.wfile.write(part); self.wfile.flush()
                    time.sleep(0.05)
                time.sleep(5)

            def log_message(self, *args):
                pass

        httpd = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        print(httpd.server_address[1], flush=True)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        time.sleep(20)
        """

    private var process: Process?

    override func tearDown() {
        process?.terminate()
        process = nil
        super.tearDown()
    }

    /// Starts the server and returns the port it bound to.
    private func startServer() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", Self.server]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        self.process = process

        let handle = pipe.fileHandleForReading
        var line = Data()
        // The port, then nothing else — the server prints one number.
        while !line.contains(UInt8(ascii: "\n")) {
            let next = handle.availableData
            if next.isEmpty { break }
            line.append(next)
        }
        let text = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int(text), "server did not report a port")
    }

    func testItConnectsAndDeliversEvents() async throws {
        let port = try startServer()
        let client = EventStreamClient(port: port, token: "tok")

        var sawConnected = false
        var events: [EngineEvent] = []
        let deadline = Date().addingTimeInterval(10)

        for await item in client.items() {
            switch item {
            case .connected:
                sawConnected = true
                // The whole point of the ordering: nothing has been sent yet.
                XCTAssertTrue(events.isEmpty,
                              "`.connected` must arrive before any event — "
                              + "it is what makes the app re-fetch the catalog")
            case .event(let event):
                events.append(event)
            case .disconnected:
                break
            }
            if events.count >= 2 || Date() > deadline { break }
        }

        XCTAssertTrue(sawConnected, "never connected")
        XCTAssertEqual(events.count, 2, "expected both frames, got \(events)")
        guard case .jobProgress(let jobId, let progress) = events.first else {
            return XCTFail("first event was \(String(describing: events.first))")
        }
        XCTAssertEqual(jobId, "j1")
        XCTAssertEqual(progress.stage, "generating")
        guard case .jobCompleted(let completed) = events.last else {
            return XCTFail("last event was \(String(describing: events.last))")
        }
        XCTAssertEqual(completed, "j1")
    }

    /// A refused connection must not be reported as a connection — this is the
    /// status check that lives in the response delegate, and the one thing the
    /// "a body proves acceptance" fallback cannot stand in for.
    func testAnUnauthorizedStreamNeverReportsConnected() async throws {
        let port = try startServer()
        let client = EventStreamClient(port: port, token: "wrong")

        var items: [EventStreamClient.StreamItem] = []
        let deadline = Date().addingTimeInterval(5)
        for await item in client.items() {
            items.append(item)
            // One disconnect is the whole answer; the backoff would take the
            // rest of the day.
            if case .disconnected = item { break }
            if Date() > deadline { break }
        }

        XCTAssertFalse(items.contains { if case .connected = $0 { true } else { false } },
                       "a 401 was reported as a live stream")
        XCTAssertTrue(items.contains { if case .disconnected = $0 { true } else { false } },
                      "a refused stream should report a disconnect and retry")
    }
}
