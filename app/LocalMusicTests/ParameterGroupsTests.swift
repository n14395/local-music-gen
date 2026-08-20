import XCTest
@testable import LocalMusic

/// Sorting a model's parameters into the redesign's named groups.
///
/// The app's standing invariant is zero hardcoded per-model UI, so grouping has
/// to work from the wire: either a `group` the catalog declares, or a fallback
/// classifier over the key name. The classifier is allowed to be imperfect —
/// what it must never do is lose a parameter, because a param that does not
/// render is a param the user cannot set and cannot see is unset.
final class ParameterGroupsTests: XCTestCase {

    private func spec(_ key: String, type: String = "float",
                      group: String? = nil, groupLabel: String? = nil,
                      appliesWhen: String? = nil) -> ParamSpec {
        let groupJSON = group.map { "\"group\": \"\($0)\"," } ?? ""
        let labelJSON = groupLabel.map { "\"group_label\": \"\($0)\"," } ?? ""
        let appliesJSON = appliesWhen ?? ""
        let json = """
        {"key": "\(key)", "type": "\(type)", "label": "\(key)",
         \(groupJSON)\(labelJSON)\(appliesJSON)
         "default": 1, "nullable": false}
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ParamSpec.self, from: Data(json.utf8))
    }

    // MARK: partition

    func testEveryParamLandsInExactlyOneGroup() {
        let specs = [spec("steps"), spec("guidance_scale"), spec("bpm"),
                     spec("task_type", type: "enum"), spec("src_audio", type: "audio"),
                     spec("wobble"), spec("seed"), spec("vocal_language", type: "enum")]
        let groups = ParameterGroups.groups(for: specs)
        let placed = groups.flatMap(\.specs).map(\.key).sorted()
        XCTAssertEqual(placed, specs.map(\.key).sorted())
        XCTAssertEqual(placed.count, Set(placed).count, "a param appeared twice")
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(ParameterGroups.groups(for: []).isEmpty)
    }

    // MARK: classifier

    func testSamplingKeys() {
        for key in ["seed", "num_inference_steps", "guidance_scale", "cfg",
                    "temperature", "top_k", "lm_reasoning"] {
            XCTAssertEqual(ParameterGroups.classify(key: key, type: .float), .sampling,
                           "\(key) should be sampling")
        }
    }

    func testMusicalKeys() {
        for key in ["bpm", "target_key", "vocal_language", "lyrics_strength"] {
            XCTAssertEqual(ParameterGroups.classify(key: key, type: .string), .musical,
                           "\(key) should be musical")
        }
    }

    func testTaskKeys() {
        for key in ["task_type", "src_audio", "reference_audio", "cover_strength",
                    "repainting_start", "extend_audio"] {
            XCTAssertEqual(ParameterGroups.classify(key: key, type: .string), .task,
                           "\(key) should be task")
        }
    }

    /// Audio and MIDI inputs describe what you are transforming, whatever they
    /// are called — a melody upload is not a "sampling" control.
    func testAudioParamsAlwaysClassifyAsTask() {
        XCTAssertEqual(ParameterGroups.classify(key: "melody_audio", type: .audio), .task)
        XCTAssertEqual(ParameterGroups.classify(key: "notes", type: .midi), .task)
    }

    func testUnknownKeyFallsToOther() {
        XCTAssertEqual(ParameterGroups.classify(key: "wobble", type: .float), .other)
    }

    // MARK: declared groups

    func testDeclaredGroupBeatsTheClassifier() {
        // "seed" would classify as sampling; the catalog says otherwise.
        let groups = ParameterGroups.groups(for: [spec("seed", group: "musical")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "musical")
        XCTAssertEqual(groups[0].specs.map(\.key), ["seed"])
    }

    func testDeclaredLabelIsUsed() {
        let groups = ParameterGroups.groups(
            for: [spec("x", group: "wild", groupLabel: "Wild things")])
        XCTAssertEqual(groups[0].label, "Wild things")
    }

    func testUndeclaredLabelIsDerivedFromTheId() {
        let groups = ParameterGroups.groups(for: [spec("x", group: "post_process")])
        XCTAssertEqual(groups[0].label, "Post Process")
    }

    /// Models that rely on the classifier must all lay out the same way, so
    /// the fallback ids follow the design's order regardless of param order.
    func testFallbackGroupsUseCanonicalOrder() {
        let specs = [spec("wobble"), spec("src_audio", type: "audio"),
                     spec("bpm"), spec("steps")]
        let ids = ParameterGroups.groups(for: specs).map(\.id)
        XCTAssertEqual(ids, ["sampling", "musical", "task", "other"])
    }

    // MARK: applies_when

    private func conditional(_ key: String, values: [String]) -> ParamSpec {
        let list = values.map { "\"\($0)\"" }.joined(separator: ", ")
        return spec(key, appliesWhen:
            "\"applies_when\": {\"param\": \"task_type\", \"values\": [\(list)]},")
    }

    func testApplicableWhenTheConditionMatches() {
        let spec = conditional("cover_strength", values: ["cover"])
        XCTAssertTrue(ParameterGroups.isApplicable(
            spec, values: ["task_type": .string("cover")]))
        XCTAssertFalse(ParameterGroups.isApplicable(
            spec, values: ["task_type": .string("generate")]))
    }

    /// If the referenced param is not in the form at all we cannot judge, and
    /// dimming a control for a reason we cannot state is worse than showing it.
    func testApplicableWhenTheReferencedParamIsAbsent() {
        XCTAssertTrue(ParameterGroups.isApplicable(
            conditional("cover_strength", values: ["cover"]), values: [:]))
    }

    func testUnconditionalSpecsAreAlwaysApplicable() {
        XCTAssertTrue(ParameterGroups.isApplicable(spec("steps"), values: [:]))
    }

    func testFootnoteNamesTheTasksTheDimmedFieldsBelongTo() {
        let specs = [spec("steps"),
                     conditional("cover_strength", values: ["cover"]),
                     conditional("repainting_start", values: ["repaint"])]
        let note = ParameterGroups.dimmedFootnote(
            for: specs, values: ["task_type": .string("generate")])
        XCTAssertEqual(note, "Dimmed fields belong to the Cover and Repaint tasks")
    }

    func testNoFootnoteWhenEverythingApplies() {
        let specs = [spec("steps"), conditional("cover_strength", values: ["cover"])]
        XCTAssertNil(ParameterGroups.dimmedFootnote(
            for: specs, values: ["task_type": .string("cover")]))
    }
}
