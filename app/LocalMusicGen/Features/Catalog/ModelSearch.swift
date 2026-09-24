// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a typed query matches, in one place.
///
/// Studio's model picker and the Models screen search the same catalog, and two
/// boxes over one set of data disagreeing about what counts as a hit is its own
/// small bug. This is the shared answer.
///
/// **Whitespace-separated tokens, all of which must appear somewhere.** Model
/// names here are full of punctuation and spacing — `ACE-Step 1.5 XL SFT
/// (GGUF)` — and a single substring test means "ace xl" finds nothing at all,
/// while "ace step" fails on the hyphen. For a query with no spaces this is
/// exactly a substring test, so it is never stricter than the plain `contains`
/// it replaced: strictly more forgiving, never less.
///
/// Tokens can never straddle the joins between fields, because a token is
/// whitespace-free by construction and the fields are joined with a space.
enum ModelSearch {
    static func matches(query: String, in fields: [String]) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = fields.joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
