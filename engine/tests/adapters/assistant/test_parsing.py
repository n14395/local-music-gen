"""assistant.parsing: getting a JSON object back out of a 1.5B model.

Covers M39 and 11-B2 — a finished interview scored as a malformed answer,
which bought a second cold generation and then reported the finished
interview to the app as `ok: false`.
"""

import sys
import unittest

from adapter_assistant.kinds import KINDS
from adapter_assistant.parsing import extract, satisfies


class SatisfiesTests(unittest.TestCase):
    def test_a_finished_interview_is_not_a_malformed_answer(self):
        """M39/11-B2: the interview's documented exit is an empty list.

        `{"questions": []}` means "I know enough now"; it used to score as
        absence, so the app was handed `ok: false` and raw JSON where it
        meant to say "press Write the description".
        """
        kind = KINDS["interview"]
        self.assertIn("questions", kind.may_be_empty)
        self.assertTrue(satisfies({"questions": [], "ready": True},
                                  kind.required, kind.may_be_empty))

    def test_an_empty_string_is_still_absence_for_a_may_be_empty_key(self):
        """M39: the shape asks for a list; `""` is a model that fell apart."""
        kind = KINDS["interview"]
        self.assertFalse(satisfies({"questions": ""}, kind.required,
                                   kind.may_be_empty))

    def test_an_empty_value_without_may_be_empty_is_absence(self):
        """M39: emptiness counts as absence for every ordinary key."""
        self.assertFalse(satisfies({"prompt": ""}, ("prompt",)))
        self.assertFalse(satisfies({"variations": []}, ("variations",)))

    def test_a_missing_required_key_is_absence(self):
        self.assertFalse(satisfies({"title": "x"}, ("prompt",)))
        self.assertFalse(satisfies({"prompt": None}, ("prompt",)))

    def test_a_present_required_key_satisfies(self):
        self.assertTrue(satisfies({"prompt": "a hazy waltz"}, ("prompt",)))

    def test_a_non_dict_never_satisfies(self):
        self.assertFalse(satisfies(None, ("prompt",)))
        self.assertFalse(satisfies([{"prompt": "x"}], ("prompt",)))


class ExtractTests(unittest.TestCase):
    def test_a_bare_object_is_returned(self):
        self.assertEqual(extract('{"prompt": "a waltz"}'),
                         {"prompt": "a waltz"})

    def test_a_markdown_fence_is_unwrapped(self):
        self.assertEqual(extract('Sure!\n```json\n{"a": 1}\n```\nEnjoy.'),
                         {"a": 1})

    def test_a_preamble_and_a_trailing_line_are_ignored(self):
        self.assertEqual(
            extract('Here you go:\n{"a": 1}\nHope that helps!'), {"a": 1})

    def test_a_trailing_comma_is_repaired(self):
        self.assertEqual(extract('{"a": 1, "b": 2,}'), {"a": 1, "b": 2})

    def test_a_think_block_is_stripped(self):
        self.assertEqual(extract('<think>hmm</think>{"a": 1}'), {"a": 1})

    def test_braces_inside_a_string_do_not_end_the_object(self):
        """Section tags and lyrics carry braces; a regex would cut early."""
        self.assertEqual(extract('{"lyrics": "[verse] a } b", "n": 1}'),
                         {"lyrics": "[verse] a } b", "n": 1})

    def test_an_object_truncated_by_the_token_ceiling_is_closed(self):
        got = extract('{"prompt": "a hazy waltz", "title": "Dust"')
        self.assertEqual(got, {"prompt": "a hazy waltz", "title": "Dust"})

    def test_a_bare_array_is_wrapped_rather_than_discarded(self):
        self.assertEqual(extract('[1, 2]'), {"items": [1, 2]})

    def test_prose_with_no_object_yields_nothing(self):
        self.assertIsNone(extract("I would write a cheerful waltz."))
        self.assertIsNone(extract(""))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
