import Foundation
import Observation

/// Which models can act as the writing assistant.
///
/// Shape-driven like every other model choice in this app (see
/// `StyleTransferMode.Requirement` and `MixModels`): a model qualifies by
/// declaring the `assist` task, never by being on a list of ids. A new
/// assistant added to the catalog tomorrow works here with no app change.
enum AssistantModels {
    static func canAssist(_ model: ModelInfo) -> Bool {
        model.capabilities.supportedTasks.contains("assist")
    }

    /// Installed assistants, in catalog order. Order is load-bearing: the
    /// first one is what every card opens on, and the catalog orders the
    /// better model before the lighter one.
    static func installed(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.installState == .installed && canAssist($0) }
    }

    /// Everything that could serve, installed or not, smallest first — what
    /// the Models screen offers when nothing is installed yet.
    static func candidates(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter(canAssist).sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// The assistant a card should use: the one the user chose in Settings if
    /// it is still installed, else the first installed one.
    static func choose(_ models: [ModelInfo], preferring preferred: String?) -> ModelInfo? {
        let available = installed(models)
        if let preferred, let match = available.first(where: { $0.id == preferred }) {
            return match
        }
        return available.first
    }
}

/// Runs assistant jobs and hands back the answers.
///
/// One in-flight request per *slot* rather than one globally: several cards can
/// be open behind one another, and an interview answered on one page must not
/// be cancelled by a title being drafted somewhere else. The slot is whatever
/// string the caller wants — pages use their recipe id.
@MainActor
@Observable
final class AssistantStore {
    /// The live state of one slot's request.
    enum Phase: Equatable {
        case idle
        case working(AssistKind)
        case done(AssistResult)
        case failed(String)

        var isWorking: Bool { if case .working = self { true } else { false } }

        var result: AssistResult? {
            if case .done(let result) = self { return result }
            return nil
        }
    }

    private(set) var phases: [String: Phase] = [:]

    var client: BackendClient?
    /// Supplied by AppEnvironment so the store reads the live setting rather
    /// than a copy taken at construction.
    var preferredModelId: @MainActor () -> String? = { nil }
    var temperature: @MainActor () -> Double = { 0.7 }

    /// The catalog, for model choice. A closure for the same reason: the
    /// catalog refreshes and this must see the refreshed list.
    var models: @MainActor () -> [ModelInfo] = { [] }

    private var tasks: [String: Task<Void, Never>] = [:]

    func phase(_ slot: String) -> Phase { phases[slot] ?? .idle }

    func result(_ slot: String) -> AssistResult? { phase(slot).result }

    func clear(_ slot: String) {
        tasks[slot]?.cancel()
        tasks[slot] = nil
        phases[slot] = .idle
    }

    /// Whether anything can serve an assist request right now.
    var isAvailable: Bool {
        AssistantModels.choose(models(), preferring: preferredModelId()) != nil
    }

    /// Ask the assistant for something.
    ///
    /// `input` is the kind-specific payload; it is JSON-encoded into the
    /// `assist_input` param, which is where the whole vocabulary of this
    /// feature lives. `targetModel` is the music model the text is being
    /// written for — its family selects the dialect the assistant writes in,
    /// and its declared lyric tags override the adapter's built-in table.
    func ask(slot: String, kind: AssistKind, input: [String: JSONValue],
             targetModel: ModelInfo? = nil) {
        tasks[slot]?.cancel()
        guard let client else {
            phases[slot] = .failed("Not connected to the engine.")
            return
        }
        guard let assistant = AssistantModels.choose(
            models(), preferring: preferredModelId()) else {
            phases[slot] = .failed(
                "No writing assistant is installed yet.")
            return
        }

        var input = input
        // The target model's own declared tags beat the adapter's table, which
        // is generated from the catalog and therefore right when the table has
        // drifted.
        if kind.needsTargetModel, let tags = targetModel?.capabilities.lyricsTags,
           !tags.isEmpty {
            input["lyrics_tags"] = .array(tags.map { .string($0) })
        }

        var params: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "temperature": .double(temperature()),
        ]
        // The input rides as a JSON *string*: `json` params are flat scalars on
        // the wire (contract §4.1), which keeps params a plain dictionary all
        // the way down.
        guard let encoded = Self.encode(input) else {
            phases[slot] = .failed("Could not prepare the request.")
            return
        }
        params["assist_input"] = .string(encoded)
        if kind.needsTargetModel, let family = targetModel?.family {
            params["target_family"] = .string(family)
        }

        phases[slot] = .working(kind)
        tasks[slot] = Task { [weak self] in
            let outcome = await MetaJobRunner.run(
                client: client, modelId: assistant.id, task: "assist",
                params: params)
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let job):
                if let result = AssistResult(meta: job.result?.meta) {
                    self.phases[slot] = .done(result)
                } else {
                    self.phases[slot] = .failed(
                        MetaJobRunner.Failure.empty.message)
                }
            case .failure(let failure):
                self.phases[slot] = .failed(failure.message)
            }
            self.tasks[slot] = nil
        }
    }

    private static func encode(_ input: [String: JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(input) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
