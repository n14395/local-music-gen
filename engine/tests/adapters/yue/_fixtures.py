"""Shared fakes for the YuE adapter tests. Never a model, never a clone."""

from __future__ import annotations

import os


class Progress:
    """A ProgressCb that records instead of reporting."""

    def __init__(self) -> None:
        self.calls: list[tuple[float | None, str]] = []

    def __call__(self, fraction, message, *, phase=None, step=None,
                 steps=None) -> None:
        self.calls.append((fraction, message))

    @property
    def messages(self) -> list[str]:
        return [m for _f, m in self.calls]


class FakeRun:
    """A stand-in for `subprocess.run` that records and does nothing.

    A real `git clone` would reach the network; the point of every load()
    test here is which branch was taken, not what the branch fetched.
    """

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append(list(cmd))

        class _Completed:
            returncode = 0
            stdout = ""
            stderr = ""

        return _Completed()

    @property
    def cloned(self) -> bool:
        return any(c[:2] == ["git", "clone"] for c in self.calls)


# The one attention line the adapter's patch looks for.
INFER_PY = (
    "import transformers\n"
    'model = from_pretrained(attn_implementation="flash_attention_2")\n'
)


def make_checkout(base: str, *, infer_py: bool = True,
                  tombstone: bool = False) -> str:
    """A YuE checkout under `base`, complete but for what is asked away."""
    repo = os.path.join(base, "YuE")
    inference = os.path.join(repo, "inference")
    os.makedirs(inference, exist_ok=True)
    if infer_py:
        with open(os.path.join(inference, "infer.py"), "w") as f:
            f.write(INFER_PY)
    with open(os.path.join(inference, "mmtokenizer.py"), "w") as f:
        f.write("# tokenizer\n")
    os.makedirs(os.path.join(inference, "mm_tokenizer_v0.2_hf"),
                exist_ok=True)
    if tombstone:
        from engine_protocol.staging import INCOMPLETE_MARKER
        open(os.path.join(repo, INCOMPLETE_MARKER), "w").close()
    return repo
