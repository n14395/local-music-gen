"""_fetch: what the user is told, and what is left behind if it goes wrong.

11-B12 — the ByteDance checkpoint used to run behind one message for the whole
172 MB, and since `progress_cb` raises CancelledError on a cancelled job,
saying nothing meant Cancel was ignored for the whole transfer. A transfer
that ends any other way than completely must take its `.part` with it.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from _fixtures import MB, FakeResponse

from adapter_transcription.adapter import _fetch


class FetchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dest = os.path.join(self.tmp.name, "note_pedal.pth")
        self.messages: list[str] = []

    def _progress(self, fraction, message, **kwargs) -> None:
        self.messages.append(message)

    def test_it_reports_megabytes_against_the_content_length(self) -> None:
        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB, MB, MB],
                                                  content_length=3 << 20)):
            _fetch("https://example.invalid/w.pth", self.dest, self._progress,
                   "the piano model")
        self.assertEqual(self.messages[0],
                         "fetching the piano model — 1 MB of 3 MB")
        self.assertEqual(self.messages[-1],
                         "fetching the piano model — 3 MB of 3 MB")

    def test_a_missing_content_length_invents_no_total(self) -> None:
        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB])):
            _fetch("https://example.invalid/w.pth", self.dest, self._progress,
                   "the piano model")
        self.assertEqual(self.messages, ["fetching the piano model — 1 MB"])

    def test_the_finished_file_lands_at_its_real_name(self) -> None:
        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB])):
            _fetch("https://example.invalid/w.pth", self.dest, self._progress,
                   "the piano model")
        self.assertTrue(os.path.exists(self.dest))
        self.assertFalse(os.path.exists(self.dest + ".part"))

    def test_a_cancel_partway_leaves_no_part_file(self) -> None:
        """11-B12: a half-written checkpoint poisons every retry."""
        calls = []

        def cancel_on_second(fraction, message, **kwargs):
            calls.append(message)
            if len(calls) == 2:
                raise KeyboardInterrupt("cancelled")

        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB, MB, MB],
                                                  content_length=3 << 20)):
            with self.assertRaises(KeyboardInterrupt):
                _fetch("https://example.invalid/w.pth", self.dest,
                       cancel_on_second, "the piano model")
        self.assertFalse(os.path.exists(self.dest + ".part"))
        self.assertFalse(os.path.exists(self.dest))


if __name__ == "__main__":
    unittest.main()
