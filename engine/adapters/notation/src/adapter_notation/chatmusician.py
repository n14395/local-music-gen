"""ChatMusician: a LLaMA-2 that reads and writes ABC notation.

Plain `LlamaForCausalLM` — no vendored architecture, no remote code — which
is why it is shippable at all. Unlike text-to-music it genuinely *continues*
notation, so this is the engine the ABC round trips use when it is installed:
hand it a tune and ask for a variation and it answers in the same notation.
"""

from __future__ import annotations

from engine_protocol.adapter import CancelledError

from .abc_convert import looks_like_abc

# The instruct format the checkpoint was tuned on.
TEMPLATE = ("Human: {instruction}\n\nAssistant: ")

CONTINUE = ("Below is an ABC notation tune. Write a new piece in the same "
            "style — same key and metre — and reply with ABC notation only, "
            "starting at the X: header.\n\n{abc}")

COMPOSE = ("Write a piece of music in ABC notation matching this "
           "description: {text}. Reply with ABC notation only, starting at "
           "the X: header.")


def load(snapshot: str):
    import torch
    from transformers import AutoTokenizer, LlamaForCausalLM

    tokenizer = AutoTokenizer.from_pretrained(snapshot)
    model = LlamaForCausalLM.from_pretrained(snapshot,
                                             torch_dtype=torch.bfloat16)
    model.eval()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    try:
        model = model.to(device)
    except Exception:  # noqa: BLE001 — 13 GB on CPU is slow but not wrong
        device = "cpu"
    return {"tokenizer": tokenizer, "model": model, "device": device}


def compose(bundle: dict, prompt: str, max_tokens: int, temperature: float,
            seed: int | None, progress_cb, cancel) -> str:
    import torch
    from transformers import StoppingCriteria, StoppingCriteriaList

    tokenizer = bundle["tokenizer"]
    model = bundle["model"]
    device = bundle["device"]

    if seed is not None:
        torch.manual_seed(seed)

    instruction = (CONTINUE.format(abc=prompt) if looks_like_abc(prompt)
                   else COMPOSE.format(text=prompt))
    text = TEMPLATE.format(instruction=instruction)
    inputs = tokenizer(text, return_tensors="pt")
    inputs = {k: v.to(device) for k, v in inputs.items()}
    prompt_length = inputs["input_ids"].shape[-1]

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
            **inputs, max_new_tokens=max_tokens,
            do_sample=temperature > 0, temperature=max(0.05, temperature),
            top_p=0.9, pad_token_id=tokenizer.eos_token_id,
            stopping_criteria=StoppingCriteriaList([Tick()]))
    if state["cancelled"] or cancel.cancelled:
        raise CancelledError()
    # Only the reply: the prompt is echoed by a causal model, and returning
    # it would put the instruction into the tune.
    return tokenizer.decode(output[0][prompt_length:],
                            skip_special_tokens=True)
