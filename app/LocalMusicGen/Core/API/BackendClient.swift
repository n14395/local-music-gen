// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Typed async wrapper for the engine's REST API (docs/api-contract.md).
/// A plain Sendable struct — safe to hand to any actor.
struct BackendClient: Sendable {
    let baseURL: URL
    let token: String
    private let session: URLSession

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// One session for every client.
    ///
    /// Every instance configured it identically and differs only in its base
    /// URL, so there was never anything per-client about it — while the
    /// launch handshake builds a client *per attempt*, up to a couple of
    /// hundred times on a cold first run, and nothing ever called
    /// `finishTasksAndInvalidate` on any of them. That is a connection pool
    /// per attempt, none of them reclaimed, at exactly the moment the app is
    /// trying to start.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(port: Int, token: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        self.session = Self.sharedSession
    }

    // MARK: endpoints

    func health() async throws -> HealthResponse {
        try await get("/healthz", auth: false)
    }

    func system() async throws -> SystemInfo { try await get("/v1/system") }

    func models() async throws -> [ModelInfo] {
        (try await get("/v1/models") as ModelsResponse).models
    }

    func model(_ id: String) async throws -> ModelInfo {
        try await get("/v1/models/\(id)")
    }

    func deleteModel(_ id: String) async throws {
        try await send("DELETE", "/v1/models/\(id)")
    }

    func startDownload(modelId: String) async throws -> String {
        (try await post("/v1/models/\(modelId)/download") as DownloadStarted).downloadId
    }

    /// Install this model's family runtime without touching its weights — the
    /// repair for a model downloaded before its runtime step existed, or one
    /// whose adapter has been updated since (contract §4.2).
    func startRuntimeInstall(modelId: String) async throws -> String {
        (try await post("/v1/models/\(modelId)/runtime") as DownloadStarted).downloadId
    }

    func downloads() async throws -> [DownloadInfo] {
        (try await get("/v1/downloads") as DownloadsResponse).downloads
    }

    func pauseDownload(_ id: String) async throws {
        try await send("POST", "/v1/downloads/\(id)/pause")
    }

    func resumeDownload(_ id: String) async throws {
        try await send("POST", "/v1/downloads/\(id)/resume")
    }

    func cancelDownload(_ id: String) async throws {
        try await send("DELETE", "/v1/downloads/\(id)")
    }

    func submit(_ submission: JobSubmission) async throws -> JobsCreated {
        try await post("/v1/jobs", body: submission)
    }

    func jobs(status: String? = nil, groupId: String? = nil) async throws -> [JobInfo] {
        var comps = URLComponents(string: "/v1/jobs")!
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "status", value: status)) }
        if let groupId { items.append(URLQueryItem(name: "group_id", value: groupId)) }
        if !items.isEmpty { comps.queryItems = items }
        return (try await get(comps.string!) as JobsResponse).jobs
    }

    func job(_ id: String) async throws -> JobInfo { try await get("/v1/jobs/\(id)") }

    func cancelJob(_ id: String) async throws {
        try await send("POST", "/v1/jobs/\(id)/cancel")
    }

    /// Stop starting queued jobs (contract §5.7). The running one is not
    /// suspended — there is no verb for that, by design.
    func holdQueue(_ held: Bool) async throws {
        try await send("POST", "/v1/queue/\(held ? "pause" : "resume")")
    }

    /// Run these queued jobs in this order, ahead of every queued job not
    /// named (contract §5.8). One call, so a drag lands atomically.
    func reorderQueue(_ jobIds: [String]) async throws {
        try await send("POST", "/v1/queue/order", body: ["job_ids": jobIds])
    }

    func setJobPriority(_ id: String, priority: Int) async throws {
        try await send("PATCH", "/v1/jobs/\(id)/priority",
                       body: ["priority": priority])
    }

    func setHFToken(_ token: String) async throws {
        try await send("POST", "/v1/settings/hf-token", body: ["token": token])
    }

    func setPin(modelId: String, enabled: Bool) async throws {
        try await send("PUT", "/v1/models/\(modelId)/pin",
                       body: ["enabled": enabled])
    }

    func unloadWorker() async throws {
        try await send("POST", "/v1/worker/unload")
    }

    /// Raw-body upload for "audio" params; returns the upload id to reference
    /// from a job's params.
    func upload(data: Data, filename: String) async throws -> UploadInfo {
        var comps = URLComponents(string: "/v1/uploads")!
        comps.queryItems = [URLQueryItem(name: "filename", value: filename)]
        let raw = try await request("POST", comps.string!, body: data, auth: true)
        do { return try Self.decoder.decode(UploadInfo.self, from: raw) }
        catch { throw APIError.decoding(underlying: error) }
    }

    /// The engine's cap on an upload body — `MAX_UPLOAD_BYTES` in
    /// `supervisor/api/uploads.py`. Mirrored here so a source too big to
    /// accept can be refused before it is transferred: the engine reads an
    /// oversized body all the way to the end on purpose (so its 422 is
    /// deliverable), which for a long WAV is the whole file over the wire
    /// only to be told no.
    static let maxUploadBytes: Int64 = 256 * 1024 * 1024

    /// The same upload, streamed from disk.
    ///
    /// Identical on the wire; the difference is that the sibling above needs
    /// the whole file in memory before it can start, which for a few minutes
    /// of WAV is tens of megabytes read synchronously by whoever called it —
    /// and every submit path that takes audio went through it. Handing
    /// `URLSession` the path lets it stream the body, so a large source never
    /// lands in the app's heap at all.
    func uploadFile(at fileURL: URL, filename: String) async throws
        -> UploadInfo {
        var comps = URLComponents(string: "/v1/uploads")!
        comps.queryItems = [URLQueryItem(name: "filename", value: filename)]
        var req = URLRequest(
            url: URL(string: comps.string!, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let raw: Data
        do {
            let (data, response) = try await session.upload(for: req,
                                                            fromFile: fileURL)
            raw = try Self.validated(data: data, response: response)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: error)
        }
        do { return try Self.decoder.decode(UploadInfo.self, from: raw) }
        catch { throw APIError.decoding(underlying: error) }
    }

    // MARK: model library (contract §4.4)

    func library() async throws -> LibraryInfo {
        try await get("/v1/models/library")
    }

    func verifyLibrary() async throws -> LibraryVerifyReport {
        try await get("/v1/models/library/verify")
    }

    /// Remove models of ours from the current library folder — `all` of them,
    /// or just the `partial` ones left by interrupted downloads. Nothing else
    /// in that folder is touched: it may be the shared Hugging Face cache,
    /// full of repos this app never asked for.
    @discardableResult
    func clearLibrary(scope: String = "all") async throws -> String {
        (try await post("/v1/models/library/clear", body: ["scope": scope])
            as LibraryOperationStarted).operationId
    }

    /// Rearrange the files for a new library folder. `disposition` says what
    /// becomes of the models in the old one: `move`, `delete` or `leave`.
    ///
    /// The engine reads HF_HOME once, at launch, so this only moves bytes —
    /// the caller applies the new path and restarts the engine afterwards.
    @discardableResult
    func relocateLibrary(to path: String,
                         disposition: String) async throws -> String {
        (try await post("/v1/models/library/relocate",
                        body: ["path": path, "disposition": disposition])
            as LibraryOperationStarted).operationId
    }

    func cancelLibraryOperation() async throws {
        try await send("POST", "/v1/models/library/cancel")
    }

    func inspectModel(repoId: String) async throws -> ModelInfo {
        try await post("/v1/models/inspect", body: ["repo_id": repoId])
    }

    func addCustomModel(repoId: String) async throws -> ModelInfo {
        try await post("/v1/models/custom", body: ["repo_id": repoId])
    }

    func shutdown() async throws { try await send("POST", "/v1/shutdown") }

    // MARK: plumbing

    private func request(_ method: String, _ path: String, body: Data?,
                         auth: Bool) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = method
        if auth { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.transport(underlying: error)
        }
        return try Self.validated(data: data, response: response)
    }

    /// Status check shared by `request` and the streamed upload.
    private static func validated(data: Data,
                                  response: URLResponse) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? Self.decoder.decode(APIErrorEnvelope.self, from: data))?.error
                ?? APIErrorBody(code: "INTERNAL", message: "HTTP \(status)")
            throw APIError.http(status: status, body: body)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, auth: Bool = true) async throws -> T {
        let data = try await request("GET", path, body: nil, auth: auth)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(underlying: error) }
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request("POST", path, body: nil, auth: true)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(underlying: error) }
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try await request("POST", path, body: try Self.encoder.encode(body),
                                     auth: true)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(underlying: error) }
    }

    private func send(_ method: String, _ path: String) async throws {
        _ = try await request(method, path, body: nil, auth: true)
    }

    private func send<B: Encodable>(_ method: String, _ path: String, body: B) async throws {
        _ = try await request(method, path, body: try Self.encoder.encode(body), auth: true)
    }
}
