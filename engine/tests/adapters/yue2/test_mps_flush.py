"""YuE2's mid-render MPS allocator flushes.

A 303 s render died with "MPS allocated: 72.80 GiB" of which barely 8 GiB was
live — the torch MPS allocator had grown its pool to its own low watermark
(1.4x the Metal working set, 72.6 GiB on a 64 GB Mac) before it would try to
reclaim anything, and the 15 GiB of non-torch Metal allocations beside it
crossed the 88.13 GiB device ceiling. No stage leaks; the allocator simply
keeps every high-water mark it reaches, so a warm worker carried each take's
peak into the next.

So: once at the top of a take and at both stage boundaries — the moments
when the model is all that is live and the whole pool can go back — plus
every MPS_FLUSH_TOKENS tokens in each AR stage. Never inside the flow
matching solver, which was measured at 2.4x its own cost that way. That
stage's `cancelled` poll carries its step reporting instead. On CPU no
flush should fire at all.

No weights and no torch: the pipeline is a fake that drives the callbacks
upstream would, and `torch.mps.empty_cache` is a counter.
"""

import sys
import types
import unittest
from unittest import mock

import numpy
from yue2.protocol import CONTEXT

from adapter_yue2.adapter import MPS_FLUSH_TOKENS, YuE2Adapter


class FakePipe:
    """Drives the adapter's callbacks the way YuE2Pipeline does."""

    ODE_STEPS = 2

    def __init__(self, order: list[str], *, abc_tokens: int, semantic_tokens: int,
                 ode_polls: int = 5) -> None:
        self.order = order
        self.abc_tokens = abc_tokens
        self.semantic_tokens = semantic_tokens
        self.ode_polls = ode_polls
        # `generate` asks upstream how many solver steps the stage really
        # has, through its real chunk_ranges; 400 frames behind a 100-token
        # prefix is one chunk.
        self.generation_config = types.SimpleNamespace(
            ode_steps=self.ODE_STEPS, context=CONTEXT)

    def plan(self, *, request, cancelled, on_token):
        for _ in range(self.abc_tokens):
            cancelled()
            on_token("abc", 1)
        self.order.append("plan")
        return types.SimpleNamespace(truncated=False)

    def generate_semantic(self, plan, *, sampling, cancelled, on_token):
        for _ in range(self.semantic_tokens):
            cancelled()
            on_token("semantic", 1)
        self.order.append("semantic")
        return types.SimpleNamespace(
            truncated=False, tokens=list(range(400)),
            plan=types.SimpleNamespace(prefix=list(range(100)), truncated=False))

    def synthesize(self, semantic, *, cancelled):
        # Upstream polls once before the acoustic prefill and twice per ODE
        # step. Nothing else reports this stage, so the polls are where its
        # progress comes from.
        for _ in range(self.ode_polls):
            cancelled()
        self.order.append("synthesize")
        return object()

    def decode(self, latents):
        self.order.append("decode")
        return numpy.zeros((480, 2), dtype="float32")


class FlushTests(unittest.TestCase):
    def setUp(self) -> None:
        self.flushes: list[str] = []
        self.order: list[str] = []
        fake_torch = types.SimpleNamespace(
            mps=types.SimpleNamespace(
                empty_cache=lambda: (self.flushes.append("flush"),
                                     self.order.append("flush"))[0]))
        patch = mock.patch.dict(sys.modules, {"torch": fake_torch})
        patch.start()
        self.addCleanup(patch.stop)

        self.adapter = YuE2Adapter("yue2-3b", {}, "/tmp", {})

    def run_generate(self, *, device: str, abc: int, semantic: int,
                     ode_polls: int = 5) -> None:
        self.adapter._device = device
        self.adapter.pipe = FakePipe(self.order, abc_tokens=abc,
                                     semantic_tokens=semantic,
                                     ode_polls=ode_polls)
        cancel = types.SimpleNamespace(cancelled=False)
        self.progress: list[tuple] = []

        def progress_cb(fraction, message, **kw):
            self.progress.append((fraction, message, kw))

        with mock.patch("soundfile.write"), mock.patch("os.replace"):
            self.adapter.generate("techno", "la la la",
                                  {"duration_s": 60.0, "seed": 7},
                                  "/tmp/out.wav", progress_cb, cancel)

    # Take start, after the plan, after the semantic pass, after flow
    # matching: the four moments when the model is all that is live.
    BOUNDARIES = 4

    def test_the_ar_stages_flush_on_their_token_interval(self):
        """Free, and it trims each AR stage's own high-water mark before the
        boundary flush has to hand it back."""
        self.run_generate(device="mps", abc=MPS_FLUSH_TOKENS * 3,
                          semantic=MPS_FLUSH_TOKENS * 2, ode_polls=0)
        self.assertEqual(len(self.flushes), 3 + 2 + self.BOUNDARIES)

    def test_a_short_render_still_flushes_at_the_stage_boundaries(self):
        """Below one interval the token hook never fires; the boundaries are
        where the AR pass's pool is returned before the acoustic prefill."""
        self.run_generate(device="mps", abc=5, semantic=5, ode_polls=0)
        self.assertEqual(len(self.flushes), self.BOUNDARIES)

    def test_the_boundary_flushes_land_between_the_stages(self):
        """A flush after `synthesize` has already asked for its peak is too
        late — it has to be before."""
        self.run_generate(device="mps", abc=5, semantic=5, ode_polls=0)
        self.assertEqual(self.order,
                         ["flush", "plan", "flush", "semantic", "flush",
                          "synthesize", "flush", "decode"])

    def test_a_take_hands_back_the_previous_takes_pool_first(self):
        """The warm-worker vein: nothing calls unload() between takes, so the
        take itself has to open by returning what the last one peaked at."""
        self.run_generate(device="mps", abc=5, semantic=5, ode_polls=0)
        self.assertEqual(self.order[0], "flush")

    def test_flow_matching_never_flushes_inside_the_solver(self):
        """Measured at 2.4x the stage's own cost and climbing — it hands the
        pool back twice a step and the next layer asks for all of it again."""
        self.run_generate(device="mps", abc=0, semantic=0, ode_polls=7)
        self.assertEqual(len(self.flushes), self.BOUNDARIES)

    def test_flow_matching_reports_its_solver_steps(self):
        """Upstream reports this stage through a Progress object the adapter
        turns off, so 33 minutes of a 300 s render used to pass in silence."""
        self.run_generate(device="mps", abc=0, semantic=0, ode_polls=5)
        steps = [kw.get("step") for _, m, kw in self.progress
                 if m.startswith("refining to audio — step")]
        self.assertEqual(steps, [0, 1, 2])
        fractions = [f for f, m, _ in self.progress
                     if m.startswith("refining to audio — step")]
        # The stage owns 0.90 to 0.95; the VAE decode picks up from there.
        for got, want in zip(fractions, [0.9, 0.925, 0.95], strict=True):
            self.assertAlmostEqual(got, want)

    def test_the_solver_total_comes_from_upstreams_own_chunking(self):
        """One chunk of 400 frames at 2 solver steps is 2 steps, not a guess
        at the step count."""
        self.run_generate(device="mps", abc=0, semantic=0, ode_polls=5)
        totals = {kw.get("steps") for _, m, kw in self.progress
                  if m.startswith("refining to audio — step")}
        self.assertEqual(totals, {FakePipe.ODE_STEPS})

    def test_the_ar_stages_report_no_solver_steps(self):
        """The reporting is armed only for flow matching; the AR stages poll
        `cancelled` once per token and must stay on their own counter."""
        self.run_generate(device="mps", abc=200, semantic=200, ode_polls=0)
        self.assertEqual([m for _, m, _ in self.progress
                          if m.startswith("refining to audio — step")], [])

    def test_the_ar_stages_do_not_flush_on_their_cancel_polls(self):
        """Once per token would be a commit-and-wait per token; the interval
        is what keeps the flushing free."""
        self.run_generate(device="mps", abc=MPS_FLUSH_TOKENS - 1,
                          semantic=MPS_FLUSH_TOKENS - 1, ode_polls=0)
        self.assertEqual(len(self.flushes), self.BOUNDARIES)

    def test_the_gate_closes_again_after_flow_matching(self):
        """Nothing polls `cancelled` after the ODE, but the flag must not be
        left set for a warm worker's next take."""
        self.run_generate(device="mps", abc=5, semantic=5, ode_polls=2)
        before = len(self.flushes)
        self.run_generate(device="mps", abc=MPS_FLUSH_TOKENS - 1,
                          semantic=MPS_FLUSH_TOKENS - 1, ode_polls=0)
        self.assertEqual(len(self.flushes) - before, self.BOUNDARIES)

    def test_cpu_never_flushes(self):
        """There is no Metal pool to hand back, and torch.mps would raise."""
        self.run_generate(device="cpu", abc=MPS_FLUSH_TOKENS * 3,
                          semantic=MPS_FLUSH_TOKENS * 2, ode_polls=7)
        self.assertEqual(self.flushes, [])


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
