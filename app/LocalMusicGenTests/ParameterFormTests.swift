import XCTest
@testable import LocalMusicGen

@MainActor
final class ParameterFormTests: XCTestCase {
    private func spec(_ key: String, _ type: ParamType, default d: JSONValue,
                      nullable: Bool = false, min: Double? = nil,
                      max: Double? = nil,
                      choices: [EnumChoice]? = nil) -> ParamSpec {
        ParamSpec(key: key, type: type, label: key, help: nil, default: d,
                  nullable: nullable, min: min, max: max, step: nil,
                  placeholder: nil, choices: choices, isInternal: nil,
                  resolveUploads: nil)
    }

    func testDefaultsPopulate() {
        let state = ParameterFormState(specs: [
            spec("steps", .int, default: .int(60), min: 10, max: 200),
            spec("seed", .int, default: .null, nullable: true),
            spec("variant", .enum, default: .string("turbo"),
                 choices: [EnumChoice(value: "turbo", label: "Turbo")]),
        ])
        XCTAssertEqual(state.params["steps"], .int(60))
        XCTAssertEqual(state.params["seed"], .null)
        XCTAssertEqual(state.params["variant"], .string("turbo"))
    }

    func testClamping() {
        let s = spec("steps", .int, default: .int(60), min: 10, max: 200)
        let state = ParameterFormState(specs: [s])
        state.setDouble(s, 500)
        XCTAssertEqual(state.params["steps"], .int(200))
        state.setDouble(s, -5)
        XCTAssertEqual(state.params["steps"], .int(10))
        state.setDouble(s, 42.7)
        XCTAssertEqual(state.params["steps"], .int(43), "int specs round")
    }

    func testFloatStaysFloat() {
        let s = spec("guidance", .float, default: .double(3.0), min: 1, max: 15)
        let state = ParameterFormState(specs: [s])
        state.setDouble(s, 7.5)
        XCTAssertEqual(state.params["guidance"], .double(7.5))
    }

    func testNullableSeedRoundTrip() {
        let s = spec("seed", .int, default: .null, nullable: true, min: 0,
                     max: 100)
        let state = ParameterFormState(specs: [s])
        XCTAssertTrue(state.isNull(s))
        state.setDouble(s, 42)
        XCTAssertEqual(state.params["seed"], .int(42))
        state.setNull(s)
        XCTAssertEqual(state.params["seed"], .null)
    }
}
