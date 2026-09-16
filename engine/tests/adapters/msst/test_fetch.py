"""MSST's first-use downloads: bytes reported, cancel honoured, no residue.

Covers 11-B12. These are the biggest first-use downloads in the engine — 448
MB for the MDX23C checkpoint, 1.6 GB for the BSRNN zip — and they used to
run behind one indeterminate message with no way out: Cancel was ignored for
the whole transfer, and a cancelled 1.6 GB transfer left 1.6 GB behind.

Nothing is downloaded: `urllib.request.urlopen` is replaced.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from _fixtures import FakeResponse, Opener, Progress, megabytes
from adapter_msst import adapter as msst
from adapter_msst.adapter import _fetch
from engine_protocol.adapter import CancelledError, CancelToken

URL = "https://example.invalid/checkpoint.ckpt"


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dest = os.path.join(self.tmp.name, "weights", "model.ckpt")

    def use(self, opener) -> None:
        patch = mock.patch.object(msst.urllib.request, "urlopen", opener)
        patch.start()
        self.addCleanup(patch.stop)

    def residue(self) -> list[str]:
        d = os.path.dirname(self.dest)
        return sorted(e for e in os.listdir(d)) if os.path.isdir(d) else []

    def test_progress_reports_megabytes_against_the_content_length(self):
        """11-B12: one indeterminate message for 448 MB reads as a hang."""
        opener = Opener(FakeResponse(megabytes(3),
                                     content_length=3 << 20))
        self.use(opener)
        progress = Progress()
        _fetch(URL, self.dest, progress, "the MDX23C checkpoint")
        self.assertIn("fetching the MDX23C checkpoint — 1 MB of 3 MB",
                      progress.messages)
        self.assertIn("fetching the MDX23C checkpoint — 3 MB of 3 MB",
                      progress.messages)

    def test_a_response_without_a_content_length_still_reports_bytes(self):
        self.use(Opener(FakeResponse(megabytes(2))))
        progress = Progress()
        _fetch(URL, self.dest, progress, "the BSRNN weights")
        self.assertIn("fetching the BSRNN weights — 2 MB", progress.messages)
        self.assertFalse(any(" of " in m for m in progress.messages))

    def test_a_finished_download_lands_at_the_destination(self):
        self.use(Opener(FakeResponse(megabytes(2), content_length=2 << 20)))
        _fetch(URL, self.dest, Progress(), "the checkpoint")
        self.assertEqual(os.path.getsize(self.dest), 2 << 20)
        self.assertEqual(self.residue(), ["model.ckpt"])

    def test_a_cancel_raised_by_progress_leaves_no_part_file(self):
        """11-B12: progress_cb raises CancelledError on a cancelled job, and
        a cancelled 1.6 GB transfer must not leave 1.6 GB behind."""
        self.use(Opener(FakeResponse(megabytes(3), content_length=3 << 20)))
        with self.assertRaises(CancelledError):
            _fetch(URL, self.dest, Progress(raise_at=2), "the checkpoint")
        self.assertEqual(self.residue(), [])

    def test_a_cancel_token_stops_the_transfer_and_leaves_no_part_file(self):
        """Reporting per megabyte is also the cancel checkpoint."""
        cancel = CancelToken()
        cancel.cancel()
        self.use(Opener(FakeResponse(megabytes(3), content_length=3 << 20)))
        with self.assertRaises(CancelledError):
            _fetch(URL, self.dest, Progress(), "the checkpoint", cancel)
        self.assertEqual(self.residue(), [])

    def test_a_transfer_that_dies_mid_stream_leaves_no_part_file(self):
        class Exploding(FakeResponse):
            def read(self, n=-1):
                if len(self.blocks) < 2:
                    raise OSError("connection reset")
                return super().read(n)

        self.use(Opener(Exploding(megabytes(3), content_length=3 << 20)))
        with self.assertRaises(OSError):
            _fetch(URL, self.dest, Progress(), "the checkpoint")
        self.assertEqual(self.residue(), [])

    def test_an_already_fetched_file_is_never_re_downloaded(self):
        os.makedirs(os.path.dirname(self.dest))
        with open(self.dest, "wb") as f:
            f.write(b"already here")
        opener = Opener()
        self.use(opener)
        progress = Progress()
        _fetch(URL, self.dest, progress, "the checkpoint")
        self.assertEqual(opener.urls, [])
        self.assertEqual(progress.messages, [])

    def test_the_destination_directory_is_made_on_demand(self):
        self.use(Opener(FakeResponse(megabytes(1), content_length=1 << 20)))
        _fetch(URL, self.dest, Progress(), "the checkpoint")
        self.assertTrue(os.path.isfile(self.dest))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
