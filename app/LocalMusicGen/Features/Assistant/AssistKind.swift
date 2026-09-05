import Foundation

/// The jobs the writing assistant can be asked to do.
///
/// One case per `kind` the engine's assistant adapter understands. The raw
/// values are wire values — they travel as the `kind` param and must not be
/// renamed — and each case knows how to describe itself so the pages built on
/// top of it need no copy of their own.
///
/// Several cards share a kind (`fleshOut` backs both "Flesh out my idea" and
/// the Improve button inside Generate), which is why this is a separate type
/// from the recipe list rather than a property of it.
enum AssistKind: String, CaseIterable, Sendable, Equatable {
    case interview
    case interviewFinish = "interview_finish"
    case fleshOut = "flesh_out"
    case lyrics
    case pickModel = "pick_model"
    case planSong = "plan_song"
    case routeIntent = "route_intent"
    case brief
    case translateLyrics = "translate_lyrics"
    case describeSong = "describe_song"
    case moreLikeThis = "more_like_this"
    case critiqueFix = "critique_fix"
    case nameAndTag = "name_and_tag"

    /// What the page says while the model is working. Present continuous, and
    /// specific: "Writing…" on every one of thirteen screens tells the reader
    /// nothing about which of them they are on.
    var workingLine: String {
        switch self {
        case .interview: "Thinking of questions…"
        case .interviewFinish: "Writing your description…"
        case .fleshOut: "Filling out your idea…"
        case .lyrics: "Writing lyrics…"
        case .pickModel: "Looking through your models…"
        case .planSong: "Sketching the shape…"
        case .routeIntent: "Working out what you meant…"
        case .brief: "Dreaming something up…"
        case .translateLyrics: "Translating…"
        case .describeSong: "Listening back…"
        case .moreLikeThis: "Finding the family resemblance…"
        case .critiqueFix: "Working out what to change…"
        case .nameAndTag: "Naming it…"
        }
    }

    /// Whether this kind needs to know which music model the text is destined
    /// for. The ones that reason about the app or the library do not, and
    /// sending a family for them would only narrow the answer for no reason.
    var needsTargetModel: Bool {
        switch self {
        case .pickModel, .routeIntent, .nameAndTag: false
        default: true
        }
    }

    /// Whether the answer is a prompt the user can carry into Generate.
    var producesPrompt: Bool {
        switch self {
        case .interviewFinish, .fleshOut, .brief, .critiqueFix, .describeSong:
            true
        default: false
        }
    }

    /// Whether the answer is lyrics.
    var producesLyrics: Bool {
        self == .lyrics || self == .translateLyrics
    }
}

// MARK: - What comes back

/// One assistant answer, decoded.
///
/// `ok` is the adapter's own verdict on whether it got structured output back.
/// When it is false, `raw` still holds the model's words and the UI shows them
/// as editable text — a small model that wrote something useful in the wrong
/// shape is worth more than an error message, and the user was going to edit
/// the result anyway.
struct AssistResult: Sendable, Equatable {
    var kind: AssistKind
    var ok: Bool
    var raw: String
    var value: [String: JSONValue]
    var repaired: Bool

    init?(meta: [String: JSONValue]?) {
        guard let payload = meta?["assist"]?.objectValue else { return nil }
        guard let kindString = payload["kind"]?.stringValue,
              let kind = AssistKind(rawValue: kindString) else { return nil }
        self.kind = kind
        self.ok = payload["ok"]?.boolValue ?? false
        self.raw = payload["raw"]?.stringValue ?? ""
        self.value = payload["value"]?.objectValue ?? [:]
        self.repaired = payload["repaired"]?.boolValue ?? false
    }

    /// Memberwise, for tests and for the previews.
    init(kind: AssistKind, ok: Bool, raw: String,
         value: [String: JSONValue], repaired: Bool = false) {
        self.kind = kind
        self.ok = ok
        self.raw = raw
        self.value = value
        self.repaired = repaired
    }

    // MARK: Typed readers
    //
    // Every one tolerates absence. A 1.5B model that returned eight of nine
    // fields should render eight fields, not an error — so nothing here is
    // allowed to fail, and the pages check for empty rather than for nil.

    var prompt: String { value["prompt"]?.stringValue ?? "" }
    var lyricsText: String { value["lyrics"]?.stringValue ?? "" }
    var title: String { value["title"]?.stringValue ?? "" }
    var description: String { value["description"]?.stringValue ?? "" }
    var summary: String { value["summary"]?.stringValue ?? "" }
    var idea: String { value["idea"]?.stringValue ?? "" }

    var addedDetails: [String] {
        (value["added"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    var tags: [String] {
        (value["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    var questions: [AssistQuestion] {
        (value["questions"]?.arrayValue ?? []).compactMap(AssistQuestion.init)
    }

    var sections: [AssistSection] {
        (value["sections"]?.arrayValue ?? []).compactMap(AssistSection.init)
    }

    var variations: [AssistVariation] {
        (value["variations"]?.arrayValue ?? []).compactMap(AssistVariation.init)
    }

    var changes: [AssistChange] {
        (value["changes"]?.arrayValue ?? []).compactMap(AssistChange.init)
    }

    var modelPick: AssistModelPick? {
        value["best"]?.objectValue.flatMap(AssistModelPick.init)
    }

    var modelAlternatives: [AssistModelPick] {
        (value["alternatives"]?.arrayValue ?? [])
            .compactMap { $0.objectValue }
            .compactMap(AssistModelPick.init)
    }

    var route: AssistRoute? { AssistRoute(value) }

    /// The assistant believes it has asked enough and can write the
    /// description now. Also true when it simply returned no questions —
    /// an empty question list is the same statement made implicitly.
    var interviewIsDone: Bool {
        (value["ready"]?.boolValue ?? false) || questions.isEmpty
    }
}

struct AssistQuestion: Sendable, Equatable, Identifiable {
    var id: String { question }
    var question: String
    var examples: [String]

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let question = object["question"]?.stringValue,
              !question.isEmpty else { return nil }
        self.question = question
        self.examples = (object["examples"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
    }
}

struct AssistSection: Sendable, Equatable, Identifiable {
    var id: String { "\(tag)-\(seconds)-\(what)" }
    var tag: String
    var seconds: Int
    var what: String

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        let tag = object["tag"]?.stringValue ?? ""
        guard !tag.isEmpty else { return nil }
        self.tag = tag
        self.seconds = object["seconds"]?.intValue ?? 0
        self.what = object["what"]?.stringValue ?? ""
    }
}

struct AssistVariation: Sendable, Equatable, Identifiable {
    var id: String { prompt }
    var prompt: String
    var differs: String

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let prompt = object["prompt"]?.stringValue,
              !prompt.isEmpty else { return nil }
        self.prompt = prompt
        self.differs = object["differs"]?.stringValue ?? ""
    }
}

struct AssistChange: Sendable, Equatable, Identifiable {
    var id: String { "\(before)→\(after)" }
    var before: String
    var after: String

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        // "from" is a Swift keyword in argument position but a perfectly
        // ordinary JSON key; the rename is only here.
        self.before = object["from"]?.stringValue ?? ""
        self.after = object["to"]?.stringValue ?? ""
        if before.isEmpty && after.isEmpty { return nil }
    }
}

struct AssistModelPick: Sendable, Equatable, Identifiable {
    var id: String { modelId }
    var modelId: String
    var why: String
    var installed: Bool

    init?(_ object: [String: JSONValue]) {
        guard let modelId = object["id"]?.stringValue, !modelId.isEmpty
        else { return nil }
        self.modelId = modelId
        self.why = object["why"]?.stringValue ?? ""
        self.installed = object["installed"]?.boolValue ?? false
    }
}

/// Where "say the job in your own words" decided to send you.
struct AssistRoute: Sendable, Equatable {
    var actionId: String?
    var prompt: String?
    var subject: String?
    var confidence: Double
    var reason: String

    init?(_ value: [String: JSONValue]) {
        // A null action is a real answer — "nothing here does that" — so this
        // initialiser only fails when the model returned no opinion at all.
        guard value["action"] != nil || value["reason"] != nil else { return nil }
        self.actionId = value["action"]?.stringValue
        self.prompt = value["prompt"]?.stringValue
        self.subject = value["subject"]?.stringValue
        self.confidence = value["confidence"]?.doubleValue ?? 0
        self.reason = value["reason"]?.stringValue ?? ""
    }

    /// The recipe this route names, if it names one that exists. The model is
    /// told to use ids from the list it was given, but it is a small model —
    /// an id that is not in the catalog is treated as no answer rather than
    /// navigating somewhere arbitrary.
    var recipe: Recipe? {
        guard let actionId else { return nil }
        return RecipeCatalog.recipe(id: actionId)
    }
}
