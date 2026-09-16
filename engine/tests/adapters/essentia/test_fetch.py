"""Essentia's first-use downloads, and the head table they are driven from.

Covers 11-B12. The embedder and every classification head were fetched
behind one indeterminate message, so Cancel was ignored through the whole
transfer; there is no CancelToken in load(), so `progress_cb` raising on a
cancelled job is the only checkpoint — which means it has to be called.

Nothing is downloaded: `urllib.request.urlopen` is replaced.
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from _fixtures import FakeResponse, Opener, Progress, megabytes
from adapter_essentia import adapter as ess
from adapter_essentia.adapter import (BASE, HEADS, EssentiaAdapter,
                                      _head_files, _head_nodes)
from engine_protocol.adapter import CancelledError

URL = "https://essentia.upf.edu/models/x.pb"


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dest = os.path.join(self.tmp.name, "discogs-effnet-bs64-1.pb")
        self.adapter = EssentiaAdapter("essentia", {}, self.tmp.name, {})

    def use(self, opener) -> None:
        patch = mock.patch.object(ess.urllib.request, "urlopen", opener)
        patch.start()
        self.addCleanup(patch.stop)

    def residue(self) -> list[str]:
        return sorted(os.listdir(self.tmp.name))

    def test_progress_reports_megabytes_against_the_content_length(self):
        """11-B12: one message for the whole transfer reads as a hang."""
        self.use(Opener(FakeResponse(megabytes(3), content_length=3 << 20)))
        progress = Progress()
        self.adapter._fetch(URL, self.dest, progress)
        name = "discogs-effnet-bs64-1.pb"
        self.assertIn(f"fetching {name} — 1 MB of 3 MB", progress.messages)
        self.assertIn(f"fetching {name} — 3 MB of 3 MB", progress.messages)

    def test_a_response_without_a_content_length_still_reports_bytes(self):
        self.use(Opener(FakeResponse(megabytes(2))))
        progress = Progress()
        self.adapter._fetch(URL, self.dest, progress)
        self.assertTrue(any(m.endswith("— 2 MB") for m in progress.messages),
                        progress.messages)

    def test_a_finished_download_lands_at_the_destination(self):
        self.use(Opener(FakeResponse(megabytes(2), content_length=2 << 20)))
        self.adapter._fetch(URL, self.dest, Progress())
        self.assertEqual(os.path.getsize(self.dest), 2 << 20)
        self.assertEqual(self.residue(), ["discogs-effnet-bs64-1.pb"])

    def test_a_cancel_raised_by_progress_leaves_no_part_file(self):
        """11-B12: there is no CancelToken in load(), so progress_cb raising
        is the cancel — and it must not leave the transfer behind."""
        self.use(Opener(FakeResponse(megabytes(3), content_length=3 << 20)))
        with self.assertRaises(CancelledError):
            self.adapter._fetch(URL, self.dest, Progress(raise_at=2))
        self.assertEqual(self.residue(), [])

    def test_a_transfer_that_dies_mid_stream_leaves_no_part_file(self):
        class Exploding(FakeResponse):
            def read(self, n=-1):
                if len(self.blocks) < 2:
                    raise OSError("connection reset")
                return super().read(n)

        self.use(Opener(Exploding(megabytes(3), content_length=3 << 20)))
        with self.assertRaises(OSError):
            self.adapter._fetch(URL, self.dest, Progress())
        self.assertEqual(self.residue(), [])

    def test_an_already_fetched_file_is_never_re_downloaded(self):
        with open(self.dest, "wb") as f:
            f.write(b"already here")
        opener = Opener()
        self.use(opener)
        progress = Progress()
        self.adapter._fetch(URL, self.dest, progress)
        self.assertEqual(opener.urls, [])
        self.assertEqual(progress.messages, [])


class HeadTableTests(unittest.TestCase):
    def test_every_head_resolves_to_a_graph_and_its_metadata(self):
        for name in HEADS:
            with self.subTest(head=name):
                url, pb, meta = _head_files(name)
                self.assertTrue(url.startswith(BASE + "/classification-heads/"))
                self.assertTrue(url.endswith(pb))
                self.assertEqual(pb[:-3], meta[:-5])
                self.assertTrue(pb.endswith("-discogs-effnet-1.pb"))

    def test_a_head_whose_stem_differs_from_its_directory(self):
        """approachability ships 2c/3c/regression variants in one
        directory — the 2c one is the taggable yes/no."""
        url, pb, _meta = _head_files("approachability")
        self.assertIn("/approachability/", url)
        self.assertEqual(pb, "approachability_2c-discogs-effnet-1.pb")

    def test_node_names_come_from_the_heads_own_metadata(self):
        """Configuring a head with another one's names is the "not a valid
        node name" crash."""
        meta = {"schema": {"inputs": [{"name": "in:0"}],
                           "outputs": [{"name": "logits"},
                                       {"name": "out:0",
                                        "output_purpose": "predictions"}]}}
        self.assertEqual(_head_nodes("genre", meta), ("in:0", "out:0"))

    def test_metadata_too_old_to_carry_a_schema_falls_back_by_family(self):
        self.assertEqual(_head_nodes("genre", {}),
                         ("serving_default_model_Placeholder",
                          "PartitionedCall:0"))
        self.assertEqual(_head_nodes("jamendo_genre", {}),
                         ("model/Placeholder", "model/Sigmoid"))
        self.assertEqual(_head_nodes("mood_happy", {}),
                         ("model/Placeholder", "model/Softmax"))

    def test_an_unknown_head_is_named_rather_than_keyerrored(self):
        a = EssentiaAdapter("essentia", {}, "/tmp",
                            {"heads": ["mood_happy", "no_such_head"]})
        with self.assertRaises(RuntimeError) as caught:
            a._wanted_heads()
        self.assertIn("no_such_head", str(caught.exception))

    def test_an_entry_with_no_heads_setting_wants_them_all(self):
        a = EssentiaAdapter("essentia", {}, "/tmp", {})
        self.assertEqual(a._wanted_heads(), list(HEADS))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
