"""YuE2's `_stage`: a clean twin of the snapshot, free of AppleDouble twins.

Covers C3. The library volume is ExFAT, which cannot carry extended
attributes, so macOS writes an AppleDouble `._X` beside every file in it.
Upstream's manifest check enumerates the folder with `Path.glob`, which —
unlike `glob.glob` — returns dot-files, finds `._model.safetensors`, has no
manifest entry for it, and refuses to load ("Weight integrity failed"). This
is why the entry had never rendered.

No weights: the "snapshot" is a temp tree of empty files, and `aux_dir` is
pointed at another temp tree.
"""

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

from adapter_yue2 import adapter as yue2
from adapter_yue2.adapter import MODEL_NEEDLE, YuE2Adapter


def touch(path: str, body: str = "") -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)


class StageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.snapshot = os.path.join(self.root, "snapshot")
        self.aux = os.path.join(self.root, "aux")
        os.makedirs(self.aux, exist_ok=True)
        patch = mock.patch.object(yue2, "aux_dir", lambda name: self.aux)
        patch.start()
        self.addCleanup(patch.stop)

    def make_snapshot(self, *, twins: bool = True) -> None:
        manifest = {"files": {"model.safetensors": "sha256:0"}}
        touch(os.path.join(self.snapshot, "model.safetensors"), "weights")
        touch(os.path.join(self.snapshot, "config.json"), "{}")
        touch(os.path.join(self.snapshot, "weights_manifest.json"),
              json.dumps(manifest))
        if twins:
            # What macOS writes onto ExFAT beside each of the above.
            for name in ("model.safetensors", "config.json",
                         "weights_manifest.json"):
                touch(os.path.join(self.snapshot, "._" + name), "\x00")

    def adapter(self) -> YuE2Adapter:
        return YuE2Adapter("yue2-3b", {"m-a-p/yue2-3b": self.snapshot},
                           self.root, {})

    def test_appledouble_twins_are_never_staged(self):
        """C3: the farm must hold `model.safetensors` and no `._` entry."""
        self.make_snapshot()
        farm = self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        entries = sorted(os.listdir(farm))
        self.assertIn("model.safetensors", entries)
        self.assertEqual([e for e in entries if e.startswith("._")], [])
        self.assertEqual(entries,
                         ["config.json", "model.safetensors",
                          "weights_manifest.json"])

    def test_the_staged_links_point_at_the_snapshots_files(self):
        self.make_snapshot()
        farm = self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        link = os.path.join(farm, "model.safetensors")
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link),
                         os.path.realpath(os.path.join(self.snapshot,
                                                       "model.safetensors")))

    def test_a_twin_that_appeared_inside_the_farm_is_swept_away(self):
        """C3: a twin of a link fails upstream's check exactly as one of a
        real file does, so anything unnamed is removed."""
        self.make_snapshot()
        farm = os.path.join(self.aux, "YuE2-3B")
        os.makedirs(farm, exist_ok=True)
        touch(os.path.join(farm, "._model.safetensors"), "\x00")
        touch(os.path.join(farm, "model-00001-of-00002.safetensors"), "old")
        got = self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        self.assertEqual(got, farm)
        self.assertEqual([e for e in os.listdir(farm)
                          if e.startswith("._")], [])
        self.assertNotIn("model-00001-of-00002.safetensors",
                         os.listdir(farm))

    def test_the_manifests_own_shards_are_staged_too(self):
        """Everything the weights manifest names, beyond STAGED_FILES."""
        touch(os.path.join(self.snapshot, "weights_manifest.json"),
              json.dumps({"files": {"shard-1.safetensors": "sha256:0"}}))
        touch(os.path.join(self.snapshot, "shard-1.safetensors"), "weights")
        touch(os.path.join(self.snapshot, "._shard-1.safetensors"), "\x00")
        farm = self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        self.assertIn("shard-1.safetensors", os.listdir(farm))
        self.assertNotIn("._shard-1.safetensors", os.listdir(farm))

    def test_a_stale_link_from_a_moved_library_is_replaced(self):
        """Links cross into an HF snapshot and a relocate strands them —
        `os.path.exists` follows the link, so a dead one reads as absent."""
        self.make_snapshot()
        farm = os.path.join(self.aux, "YuE2-3B")
        os.makedirs(farm, exist_ok=True)
        os.symlink(os.path.join(self.root, "gone", "model.safetensors"),
                   os.path.join(farm, "model.safetensors"))
        self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        link = os.path.join(farm, "model.safetensors")
        self.assertTrue(os.path.exists(link))
        self.assertEqual(os.path.realpath(link),
                         os.path.realpath(os.path.join(self.snapshot,
                                                       "model.safetensors")))

    def test_a_link_to_an_older_revision_is_repointed(self):
        self.make_snapshot()
        old = os.path.join(self.root, "old-snapshot")
        touch(os.path.join(old, "model.safetensors"), "older weights")
        farm = os.path.join(self.aux, "YuE2-3B")
        os.makedirs(farm, exist_ok=True)
        os.symlink(os.path.join(old, "model.safetensors"),
                   os.path.join(farm, "model.safetensors"))
        self.adapter()._stage(MODEL_NEEDLE, "YuE2-3B")
        self.assertEqual(
            os.path.realpath(os.path.join(farm, "model.safetensors")),
            os.path.realpath(os.path.join(self.snapshot,
                                          "model.safetensors")))

    def test_a_missing_snapshot_is_named(self):
        with self.assertRaises(RuntimeError) as caught:
            YuE2Adapter("yue2-3b", {}, self.root, {})._stage(
                MODEL_NEEDLE, "YuE2-3B")
        self.assertIn(MODEL_NEEDLE, str(caught.exception))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
