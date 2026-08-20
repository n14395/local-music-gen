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

    init(port: Int, token: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
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
