import Foundation
import Observation

@MainActor @Observable
final class ModelCatalogStore {
    private(set) var models: [ModelInfo] = []
    var lastError: String?
    var client: BackendClient?

    /// The engine's own state, read for one purpose: to tell "the catalog has
    /// not arrived yet" apart from "it never will".
    ///
    /// Held here rather than passed in at every call site because `readiness`
    /// has to be reachable from anywhere that asks whether a model is
    /// installed — which is a dozen screens — and a question that takes an
    /// argument is a question people route around.
    private let backend: BackendStatusStore?

    /// True once the catalog has come back from the engine at least once.
    /// Until then an empty `models` means "we don't know yet", not "nothing is
    /// installed" — the difference the UI needs to show a spinner instead of a
    /// wrong "No models installed".
    private(set) var hasLoaded = false

    /// Model ids whose license the user accepted; persisted across launches.
    private(set) var acceptedLicenses: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(acceptedLicenses),
                                      forKey: "acceptedLicenses")
        }
    }

    /// Whether a Hugging Face token is in the Keychain, which is what a gated
    /// model row reads to say `HF TOKEN ✓` rather than demanding one.
    ///
    /// It lives on the store rather than in the Models screen because Settings
    /// is a *separate window*: a token saved there has to reach rows that are
    /// already on screen, and view state would only catch up on the next visit.
    private(set) var hasHFToken = false

    init(backend: BackendStatusStore? = nil) {
        self.backend = backend
        acceptedLicenses = Set(UserDefaults.standard
            .stringArray(forKey: "acceptedLicenses") ?? [])
        hasHFToken = Keychain.get(account: "hf-token") != nil
    }

    /// Whether `models` can be believed yet, and why not when it cannot.
    ///
    /// Every screen that gates on an installed model goes through this rather
    /// than reading `models` and inferring — see `CatalogReadiness` for what
    /// happened when they didn't.
    var readiness: CatalogReadiness {
        CatalogReadiness.state(hasLoaded: hasLoaded, isConnected: client != nil,
                               lastError: lastError,
                               backend: backend?.phase ?? .stopped)
    }

    /// Re-read the Keychain. Called by Settings after it writes or clears the
    /// token, so the change is observed by every open view at once.
    func refreshHFToken() {
        hasHFToken = Keychain.get(account: "hf-token") != nil
    }

    func acceptLicense(for model: ModelInfo) {
        acceptedLicenses.insert(model.id)
    }

    func refresh() async {
        guard let client else { return }
        do {
            models = try await client.models()
            lastError = nil
            hasLoaded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startDownload(_ model: ModelInfo) async {
        guard let client else { return }
        do {
            _ = try await client.startDownload(modelId: model.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Install the family runtime for a model whose weights are already here.
    /// Runs through the download queue like anything else heavy, so the row
    /// picks it up from the same events a weights download uses.
    func installRuntime(_ model: ModelInfo) async {
        guard let client else { return }
        do {
            _ = try await client.startRuntimeInstall(modelId: model.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func delete(_ model: ModelInfo) async {
        guard let client else { return }
        do {
            try await client.deleteModel(model.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func setPin(_ model: ModelInfo, enabled: Bool) async {
        guard let client else { return }
        do {
            try await client.setPin(modelId: model.id, enabled: enabled)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    // MARK: helpers

    static let physicalRAM = Int64(ProcessInfo.processInfo.physicalMemory)
}
