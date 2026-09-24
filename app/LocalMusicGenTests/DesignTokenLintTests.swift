// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// A house-style guard for the redesign.
///
/// The app is dark-only and every colour, font and control comes from
/// `Bench`. That is not enforceable by the type system — `.secondary` and
/// `.borderedProminent` compile perfectly well — so it is enforced here. The
/// failure mode this prevents is quiet: one system-styled control in a dark
/// panel does not crash anything, it just looks like a different app, and by
/// the time anyone notices there are thirty of them.
///
/// The scan reads the checked-out sources via `#filePath`, which is baked in at
/// compile time and points at this file. If the tests are ever run somewhere
/// the sources are absent, the scan finds no files and skips rather than
/// failing on the environment.
final class DesignTokenLintTests: XCTestCase {

    /// Tokens that have a Bench equivalent and must not appear in a view.
    /// Each is paired with what to use instead, so a failure tells you the fix.
    private static let banned: [(needle: String, use: String)] = [
        (".quinary", "Bench.Palette.card"),
        (".quaternary", "Bench.Palette.control"),
        ("Color.accentColor", "Bench.Palette.accent"),
        (".accentColor", "Bench.Palette.accent"),
        ("Color(nsColor: .separatorColor)", "Bench.Palette.hairline"),
        (".background(.bar)", "Bench.Palette.panel"),
        (".buttonStyle(.borderedProminent)", ".buttonStyle(.benchPrimary)"),
        (".buttonStyle(.bordered)", ".buttonStyle(.benchSecondary)"),
        (".textFieldStyle(.roundedBorder)", "a Bench field"),
        (".pickerStyle(.segmented)", "BenchSegmented"),
        (".foregroundStyle(.secondary)", "Bench.Palette.textTertiary"),
        (".foregroundStyle(.tertiary)", "Bench.Palette.textFaint"),
        (".foregroundStyle(.red)", "Bench.Palette.danger"),
        (".foregroundStyle(.green)", "Bench.Palette.ok"),
        (".foregroundStyle(.yellow)", "Bench.Palette.warn"),
        (".foregroundStyle(.orange)", "Bench.Palette.warn"),
        ("ContentUnavailableView", "StudioEmptyState"),
    ]

    /// Directories whose styling is deliberately not Bench's business.
    private static let exempt = ["/Design/", "/Core/", "/App/SingleInstance.swift"]

    func testNoSystemStylingSurvivesInFeatureViews() throws {
        let files = try swiftFiles(under: "Features")
        try XCTSkipIf(files.isEmpty, "sources not present next to the test bundle")

        var offences: [String] = []
        for url in files {
            let path = url.path
            guard !Self.exempt.contains(where: { path.contains($0) }) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                // Comments are allowed to name the thing they replaced.
                let code = line.split(separator: "//", maxSplits: 1,
                                      omittingEmptySubsequences: false)[0]
                for rule in Self.banned where code.contains(rule.needle) {
                    offences.append("\(url.lastPathComponent):\(index + 1) "
                                    + "uses \(rule.needle) — use \(rule.use)")
                }
            }
        }
        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n"))
    }

    /// The design puts every number in a monospaced face. This catches the
    /// most common slip: a hardcoded `.system(size:)` in a view that should
    /// have gone through `Bench.Typo`.
    func testFeatureViewsGoThroughTheTypeRamp() throws {
        let files = try swiftFiles(under: "Features")
        try XCTSkipIf(files.isEmpty, "sources not present next to the test bundle")

        var offences: [String] = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let code = line.split(separator: "//", maxSplits: 1,
                                      omittingEmptySubsequences: false)[0]
                // Dynamic Type styles have no place in a fixed 1440-wide design.
                for style in [".font(.caption)", ".font(.caption2)", ".font(.headline)",
                              ".font(.callout)", ".font(.body)", ".font(.title)",
                              ".font(.title2)", ".font(.title3)", ".font(.subheadline)"]
                    where code.contains(style) {
                    offences.append("\(url.lastPathComponent):\(index + 1) "
                                    + "uses \(style) — use Bench.Typo")
                }
            }
        }
        XCTAssertEqual(offences, [], "\n" + offences.joined(separator: "\n"))
    }

    // MARK: helpers

    private func swiftFiles(under directory: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)   // …/LocalMusicGenTests/<this file>
            .deletingLastPathComponent()             // …/LocalMusicGenTests
            .deletingLastPathComponent()             // …/app
            .appendingPathComponent("LocalMusicGen")
            .appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
