import Foundation
@testable import LocalMusicGen

/// A `ModelInfo` built from its Swift initialiser, for tests about which models
/// can serve which feature.
///
/// Those rules are all shape-driven — a model qualifies by the tasks and params
/// it declares — so a fixture only ever needs to vary those two things, and
/// everything else can be a plausible constant. Existing test files each grew
/// their own private version of this; new ones should reach for this instead of
/// adding a fourth.
enum ModelFixtures {
    static func model(id: String,
                      tasks: [String]? = nil,
                      paramKeys: [String] = [],
                      installed: Bool = true,
                      family: String = "assistant",
                      sizeBytes: Int64 = 880_000_000,
                      supportsLyrics: Bool = false,
                      lyricsTags: [String]? = nil) -> ModelInfo {
        ModelInfo(
            id: id, family: family, featured: false, format: nil,
            variantOf: nil, tags: nil, displayName: id, description: "",
            hfRepos: [], sizeBytes: sizeBytes,
            installState: installed ? .installed : .notInstalled,
            installedBytes: 0, pinned: false,
            capabilities: Capabilities(
                supportsLyrics: supportsLyrics, instrumentalOnly: !supportsLyrics,
                duration: DurationSpec(minS: 1, maxS: 300, defaultS: 60),
                sampleRate: 48000, outputsPerJobMax: 1,
                estSecondsPerAudioSecond: 1,
                lyricsTags: lyricsTags, lyricsHint: nil,
                tasks: tasks, estRealtimeFactor: nil,
                params: paramKeys.map(param)),
            requirements: Requirements(minRamBytes: 1, diskBytes: 0,
                                       speedTier: .fast),
            license: LicenseInfo(name: "MIT", commercialUse: true,
                                 requiresHfToken: false, url: nil),
            notes: nil)
    }

    /// A minimal declared param. Only the key matters to the rules under test —
    /// every eligibility predicate in the app asks whether a key is declared,
    /// never what its bounds are.
    static func param(_ key: String) -> ParamSpec {
        ParamSpec(key: key, type: .string, label: key, help: nil,
                  default: .null, nullable: true, min: nil, max: nil,
                  step: nil, placeholder: nil, choices: nil,
                  isInternal: nil, resolveUploads: nil)
    }
}
