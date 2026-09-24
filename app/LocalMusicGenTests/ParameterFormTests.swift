// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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

    /// §4.1: `nullable` means the UI offers an unset state. The enum menu had
    /// no way back to null once a choice was picked, which is a one-way door
    /// on 18 catalog entries — the state itself always could.
    func testNullableEnumGoesBackToUnset() {
        let s = spec("track", .enum, default: .null, nullable: true,
                     choices: [EnumChoice(value: "vocals", label: "Vocals"),
                               EnumChoice(value: "bgm", label: "Backing")])
        let state = ParameterFormState(specs: [s])
        XCTAssertTrue(state.isNull(s))
        state.setString(s, "vocals")
        XCTAssertEqual(state.params["track"], .string("vocals"))
        state.setNull(s)
        XCTAssertEqual(state.params["track"], .null)
        XCTAssertEqual(state.stringValue(s), "")
    }

    /// What the HELD pill and Studio's summary line print. One formatter for
    /// both, so the row and the line cannot disagree about the same number.
    func testPlainPrintsIntsWholeAndFloatsShort() {
        let seed = spec("seed", .int, default: .null, nullable: true)
        let guidance = spec("guidance", .float, default: .double(3))
        XCTAssertEqual(ParameterFormView.plain(1_843_293_012, seed),
                       "1843293012")
        XCTAssertEqual(ParameterFormView.plain(7, guidance), "7")
        XCTAssertEqual(ParameterFormView.plain(7.5, guidance), "7.5")
    }

    /// 75 of the 136 catalog entries declare 44 100 Hz, and integer division
    /// printed every one of them as "44 kHz".
    func testSampleRateReadsAsKilohertz() {
        XCTAssertEqual(ModelInspector.rate(44_100), "44.1 kHz")
        XCTAssertEqual(ModelInspector.rate(48_000), "48 kHz")
        XCTAssertEqual(ModelInspector.rate(32_000), "32 kHz")
        XCTAssertEqual(ModelInspector.rate(16_000), "16 kHz")
    }
}
