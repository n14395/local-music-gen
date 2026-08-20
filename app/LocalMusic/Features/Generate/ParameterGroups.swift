import Foundation

/// Sorting a model's parameters into the named groups the redesign shows —
/// `SAMPLING`, `MUSICAL`, `TASK & SOURCE` — without a single per-model branch.
///
/// A model may declare `group` on each `ParamSpec`, in which case that is used
/// verbatim. Most catalog entries do not, so the fallback classifies by key
/// name. That is a heuristic and is allowed to be: the worst case is a control
/// landing under "Other", which still renders, still submits, and still shows
/// its value. What it must never do is drop a param — `groups(for:)` is a
/// partition, and there is a test that says so.
enum ParameterGroups {

    struct Group: Identifiable {
        let id: String
        let label: String
        let specs: [ParamSpec]
    }

    /// Canonical groups, in the order the design lays them out.
    enum Known: String, CaseIterable {
        case sampling, musical, task, other

        var label: String {
            switch self {
            case .sampling: "Sampling"
            case .musical: "Musical"
            case .task: "Task & source"
            case .other: "Other"
            }
        }
    }

    /// Partition `specs` into groups. Internal params are the caller's problem
    /// — pass `visibleSpecs`.
    static func groups(for specs: [ParamSpec]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [ParamSpec]] = [:]
        var labels: [String: String] = [:]

        for spec in specs {
            let id = spec.group ?? classify(key: spec.key, type: spec.type).rawValue
            if buckets[id] == nil {
                order.append(id)
                labels[id] = spec.groupLabel
                    ?? Known(rawValue: id)?.label
                    ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            } else if labels[id] == nil, let declared = spec.groupLabel {
                labels[id] = declared
            }
            buckets[id, default: []].append(spec)
        }

        // Declared groups keep first-seen order; the fallback ids sort into the
        // canonical order so every model that relies on the classifier lays out
        // the same way.
        let canonical = Known.allCases.map(\.rawValue)
        let sorted = order.sorted { lhs, rhs in
            switch (canonical.firstIndex(of: lhs), canonical.firstIndex(of: rhs)) {
            case let (l?, r?): return l < r
            case (nil, _?): return true       // model-declared groups lead
            case (_?, nil): return false
            case (nil, nil): return false     // stable: keep first-seen order
            }
        }

        return sorted.map {
            Group(id: $0, label: labels[$0] ?? $0, specs: buckets[$0] ?? [])
        }
    }

    /// Key-name heuristic used when a model declares no groups.
    static func classify(key: String, type: ParamType) -> Known {
        let k = key.lowercased()

        // Audio and MIDI inputs are always about what you are transforming.
        if type == .audio || type == .midi { return .task }

        for token in ["seed", "step", "guidance", "cfg", "temperature", "top_k",
                      "top_p", "sampler", "scheduler", "shift", "omega", "eta",
                      "reasoning", "granularity"] where k.contains(token) {
            return .sampling
        }
        for token in ["bpm", "tempo", "key", "language", "lyric", "genre",
                      "instrument", "vocal", "loudness"] where k.contains(token) {
            return .musical
        }
        for token in ["task", "src", "source", "reference", "strength",
                      "repaint", "extend", "cover", "track", "stem", "target",
                      "audio"] where k.contains(token) {
            return .task
        }
        return .other
    }

    /// Whether a control is currently meaningful, given the form's values.
    ///
    /// Returns true when the spec declares no condition, when the referenced
    /// param is absent from the form (we cannot judge, so do not dim), or when
    /// its current value is one of the listed values.
    static func isApplicable(_ spec: ParamSpec,
                             values: [String: JSONValue]) -> Bool {
        guard let condition = spec.appliesWhen else { return true }
        guard let current = values[condition.param] else { return true }
        guard case .string(let value) = current else { return true }
        return condition.values.contains(value)
    }

    /// The footnote under a group that contains dimmed controls, e.g.
    /// "Dimmed fields belong to the Repaint and Cover tasks".
    static func dimmedFootnote(for specs: [ParamSpec],
                               values: [String: JSONValue]) -> String? {
        let inapplicable = specs.filter { !isApplicable($0, values: values) }
        guard !inapplicable.isEmpty else { return nil }
        let tasks = inapplicable
            .compactMap { $0.appliesWhen?.values }
            .flatMap { $0 }
        var seen = Set<String>()
        let unique = tasks.filter { seen.insert($0).inserted }
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        guard !unique.isEmpty else { return nil }
        let list = unique.count == 1
            ? unique[0]
            : unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1]
        return "Dimmed fields belong to the \(list) task\(unique.count == 1 ? "" : "s")"
    }
}
