# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""text-to-music (BART): a description in, a tune in ABC out.

BART-base fine-tuned on 282k text/ABC pairs — small enough to sit in the warm
pool beside a music model, and a plain seq2seq, so it loads through
`transformers` with no vendored code and no `trust_remote_code`.

It is a *composer*, not an arranger: what comes back is a single-stave tune in
the style the words describe. Handed ABC rather than prose it will still write
something, but the model was trained on descriptions, so the ABC cards send a
description of the extracted notation rather than the notation itself.
"""

from __future__ import annotations

from engine_protocol.adapter import CancelledError

MAX_LENGTH = 1024


def load(snapshot: str):
    import torch
    from transformers import AutoTokenizer, BartForConditionalGeneration

    tokenizer = AutoTokenizer.from_pretrained(snapshot)
    model = BartForConditionalGeneration.from_pretrained(snapshot)
    model.eval()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    try:
        model = model.to(device)
    except Exception:  # noqa: BLE001 — CPU is seconds for a 0.5 GB seq2seq
        device = "cpu"
    return {"tokenizer": tokenizer, "model": model, "device": device}


def compose(bundle: dict, prompt: str, max_tokens: int, temperature: float,
            seed: int | None, progress_cb, cancel) -> str:
    import torch

    tokenizer = bundle["tokenizer"]
    model = bundle["model"]
    device = bundle["device"]

    if seed is not None:
        torch.manual_seed(seed)

    inputs = tokenizer(prompt, return_tensors="pt", truncation=True,
                       max_length=MAX_LENGTH)
    inputs = {k: v.to(device) for k, v in inputs.items()}

    # A stopping criterion is the only per-token seam `generate` offers, and
    # it is enough for both jobs it has to do here: report progress, and stop
    # when the user cancels. Cancelling this way leaves the worker and the
    # weights alive — the caller raises CancelledError once generate returns.
    from transformers import StoppingCriteria, StoppingCriteriaList

    state = {"steps": 0, "cancelled": False}

    class Tick(StoppingCriteria):
        def __call__(self, input_ids, scores, **kwargs) -> bool:
            state["steps"] += 1
            if cancel.cancelled:
                state["cancelled"] = True
                return True
            if state["steps"] % 8 == 0:
                fraction = 0.15 + 0.75 * min(state["steps"] / max_tokens, 0.98)
                progress_cb(round(fraction, 3), "writing the notation")
            return False

    with torch.no_grad():
        output = model.generate(
            **inputs, max_length=max_tokens, do_sample=temperature > 0,
            temperature=max(0.05, temperature), top_p=0.9,
            stopping_criteria=StoppingCriteriaList([Tick()]))
    if state["cancelled"] or cancel.cancelled:
        raise CancelledError()
    return tokenizer.decode(output[0], skip_special_tokens=True)
