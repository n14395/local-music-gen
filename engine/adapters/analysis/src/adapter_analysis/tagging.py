"""Zero-shot genre / mood / instrument tagging with CLAP.

No tagging model is trained here: CLAP already puts audio and text in one
space, so scoring a track against a vocabulary of labels is a cosine per
label. That makes the vocabulary — not a checkpoint — the thing worth
curating, and lets the same 0.6 GB encoder that computes timbre embeddings do
this job as well.

Prompts, not bare words. "techno" alone embeds as the *word*; "a techno
track" embeds as the music, and the separation between right and wrong
labels roughly doubles. Each group has its own template for the same reason.
"""

from __future__ import annotations

import numpy as np

GENRES = [
    "rock", "pop", "hip hop", "rap", "techno", "house", "trance",
    "drum and bass", "dubstep", "ambient", "classical", "orchestral",
    "jazz", "blues", "soul", "funk", "disco", "reggae", "dub", "ska",
    "country", "folk", "bluegrass", "metal", "heavy metal", "punk",
    "hardcore", "indie rock", "shoegaze", "post-rock", "grunge",
    "electronic", "synthwave", "lo-fi hip hop", "chillout", "downtempo",
    "trip hop", "garage", "grime", "afrobeat", "latin", "salsa", "bossa nova",
    "samba", "flamenco", "tango", "gospel", "r&b", "new age", "world music",
    "experimental", "noise", "industrial", "gothic", "chiptune", "video game",
    "film score", "musical theatre", "opera", "choral", "marching band",
]

MOODS = [
    "happy", "sad", "melancholy", "euphoric", "uplifting", "dark", "eerie",
    "menacing", "aggressive", "angry", "calm", "peaceful", "relaxing",
    "dreamy", "hypnotic", "nostalgic", "romantic", "tender", "playful",
    "quirky", "epic", "triumphant", "heroic", "tense", "suspenseful",
    "mysterious", "hopeful", "bittersweet", "lonely", "energetic", "driving",
    "laid back", "groovy", "danceable", "chaotic", "sparse", "lush",
    "warm", "cold", "gritty", "polished", "psychedelic",
]

INSTRUMENTS = [
    "electric guitar", "acoustic guitar", "distorted guitar", "bass guitar",
    "double bass", "synthesizer", "synth bass", "analog synth", "piano",
    "electric piano", "rhodes piano", "organ", "hammond organ", "harpsichord",
    "accordion", "drum kit", "drum machine", "808 drums", "percussion",
    "congas", "tabla", "hand claps", "tambourine", "violin", "viola", "cello",
    "string section", "harp", "flute", "clarinet", "oboe", "bassoon",
    "saxophone", "trumpet", "trombone", "french horn", "brass section",
    "male vocals", "female vocals", "choir", "vocal harmonies", "spoken word",
    "rapping", "whistling", "banjo", "mandolin", "ukulele", "sitar",
    "steel drums", "marimba", "vibraphone", "bells", "music box",
    "field recording", "vinyl crackle", "white noise",
]

# One template per group: the same label reads differently as a genre, a
# feeling and a thing being played.
_TEMPLATES = {
    "genre": "a {} track",
    "mood": "{} music",
    "instrument": "music featuring {}",
}

_GROUPS = (("genre", GENRES), ("mood", MOODS), ("instrument", INSTRUMENTS))

# Text embeddings are stable for the life of the worker and the vocabularies
# never change, so the ~150 encodes happen once per worker rather than once
# per job. The warm pool keeps this worker alive between jobs on purpose.
_cache: dict[str, np.ndarray] = {}


def _vectors(group: str, labels: list[str], snapshot: str) -> np.ndarray:
    key = f"{group}:{snapshot}"
    cached = _cache.get(key)
    if cached is not None:
        return cached
    from . import clap

    template = _TEMPLATES[group]
    vectors = clap.embed_text([template.format(label) for label in labels],
                              snapshot)
    _cache[key] = vectors
    return vectors


def zero_shot(audio_vector: list[float], snapshot: str, top_k: int = 5,
              progress_cb=None, check=None) -> list[dict]:
    """Top-k labels per group, scored by cosine against the audio.

    Returns the flat list the text payload carries:
    `[{"label", "score", "group"}]`, best first within each group, groups in
    vocabulary order (genre, mood, instrument) so the app can render them as
    three rows without sorting.

    Raw cosines, deliberately: a softmax over one group would make the top
    label's score depend on how many rivals the vocabulary happens to list,
    and the app's threshold ("confident enough to become a tag") has to mean
    the same thing whatever the group.
    """
    query = np.asarray(audio_vector, dtype=np.float32)
    norm = float(np.linalg.norm(query))
    if norm > 1e-9:
        query = query / norm

    tags: list[dict] = []
    for index, (group, labels) in enumerate(_GROUPS):
        if progress_cb is not None:
            progress_cb(0.2 + 0.7 * index / len(_GROUPS),
                        f"scoring {group} labels")
        if check is not None:
            check()
        vectors = _vectors(group, labels, snapshot)
        scores = vectors @ query
        best = np.argsort(-scores)[:max(1, top_k)]
        for position in best:
            tags.append({"label": labels[int(position)],
                         "score": round(float(scores[int(position)]), 4),
                         "group": group})
    return tags


def prompt_score(audio_vector: list[float], prompt: str,
                 snapshot: str) -> float | None:
    """Cosine between a prompt and the audio — "did it land?", as a number.

    No template: the prompt is already the sentence someone wrote to ask for
    this music, and dressing it up would score a rephrasing of their words
    rather than their words.
    """
    text = (prompt or "").strip()
    if not text:
        return None
    from . import clap

    query = np.asarray(audio_vector, dtype=np.float32)
    norm = float(np.linalg.norm(query))
    if norm > 1e-9:
        query = query / norm
    vector = clap.embed_text([text], snapshot)
    if vector.shape[0] == 0:
        return None
    return round(float(vector[0] @ query), 4)
