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

    /// The Models list's "only installed" filter. Session state on the store
    /// because two surfaces drive it — the screen's own toggle and the
    /// sidebar storage card's "Free up space…" — and because persisting it
    /// (as it once was) meant that button silently rewrote a preference that
    /// then greeted the next launch filtered, with nothing saying why.
    var onlyInstalledFilter = false

    /// True once the catalog has come back from the engine at least once.
    /// Until then an empty `models` means "we don't know yet", not "nothing is
    /// installed" — the difference the UI needs to show a spinner instead of a
    /// wrong "No models installed".
    private(set) var hasLoaded = false

    /// Model ids whose license the user accepted; persisted across launches.
    private(set) var acceptedLicenses: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(acceptedLicenses),
                                      forKey: "catalog.acceptedLicenses")
        }
    }

    /// Hearted models, persisted across launches.
    ///
    /// A local preference rather than a database row, because a model is not
    /// the app's data — the catalog belongs to the engine, and an id can leave
    /// it when a model is dropped. A stale id here costs nothing: nothing draws
    /// a favourite that is not in `models`.
    ///
    /// Deliberately unrelated to the Library's Favourites, which is for music
    /// and parts. This one orders the model picker and nothing else.
    private(set) var favouriteModelIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(favouriteModelIds),
                                      forKey: "catalog.favourites")
        }
    }

    func isFavourite(_ id: String) -> Bool { favouriteModelIds.contains(id) }

    func toggleFavourite(_ id: String) {
        if favouriteModelIds.contains(id) {
            favouriteModelIds.remove(id)
        } else {
            favouriteModelIds.insert(id)
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
        // Keys carry the `catalog.` prefix since the Settings rework;
        // `AppSettings.migrateLegacyKeys` moved old values across before any
        // store is constructed.
        acceptedLicenses = Set(UserDefaults.standard
            .stringArray(forKey: "catalog.acceptedLicenses") ?? [])
        favouriteModelIds = Set(UserDefaults.standard
            .stringArray(forKey: "catalog.favourites") ?? [])
        hasHFToken = Keychain.get(account: "hf-token") != nil
    }

    /// Re-read the persisted sets after something outside this store rewrote
    /// them — "Reset all preferences" in Settings is the one caller.
    func reloadPersisted() {
        acceptedLicenses = Set(UserDefaults.standard
            .stringArray(forKey: "catalog.acceptedLicenses") ?? [])
        favouriteModelIds = Set(UserDefaults.standard
            .stringArray(forKey: "catalog.favourites") ?? [])
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

    /// Forget an acceptance — the next download of that model shows its
    /// license sheet again. Settings' review list is the only caller; the
    /// set was append-only before it existed.
    func revokeLicense(modelId: String) {
        acceptedLicenses.remove(modelId)
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

    /// Announced after the engine accepts a pin change — the pinned id, or
    /// nil for an unpin. AppEnvironment records it so the pin can be replayed
    /// onto the next engine start.
    var onPinChanged: @MainActor (String?) -> Void = { _ in }

    func setPin(_ model: ModelInfo, enabled: Bool) async {
        guard let client else { return }
        do {
            try await client.setPin(modelId: model.id, enabled: enabled)
            lastError = nil
            onPinChanged(enabled ? model.id : nil)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    // MARK: helpers

    static let physicalRAM = Int64(ProcessInfo.processInfo.physicalMemory)
}
