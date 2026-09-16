"""ensure_soundfont: a cancel is not a source being down.

10-B7 — CancelledError subclasses Exception, so the old `isinstance(e,
Exception)` check swallowed it: a cancel during the download was recorded as a
dead source, the mirror was tried, and the job failed with "could not fetch
the SoundFont from any source — host: ; host: " (str(CancelledError()) is
empty).
"""

from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

from _fixtures import MB, FakeResponse

from adapter_notesynth.render_midi import SOUNDFONT_NAME, ensure_soundfont
from engine_protocol.adapter import CancelledError


class EnsureSoundfontTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = mock.patch.dict(
            os.environ, {"LOCALMUSICGEN_AUX_CACHE": self.tmp.name})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.cache = os.path.join(self.tmp.name, "localmusic-soundfonts")

    def test_a_cancel_mid_download_propagates_as_a_cancel(self) -> None:
        """10-B7: not "the host is down"."""
        def cancel_now(fraction, message, **kwargs):
            raise CancelledError()

        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB, MB])):
            with self.assertRaises(CancelledError):
                ensure_soundfont(cancel_now)

    def test_a_cancel_never_reaches_the_mirror(self) -> None:
        """10-B7: the second source is not tried after the user said stop."""
        def cancel_now(fraction, message, **kwargs):
            raise CancelledError()

        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB, MB])) as urlopen:
            with self.assertRaises(CancelledError):
                ensure_soundfont(cancel_now)
        self.assertEqual(urlopen.call_count, 1)

    def test_a_cancel_leaves_no_part_file(self) -> None:
        def cancel_now(fraction, message, **kwargs):
            raise CancelledError()

        with mock.patch("urllib.request.urlopen",
                        return_value=FakeResponse([MB, MB])):
            with self.assertRaises(CancelledError):
                ensure_soundfont(cancel_now)
        self.assertFalse(
            os.path.exists(os.path.join(self.cache, SOUNDFONT_NAME + ".part")))

    def test_a_dead_host_does_fall_through_to_the_mirror(self) -> None:
        """The other half of 10-B7: a real failure still tries source two."""
        with mock.patch("urllib.request.urlopen",
                        side_effect=[OSError("connection refused"),
                                     FakeResponse([MB])]) as urlopen:
            with self.assertRaises(OSError) as caught:
                ensure_soundfont(None)
        self.assertEqual(urlopen.call_count, 2)
        self.assertIn("connection refused", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
