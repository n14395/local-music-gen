// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import WebKit

// The one place the app touches WebKit. abcjs (vendored under
// Resources/Notation, see abcjs-LICENSE.txt) renders ABC to SVG inside a
// WKWebView loading a bundled page; everything in is `evaluateJavaScript`,
// everything out is one script message handler. The JavaScript surface is
// kept to two calls (`LMG.render`, `LMG.svg`) and two messages ("ready",
// "rendered") so this file can be reasoned about without reading abcjs.

/// What one render is asked for.
///
/// `Equatable`, and compared in `updateNSView`, so a SwiftUI redraw that
/// changed nothing costs no engraving. The Library's detail pane redraws on
/// every transport tick; without the comparison it would re-engrave the
/// score four times a second.
struct NotationRequest: Codable, Equatable {
    var abc: String
    /// The width the view has, in points. The page derives the staff width
    /// from this and `scale`. There is deliberately no responsive mode: abcjs
    /// discards `scale` in that mode, which would have made the sheet's zoom
    /// a no-op — and a page that resizes itself to a view that resizes itself
    /// to the page is a layout loop waiting to happen.
    var width: Double
    var scale: Double = 1
    /// Semitones. abcjs moves the key signature and every note.
    var transpose: Int = 0
    var theme: NotationTheme = .bench
    /// A CSS colour painted behind the score. nil is transparent, so the
    /// SwiftUI background shows through; exports set it, the views never do.
    var background: String?
}

/// What the page reports after a render.
struct NotationRender: Equatable {
    var height: Double
    var warnings: [String]
    /// Tunes with at least one staff. Zero is the app's whole test for "this
    /// is prose filed as ABC": no Swift-side heuristic, abcjs's verdict.
    var tunes: Int

    var isEmpty: Bool { tunes == 0 }
}

/// The palette, as the hex strings CSS wants. Built once from `Bench`.
struct NotationTheme: Codable, Equatable, Sendable {
    var foreground: String
    var muted: String
    var accent: String

    /// Light on dark, from the app's own palette. The app forces dark
    /// appearance and abcjs draws black by default, which on `panel` is a
    /// blank card.
    static let bench = NotationTheme(
        foreground: hex(Bench.Palette.textPrimary),
        muted: hex(Bench.Palette.textMuted),
        accent: hex(Bench.Palette.accent))

    /// Black on white, for a score that is going onto paper.
    static let paper = NotationTheme(foreground: "#000000", muted: "#555555",
                                     accent: "#000000")

    /// `#rrggbb` for a SwiftUI colour. Through `NSColor` because `Color` has
    /// no component accessors on macOS 14, and through sRGB because
    /// `Color(hex:)` declares its values there and the page's CSS reads them
    /// the same way.
    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return "#ffffff"
        }
        func byte(_ component: CGFloat) -> Int {
            Int((component * 255).rounded()).clamped(to: 0...255)
        }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent),
                      byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

/// A handle a host keeps on the web view behind a `NotationView`, for the two
/// things a view cannot express as state: "give me the SVG" and "snapshot
/// yourself". The sheet owns one and passes it down; the coordinator fills it
/// in on every update, so it always points at the live page.
@MainActor
final class NotationBridge {
    fileprivate weak var coordinator: NotationWebView.Coordinator?

    /// The score as a standalone SVG document in `theme` on `background`,
    /// drawn off-screen at 100 %. nil when nothing has rendered or nothing
    /// drew.
    func svg(theme: NotationTheme, background: String) async -> String? {
        guard let coordinator, var request = coordinator.currentRequest else {
            return nil
        }
        request.theme = theme
        request.background = background
        request.scale = 1
        let text = await coordinator.exportSVG(request)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The score as PNG data in `theme` on `background`, at the size and zoom
    /// on screen. The page is redrawn in the export colours, snapshotted and
    /// put back: a transparent page snapshots to a transparent image, and a
    /// score people export is going somewhere that will not paint under it.
    func png(theme: NotationTheme, background: String) async -> Data? {
        guard let coordinator, var request = coordinator.currentRequest else {
            return nil
        }
        request.theme = theme
        request.background = background
        let image = await coordinator.withExportRender(request) {
            await coordinator.snapshot()
        }
        guard let image = image ?? nil else { return nil }
        return Self.pngData(image)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// An `NSViewRepresentable` around one `WKWebView` showing the notation page.
///
/// Sizing is the host's business: this view draws whatever height it is
/// given and reports, through `onRendered`, how tall the score actually is.
/// `NotationView` turns that report into a frame.
struct NotationWebView: NSViewRepresentable {
    /// nil until the host knows its width; nothing is drawn for nil.
    let request: NotationRequest?
    var bridge: NotationBridge?
    let onRendered: (NotationRender) -> Void

    static let handlerName = "notation"

    /// The page, wherever the bundle put it. `Copy Bundle Resources` flattens
    /// a group's files into `Contents/Resources`; a folder reference keeps
    /// the `Notation/` directory. The page's script tags are relative, so
    /// either layout loads — and either is looked for, so a change to the
    /// project file cannot blank every score.
    static var pageURL: URL? {
        Bundle.main.url(forResource: "notation", withExtension: "html",
                        subdirectory: "Notation")
            ?? Bundle.main.url(forResource: "notation", withExtension: "html")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NotationWKWebView {
        let configuration = WKWebViewConfiguration()
        let content = WKUserContentController()
        // The controller retains its handlers. The handler holds the
        // coordinator weakly and the coordinator removes the handler when the
        // view goes — the difference between a leak per sheet and none.
        content.add(NotationMessageHandler(coordinator: context.coordinator),
                    name: Self.handlerName)
        configuration.userContentController = content
        configuration.preferences.isTextInteractionEnabled = false
        let view = NotationWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        // The page is transparent, and so must the view be, or WebKit paints
        // white under it. `drawsBackground` is the long-standing key for that;
        // `underPageBackgroundColor` is the public one and covers the
        // over-scroll area the first does not.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        context.coordinator.attach(view)
        if let url = Self.pageURL {
            view.loadFileURL(url,
                             allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // A `.js` that never reached the bundle would otherwise fail as a
            // blank rectangle; say so where the score would have been.
            context.coordinator.pageMissing()
        }
        return view
    }

    func updateNSView(_ view: NotationWKWebView, context: Context) {
        context.coordinator.onRendered = onRendered
        bridge?.coordinator = context.coordinator
        context.coordinator.request(request)
    }

    static func dismantleNSView(_ view: NotationWKWebView,
                                coordinator: Coordinator) {
        coordinator.tearDown()
    }
}

extension NotationWebView {
    /// Owns the conversation with the page: queues the first request until
    /// the page says it is ready, sends only what changed, and turns the
    /// page's reports into `onRendered` calls — or, for an export, into the
    /// answer an awaiting caller is waiting on.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        var onRendered: ((NotationRender) -> Void)?
        private var isReady = false
        /// The latest request SwiftUI asked for, and the one the page has.
        private var wanted: NotationRequest?
        private var shown: NotationRequest?
        /// While an export has the page in its own colours, SwiftUI's
        /// requests are held and replayed afterwards.
        private var exporting = false
        /// Callers waiting for the next "rendered" report — exports only.
        private var waiters: [UUID: CheckedContinuation<NotationRender?, Never>] = [:]
        private let encoder = JSONEncoder()

        /// What the page is showing, for an export to start from.
        var currentRequest: NotationRequest? { shown }

        fileprivate func attach(_ view: WKWebView) { webView = view }

        fileprivate func pageReady() {
            isReady = true
            flush()
        }

        fileprivate func pageMissing() {
            // Off the current turn: this is called from `makeNSView`, inside
            // a SwiftUI update, and the report sets state on the host.
            Task { @MainActor [weak self] in
                self?.onRendered?(NotationRender(
                    height: 0,
                    warnings: ["The notation page is missing from the app bundle."],
                    tunes: 0))
            }
        }

        fileprivate func request(_ request: NotationRequest?) {
            wanted = request
            flush()
        }

        private func flush() {
            guard isReady, !exporting, let wanted, wanted != shown else { return }
            shown = wanted
            send(wanted)
        }

        /// `LMG.<call>(<json>)`. Encoded, never interpolated: ABC contains
        /// every quote and backslash there is, and a JSON object literal is a
        /// JavaScript object literal.
        private func javaScript(_ call: String,
                                _ request: NotationRequest) -> String? {
            guard let data = try? encoder.encode(request),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return "LMG.\(call)(\(json));"
        }

        private func send(_ request: NotationRequest) {
            guard let webView, let script = javaScript("render", request) else {
                return
            }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else { return }
                // The page threw before it could report, so nothing will:
                // say so rather than leave a spinner or a stale score up.
                self?.didRender(NotationRender(
                    height: 0,
                    warnings: ["The notation page did not respond: "
                               + error.localizedDescription],
                    tunes: 0))
            }
        }

        fileprivate func didRender(_ render: NotationRender) {
            let pending = waiters
            waiters = [:]
            for waiter in pending.values { waiter.resume(returning: render) }
            if !exporting { onRendered?(render) }
        }

        /// The next report, or nil after three seconds of silence — an
        /// export must never hang the sheet on a page that threw.
        private func nextRender() async -> NotationRender? {
            let id = UUID()
            return await withCheckedContinuation { continuation in
                waiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self,
                          let waiter = self.waiters.removeValue(forKey: id)
                    else { return }
                    waiter.resume(returning: nil)
                }
            }
        }

        /// Draw `request` on the live page, run `body` against it, then put
        /// the page back the way SwiftUI wants it. nil if the page could not
        /// draw the export.
        func withExportRender<T>(_ request: NotationRequest,
                                 _ body: @MainActor () async -> T) async -> T? {
            guard isReady, webView != nil, !exporting else { return nil }
            exporting = true
            send(request)
            guard await nextRender() != nil else {
                exporting = false
                flush()
                return nil
            }
            let result = await body()
            if let shown {
                send(shown)
                _ = await nextRender()
            }
            exporting = false
            flush()
            return result
        }

        /// `LMG.svg(request)` — the score drawn off-screen and serialised.
        func exportSVG(_ request: NotationRequest) async -> String? {
            guard isReady, let webView, let script = javaScript("svg", request)
            else { return nil }
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }
        }

        func snapshot() async -> NSImage? {
            guard let webView else { return nil }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            return try? await webView.takeSnapshot(configuration: configuration)
        }

        fileprivate func tearDown() {
            let pending = waiters
            waiters = [:]
            for waiter in pending.values { waiter.resume(returning: nil) }
            onRendered = nil
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: NotationWebView.handlerName)
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView = nil
        }

        // MARK: WKNavigationDelegate

        /// Only the initial file load. There is nothing to navigate to, and
        /// a stray link in an ABC `%%text` directive must not open anything.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction)
            async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let isPage = url?.isFileURL == true
                && url?.lastPathComponent == "notation.html"
            return isPage ? .allow : .cancel
        }
    }
}

/// The page's messages, decoded and handed to the coordinator. A class of its
/// own, holding the coordinator weakly, because `WKUserContentController`
/// retains whatever it is given — see `makeNSView`.
@MainActor
private final class NotationMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: NotationWebView.Coordinator?

    init(coordinator: NotationWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["event"] as? String {
        case "ready":
            coordinator?.pageReady()
        case "rendered":
            coordinator?.didRender(NotationRender(
                height: (body["height"] as? NSNumber)?.doubleValue ?? 0,
                warnings: (body["warnings"] as? [Any])?
                    .compactMap { $0 as? String } ?? [],
                tunes: (body["tunes"] as? NSNumber)?.intValue ?? 0))
        default:
            break
        }
    }
}

/// A web view that is a picture. It takes no clicks, no focus and no context
/// menu, and because it is invisible to hit-testing the scroll wheel reaches
/// the SwiftUI scroll view behind it — a score in the Library pane must not
/// be a dead patch the list stops scrolling over.
final class NotationWKWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
