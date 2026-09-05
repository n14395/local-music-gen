import SwiftUI
import XCTest
@testable import LocalMusicGen

/// The pure parts of the Bench design system: stem identity, and the two
/// readouts that turn engine numbers into the lines the sidebar and the queue
/// print. These are unit-tested rather than eyeballed because they are the
/// places a redesign is most tempted to invent a number.
final class BenchDesignTests: XCTestCase {

    // MARK: stem identity

    /// Part kinds arrive as free-form dot-namespaced strings, and the same
    /// stem must get the same colour whether it came from `stem.vocals`, a
    /// workbench lane called `vocals-2`, or a bare role.
    func testStemKindParsesTheTaxonomy() {
        XCTAssertEqual(Bench.StemKind("stem.vocals"), .vocals)
        XCTAssertEqual(Bench.StemKind("vocals-2"), .vocals)
        XCTAssertEqual(Bench.StemKind("VOCALS"), .vocals)
        XCTAssertEqual(Bench.StemKind("stem.drums"), .drums)
        XCTAssertEqual(Bench.StemKind("layer.bass"), .bass)
        XCTAssertEqual(Bench.StemKind("stem.piano"), .piano)
        XCTAssertEqual(Bench.StemKind("stem.guitar"), .guitar)
        XCTAssertEqual(Bench.StemKind("notes.melody"), .notes)
        XCTAssertEqual(Bench.StemKind("song.mix"), .unknown)
    }

    func testStemKindHandlesNothing() {
        XCTAssertEqual(Bench.StemKind(nil), .unknown)
        XCTAssertEqual(Bench.StemKind(""), .unknown)
    }

    /// MIDI parts must not take the "other" colour — the design gives notes
    /// their own cyan so a score never looks like a stem.
    func testNotesWinOverOther() {
        XCTAssertEqual(Bench.StemKind("notes.other"), .notes)
    }

    /// Stem colour is the app's only identifier for "which instrument is
    /// this" in a timeline lane or a gain slider, so two stems sharing a
    /// colour would be a genuine ambiguity rather than a cosmetic one.
    func testEveryStemHasADistinctColour() {
        let kinds = ["vocals", "drums", "bass", "other", "piano", "guitar", "notes"]
        let components = kinds.map { kind -> String in
            let color = NSColor(Bench.Palette.stem(kind))
                .usingColorSpace(.sRGB) ?? .black
            return String(format: "%.3f,%.3f,%.3f",
                          color.redComponent, color.greenComponent, color.blueComponent)
        }
        XCTAssertEqual(Set(components).count, kinds.count,
                       "two stems share a colour: \(components)")
    }

    // MARK: telemetry formatting

    func testGigabytesUsesOneDecimalUntilItGetsSilly() {
        XCTAssertEqual(TelemetryStore.gigabytes(2_200_000_000), "2.2")
        XCTAssertEqual(TelemetryStore.gigabytes(53_400_000_000), "53.4")
        XCTAssertEqual(TelemetryStore.gigabytes(418_000_000_000), "418")
        // A round figure keeps no decimal — "36.0 GB" reads like a measurement.
        XCTAssertEqual(TelemetryStore.gigabytes(36_000_000_000), "36")
    }

    func testBackendLabelsAreTheOnesTheDesignPrints() {
        XCTAssertEqual(TelemetryStore.backendLabel("mlx"), "MLX")
        XCTAssertEqual(TelemetryStore.backendLabel("metal"), "Metal")
        XCTAssertEqual(TelemetryStore.backendLabel("mps"), "Metal")
        XCTAssertEqual(TelemetryStore.backendLabel("cpu"), "CPU")
    }

    @MainActor
    func testMemoryLineIsNilUntilThereIsACeilingToDivideBy() {
        XCTAssertNil(TelemetryStore().memoryLine)
        XCTAssertNil(TelemetryStore().memoryFraction)
    }

    @MainActor
    func testMemoryLineNamesTheBackendWhenTheEngineReportsOne() {
        let store = TelemetryStore()
        store.apply(system(backend: "metal", workingSet: 36_000_000_000,
                           workerBytes: 2_200_000_000))
        XCTAssertEqual(store.memoryLine, "Metal · 2.2 / 36 GB")
    }

    /// GPU utilisation is device-wide and often unavailable. When it is
    /// missing the line must simply lose that clause, not print "GPU 0%".
    @MainActor
    func testBusyLineDropsGpuWhenItIsUnknown() {
        let store = TelemetryStore()
        store.apply(system(backend: "mlx", workingSet: 36_000_000_000,
                           workerBytes: 11_800_000_000))
        XCTAssertEqual(store.busyLine, "11.8 / 36 GB")

        store.apply(system(backend: "mlx", workingSet: 36_000_000_000,
                           workerBytes: 11_800_000_000, gpuPercent: 92))
        XCTAssertEqual(store.busyLine, "GPU 92% · 11.8 / 36 GB")
    }

    /// Metal's recommended working set is a much lower ceiling than physical
    /// RAM, and it is the one a model actually hits — prefer it when sent.
    @MainActor
    func testWorkingSetOutranksPhysicalRamAsTheCeiling() {
        let store = TelemetryStore()
        store.apply(system(backend: "metal", workingSet: 55_000_000_000,
                           workerBytes: 11_000_000_000, ramBytes: 68_000_000_000))
        XCTAssertEqual(store.memoryCeilingBytes, 55_000_000_000)
        XCTAssertEqual(store.memoryFraction ?? 0, 0.2, accuracy: 0.001)
    }

    private func system(backend: String?, workingSet: Int64?, workerBytes: Int64?,
                        gpuPercent: Double? = nil,
                        ramBytes: Int64 = 36_000_000_000) -> SystemInfo {
        let json = """
        {"ram_bytes": \(ramBytes), "free_disk_bytes": 418000000000,
         "machine": "Mac16,10", "warm_family": null, "warm_model_id": null,
         "transient_model_id": null, "pinned_model_id": null, "active_job_id": null,
         "memory_guard": null, "engine_versions": {},
         "accelerator": {"name": "Apple M1 Max",
                         "backend": \(backend.map { "\"\($0)\"" } ?? "null"),
                         "working_set_bytes": \(workingSet.map(String.init) ?? "null")},
         "usage": {"gpu_percent": \(gpuPercent.map { String($0) } ?? "null"),
                   "worker_bytes": \(workerBytes.map(String.init) ?? "null"),
                   "accelerator_bytes": null}}
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(SystemInfo.self, from: Data(json.utf8))
    }

    // MARK: download readout

    /// Throughput and ETA go through an EMA, because the engine samples speed
    /// by re-walking the model cache once a second and a raw sample swings
    /// around the true rate. Dividing one straight into the remaining bytes
    /// prints "3 hours" and then "4 minutes".
    func testRateSmoothsTowardsTheTrueSpeed() {
        var rate = DownloadRate()
        rate.ingest(12_000_000)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 12_000_000, accuracy: 1)
        // A single zero sample must not collapse the reading (half weight).
        rate.ingest(0)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 6_000_000, accuracy: 1)
    }

    /// A stalled download divided by ~0 bytes/s claims an ETA of several
    /// years, which is worse than admitting we do not know.
    func testEtaIsNilWhenTheRateHasCollapsed() {
        var rate = DownloadRate()
        rate.ingest(10)
        XCTAssertNil(rate.secondsRemaining(bytesDone: 1, bytesTotal: 1_000_000_000))
    }

    func testEtaIsNilWhenNothingIsLeft() {
        var rate = DownloadRate()
        rate.ingest(12_000_000)
        XCTAssertNil(rate.secondsRemaining(bytesDone: 100, bytesTotal: 100))
    }

    func testDownloadLineReadsBytesThroughputAndEta() {
        var rate = DownloadRate()
        rate.ingest(12_000_000)
        let line = DownloadFormat.line(done: 18_100_000_000,
                                       total: 53_400_000_000, rate: rate)
        XCTAssertTrue(line.hasPrefix("16.9 / 49.7 GB"), line)
        XCTAssertTrue(line.contains("12 MB/S"), line)
        XCTAssertTrue(line.hasSuffix("LEFT"), line)
    }

    /// Sub-megabyte links get their own unit rather than rounding to "0 MB/S".
    func testSlowLinksReadInKilobytes() {
        XCTAssertEqual(DownloadFormat.rate(700_000), "700 KB/S")
        XCTAssertNil(DownloadFormat.rate(nil))
        XCTAssertNil(DownloadFormat.rate(10))
    }

    /// Never "0 MIN LEFT" — that reads as finished when it is not.
    func testEtaNeverRoundsDownToZero() {
        XCTAssertEqual(DownloadFormat.eta(0.4), "1 S LEFT")
        XCTAssertEqual(DownloadFormat.eta(2942), "49 MIN LEFT")
        XCTAssertEqual(DownloadFormat.eta(4500), "1 H 15 MIN LEFT")
        XCTAssertNil(DownloadFormat.eta(nil))
        XCTAssertNil(DownloadFormat.eta(0))
    }

    // MARK: durations

    /// Precision drops as the number grows: seconds matter when a render is a
    /// minute away and are noise on a 49-minute download.
    func testDurationReadsAsSecondsThenMinutes() {
        XCTAssertEqual(JobRow.duration(40), "40 S")
        XCTAssertEqual(JobRow.duration(72), "1 MIN 12 S")
        XCTAssertEqual(JobRow.duration(120), "2 MIN")
        XCTAssertEqual(JobRow.duration(2942), "49 MIN")
        XCTAssertEqual(JobRow.duration(4500), "1 H 15 MIN")
    }
}
