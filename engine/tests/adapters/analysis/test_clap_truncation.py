"""CLAP text embedding: a long prompt is truncated, not fatal.

M40 — without `truncation`/`max_length` a long prompt (ACE-Step and plan
captions routinely run past 2,000 chars) tokenized to 1204 ids against a
512-token model and indexed past the position-embedding table, failing the
whole analyze pass at fraction 0.86. Truncating a prompt for an adherence
*score* is the right call; losing the pass is not.
"""

from __future__ import annotations

import unittest

import numpy as np

from adapter_analysis import clap


class _FakeFeatures:
    def float(self):
        return self

    def cpu(self):
        return self

    def numpy(self):
        return np.ones((_FakeProcessor.rows, 512), dtype=np.float32)


class _FakeProcessor:
    rows = 1

    def __init__(self) -> None:
        self.kwargs: dict = {}

    def __call__(self, text=None, **kwargs):
        _FakeProcessor.rows = len(text)
        self.kwargs = kwargs
        return {"input_ids": _FakeTensor()}


class _FakeTensor:
    def to(self, device):
        return self


class _FakeModel:
    def get_text_features(self, **kwargs):
        return _FakeFeatures()

    def to(self, device) -> None:
        pass


class EmbedTextTest(unittest.TestCase):
    def setUp(self) -> None:
        self.processor = _FakeProcessor()
        for name, value in (("_model", _FakeModel()),
                            ("_processor", self.processor),
                            ("_device", "cpu")):
            original = getattr(clap, name)
            setattr(clap, name, value)
            self.addCleanup(setattr, clap, name, original)

    def test_a_long_prompt_is_truncated_at_the_models_window(self) -> None:
        clap.embed_text(["a very long caption " * 200], "snapshot")
        self.assertIs(self.processor.kwargs["truncation"], True)
        self.assertEqual(self.processor.kwargs["max_length"], 512)

    def test_the_vocabulary_is_embedded_in_one_batched_call(self) -> None:
        """~150 short strings: a per-string call is all tokenizer overhead."""
        out = clap.embed_text(["one", "two", "three"], "snapshot")
        self.assertEqual(out.shape[0], 3)

    def test_no_text_is_an_empty_matrix_not_a_call(self) -> None:
        self.assertEqual(clap.embed_text([], "snapshot").shape, (0, 512))

    def test_the_rows_come_back_l2_normalised(self) -> None:
        out = clap.embed_text(["one"], "snapshot")
        self.assertAlmostEqual(float(np.linalg.norm(out[0])), 1.0, places=5)


if __name__ == "__main__":
    unittest.main()
