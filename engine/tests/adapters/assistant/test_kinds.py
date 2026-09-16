"""assistant.kinds and .dialects: the prompt half of one assist call.

Covers 11-B8 (the declared 64…2048 token range that nothing enforced) and
the invariants the app relies on when it renders a kind's answer.
"""

import sys
import unittest

from adapter_assistant.adapter import clamp_max_tokens
from adapter_assistant.dialects import GENERIC, describe, for_family
from adapter_assistant.kinds import KINDS, build_messages


class MaxTokensTests(unittest.TestCase):
    def test_minus_one_is_clamped_to_the_floor(self):
        """11-B8: mlx_lm reads -1 as an infinite generator.

        The job ran to EOS with no ceiling and the bar sat at 0.95
        (produced / max(1, -1)).
        """
        self.assertEqual(clamp_max_tokens(-1, 700), 64)

    def test_a_huge_request_is_clamped_to_the_ceiling(self):
        """11-B8: the catalog declares 2048 and nothing enforced it."""
        self.assertEqual(clamp_max_tokens(500000, 700), 2048)

    def test_an_omitted_value_uses_the_kinds_own(self):
        """11-B8: absent means "whatever this kind asked for"."""
        self.assertEqual(clamp_max_tokens(None, 1100), 1100)
        self.assertEqual(clamp_max_tokens(0, 600), 600)

    def test_a_value_inside_the_range_survives(self):
        self.assertEqual(clamp_max_tokens(900, 700), 900)


class KindTests(unittest.TestCase):
    def test_every_kinds_max_tokens_is_inside_the_declared_range(self):
        """11-B8: the clamp and the kinds' own defaults must agree."""
        for kind_id, kind in KINDS.items():
            with self.subTest(kind=kind_id):
                self.assertGreaterEqual(kind.max_tokens, 64)
                self.assertLessEqual(kind.max_tokens, 2048)
                self.assertEqual(clamp_max_tokens(None, kind.max_tokens),
                                 kind.max_tokens)

    def test_every_kind_is_keyed_by_its_own_id(self):
        for kind_id, kind in KINDS.items():
            self.assertEqual(kind_id, kind.id)

    def test_every_required_key_appears_in_the_shape_shown_to_the_model(self):
        """The schema in the prompt and the one the parser enforces drift
        apart the moment they disagree — which reads as "it is broken"."""
        for kind_id, kind in KINDS.items():
            with self.subTest(kind=kind_id):
                for key in kind.required:
                    self.assertIn(key, kind.shape)

    def test_every_may_be_empty_key_is_also_required(self):
        for kind_id, kind in KINDS.items():
            with self.subTest(kind=kind_id):
                for key in kind.may_be_empty:
                    self.assertIn(key, kind.required)

    def test_every_kind_builds_messages_from_an_empty_input(self):
        """The app sends whatever the user has typed, which is often
        nothing; no kind may raise on that."""
        for kind_id, kind in KINDS.items():
            with self.subTest(kind=kind_id):
                messages = build_messages(kind, {}, GENERIC, None)
                self.assertEqual([m["role"] for m in messages],
                                 ["system", "user"])
                # The shape goes last, immediately before the first token.
                self.assertTrue(messages[1]["content"].rstrip().endswith("}"))

    def test_the_dialect_block_is_in_the_system_prompt_only_when_wanted(self):
        with_dialect = build_messages(KINDS["lyrics"], {}, GENERIC, None)
        without = build_messages(KINDS["name_and_tag"], {}, GENERIC, None)
        self.assertIn("reads text like this", with_dialect[0]["content"])
        self.assertNotIn("reads text like this", without[0]["content"])


class DialectTests(unittest.TestCase):
    def test_an_unknown_family_falls_back_to_plain_english(self):
        """The catalog gains entries faster than the table does."""
        self.assertIs(for_family("no-such-family"), GENERIC)
        self.assertIs(for_family(None), GENERIC)
        self.assertIs(for_family(""), GENERIC)

    def test_a_family_id_is_matched_case_and_space_insensitively(self):
        self.assertIs(for_family("  YuE  "), for_family("yue"))

    def test_the_acestep_family_group_shares_one_dialect(self):
        """diffsynthace's XL entries ARE ACE-Step 1.5 through another
        runtime; they fell back to plain English only because the table is
        keyed by family id."""
        acestep = for_family("acestep")
        self.assertIs(for_family("acestepcpp"), acestep)
        self.assertIs(for_family("diffsynthace"), acestep)

    def test_describe_names_the_word_budget_and_the_examples(self):
        text = describe(GENERIC)
        self.assertIn("Aim for roughly 12-40 words.", text)
        self.assertIn("Examples of good output", text)

    def test_a_family_with_no_caption_is_not_asked_for_zero_words(self):
        """(0, 0) means "there is no caption to length"; printing
        "roughly 0-0 words" is an instruction to write nothing."""
        vampnet = for_family("vampnet")
        self.assertEqual(vampnet.target_words, (0, 0))
        self.assertNotIn("0-0 words", describe(vampnet))

    def test_the_models_own_lyric_tags_win_over_the_table(self):
        """The catalog is generated from the models, so it is right when
        this file has drifted."""
        text = describe(for_family("acestep"), lyric_tags=["[hook]"])
        self.assertIn("[hook]", text)
        self.assertNotIn("[pre-chorus]", text)

    def test_an_empty_tag_list_falls_back_to_the_table(self):
        text = describe(for_family("acestep"), lyric_tags=[])
        self.assertIn("[chorus]", text)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
