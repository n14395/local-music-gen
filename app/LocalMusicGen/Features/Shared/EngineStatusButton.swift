// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The three stores the engine panel reads, carried as one value.
///
/// `BackendDebugView` needs the status store, the process manager and the
/// telemetry store. Threading all three through every screen that merely shows
/// a status label would make the panel look like a dependency of the screen,
/// which it is not — it is a dependency of the *label*. So they travel
/// together, the way `SongActions` carries the jumps a track offers.
@MainActor
struct EngineStatus {
    let status: BackendStatusStore
    let manager: BackendProcessManager
    let telemetry: TelemetryStore
}

/// A status label you can click to find out why it says what it says.
///
/// The pre-redesign toolbar had this: a dot, a phase, and a popover behind it
/// holding the port, the version, the restart count and the engine log. The
/// redesign kept the panel but lost the click, which left "Degraded" as a word
/// with nothing behind it — you had to know to open Settings. This puts the
/// click back on whatever label the caller draws, so the two surfaces that
/// report engine state both lead to the readings behind it.
struct EngineStatusButton<Label: View>: View {
    let engine: EngineStatus
    /// Which way the panel opens: away from the sidebar, or down from a pill
    /// sitting in a top bar.
    var arrowEdge: Edge = .bottom
    @ViewBuilder var label: () -> Label

    @State private var showingPanel = false

    var body: some View {
        Button {
            showingPanel.toggle()
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPanel, arrowEdge: arrowEdge) {
            EngineStatusPanel(engine: engine)
        }
        .help("Engine status — port, version, machine readings and the log")
    }
}

/// `BackendDebugView` sized to be a popover.
///
/// The view is written to fill a settings pane, so on its own it has no width
/// to lay its label columns against and no ceiling to scroll under. Both are
/// supplied here rather than in the view itself, because the Settings pane
/// still wants it to fill whatever it is given.
private struct EngineStatusPanel: View {
    let engine: EngineStatus

    /// Where the panel stops growing and starts scrolling. Below this it is
    /// exactly as tall as it needs to be — which is the point, because how
    /// tall it needs to be moves: `Worker` appears once a model is held in
    /// memory, the memory bar once the worker reports a footprint, and a
    /// three-line `Reason` when the engine has fallen over. Any fixed height
    /// is wrong for all but one of those.
    private static let maxHeight: CGFloat = 700
    /// Stands in for one layout pass, before the measurement arrives. Near the
    /// real figure so the popover does not visibly resize as it opens.
    private static let estimatedHeight: CGFloat = 650

    @State private var contentHeight: CGFloat?

    private var height: CGFloat {
        min(contentHeight ?? Self.estimatedHeight, Self.maxHeight)
    }

    var body: some View {
        ScrollView {
            BackendDebugView(status: engine.status,
                             manager: engine.manager,
                             telemetry: engine.telemetry)
                .padding(12)
                .background {
                    // Measured from inside the scroll view, where the content
                    // is at its natural height. `fixedSize` would be the
                    // shorter spelling but it defeats scrolling at the cap:
                    // the scroll view would report its full height and so
                    // never have anything to scroll. macOS 15's
                    // `presentationSizing(.fitted)` would do the whole job;
                    // this app targets 14.
                    GeometryReader { proxy in
                        Color.clear
                            .task(id: proxy.size.height) {
                                contentHeight = proxy.size.height
                            }
                    }
                }
        }
        // The width is fixed, so the measured height is stable: nothing here
        // can feed back into what the content reports.
        .frame(width: 470, height: height)
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
    }
}

/// The affordance the label needs once it is pressable: a muted glyph saying
/// there is something behind this. Small enough not to compete with the status
/// dot, which is still the thing you are meant to read first.
struct EngineStatusHint: View {
    var body: some View {
        Image(systemName: "info.circle")
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaint)
    }
}
