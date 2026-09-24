// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

// The app's whole JavaScript surface: one namespace, two calls in
// (LMG.render, LMG.svg) and two messages out ("ready", "rendered"). Kept this
// small on purpose so NotationWebView.swift can be reasoned about without
// reading abcjs.
//
// abcjs 6.7.0 — see abcjs-LICENSE.txt for the version and where it came from.
(function () {
  "use strict";

  var PADDING = 8;

  function post(message) {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers.notation) handlers.notation.postMessage(message);
  }

  // abcjs's warnings are HTML fragments: the offending character is wrapped
  // in a styled <span> and the line around it is entity-encoded. They land
  // in a SwiftUI Text, so this takes the tags off and the entities back.
  function plain(html) {
    var box = document.createElement("div");
    box.innerHTML = String(html);
    return (box.textContent || "").replace(/\s+/g, " ").trim();
  }

  function options(req, scale) {
    // In wrap mode abcjs treats `staffwidth` as the width the score should
    // *end up* on screen: it breaks lines for staffwidth ÷ scale unscaled
    // units and the SVG's scale transform brings them back to staffwidth
    // pixels, with the padding scaled on top. So the staff is the view's
    // width less the scaled padding — not width ÷ scale, which is what the
    // non-wrap path wants and what this first said; measured through the
    // headless driver, that filled two thirds of the sheet at 150 % and
    // overflowed it at 80 %. `responsive` mode is not used anywhere: abcjs
    // discards `scale` in that mode, which would make zoom a no-op.
    var staffwidth = Math.max(160, Math.floor(req.width - PADDING * 2 * scale));
    return {
      staffwidth: staffwidth,
      scale: scale,
      visualTranspose: req.transpose || 0,
      // Re-break the lines to the staff width instead of honouring the
      // ABC's own newlines. The engine writes four bars to a line whatever
      // they hold, and abcjs otherwise keeps that: a dense line that did not
      // fit was stretched past the right edge and clipped, and zooming in
      // clipped more of it rather than flowing onto more lines. With wrap the
      // width decides — 150 % is more lines, 75 % is fewer — and the ABC's
      // line breaks are treated as the formatting hint they are.
      wrap: { minSpacing: 1.8, maxSpacing: 2.7 },
      add_classes: true,
      paddingtop: PADDING,
      paddingbottom: PADDING,
      paddingleft: PADDING,
      paddingright: PADDING,
      foregroundColor: req.theme.foreground,
      selectionColor: req.theme.accent
    };
  }

  // Whether a parsed tune is music, or prose that happened to parse.
  //
  // abcjs draws *something* for almost any text: the letters a–g in "a
  // gentle waltz in G major" are notes to it, and it engraves them on a
  // staff with one "Unknown character ignored" warning per letter that is
  // not. So "did a staff draw" is not the test — the headless smoke test
  // proved it, when a model's prose reply came back as one tune, 211 px
  // tall. The test is abcjs's own accounting: a tune is a score when it has
  // notes, and the characters abcjs threw away do not outnumber them. Real
  // notation with a typo or two passes; prose does not, with or without an
  // invented X:1 header in front of it.
  function isScore(tune, ownWarnings) {
    var notes = 0;
    (tune.lines || []).forEach(function (line) {
      (line.staff || []).forEach(function (staff) {
        (staff.voices || []).forEach(function (voice) {
          voice.forEach(function (element) {
            if (element.el_type === "note" && element.pitches
                && element.pitches.length) notes += 1;
          });
        });
      });
    });
    if (notes === 0) return false;
    var ignored = ownWarnings.filter(function (w) {
      return /Unknown character/i.test(w);
    }).length;
    return ignored <= notes;
  }

  // Draw into `el`. The report says how tall the result is and what abcjs
  // complained about. `tunes` counts the tunes that are scores by the rule
  // above; zero is the app's whole verdict on a document, so it has to mean
  // "there is no music here" and not merely "nothing was drawn".
  function draw(el, req) {
    el.innerHTML = "";
    var scale = req.scale > 0 ? req.scale : 1;
    var warnings = [];
    var tunes = 0;
    try {
      var out = ABCJS.renderAbc(el, req.abc || "", options(req, scale));
      out.forEach(function (tune) {
        var own = (tune.warnings || []).map(plain);
        if (isScore(tune, own)) tunes += 1;
        own.forEach(function (w) { warnings.push(w); });
      });
    } catch (error) {
      warnings.push(plain(error && error.message ? error.message : error));
      tunes = 0;
    }
    if (tunes === 0) {
      // Never leave a stale or half-drawn score behind a verdict of "nothing".
      el.innerHTML = "";
      el.style.height = "";
      el.style.width = "";
    } else {
      // abcjs draws every text in the foreground colour. The title, composer
      // and tempo are chrome; dimming them lets the notes carry the page.
      var chrome = ".abcjs-title, .abcjs-subtitle, .abcjs-composer, " +
                   ".abcjs-rhythm, .abcjs-tempo, .abcjs-tempo *";
      el.querySelectorAll(chrome).forEach(function (node) {
        node.setAttribute("fill", req.theme.muted);
      });
    }
    return {
      height: Math.ceil(el.getBoundingClientRect().height),
      warnings: warnings,
      tunes: tunes
    };
  }

  window.LMG = {
    render: function (req) {
      var background = req.background || "transparent";
      document.documentElement.style.background = background;
      document.body.style.background = background;
      var report = draw(document.getElementById("score"), req);
      post({ event: "rendered", height: report.height,
             warnings: report.warnings, tunes: report.tunes });
    },

    // The score as a standalone SVG document, drawn off-screen in whatever
    // theme the export asked for, so the one on screen never flickers.
    // Returns "" when nothing drew.
    svg: function (req) {
      var el = document.getElementById("export");
      var report = draw(el, req);
      var svg = el.querySelector("svg");
      var text = "";
      if (svg && report.tunes > 0) {
        var copy = svg.cloneNode(true);
        copy.setAttribute("xmlns", "http://www.w3.org/2000/svg");
        // abcjs positions the on-page SVG with an inline transform when the
        // scale is not 1; a file wants none of that, only its background.
        copy.removeAttribute("style");
        if (req.background) copy.setAttribute("style", "background:" + req.background);
        text = '<?xml version="1.0" encoding="UTF-8"?>\n' + copy.outerHTML;
      }
      el.innerHTML = "";
      return text;
    }
  };

  window.addEventListener("load", function () { post({ event: "ready" }); });
})();
