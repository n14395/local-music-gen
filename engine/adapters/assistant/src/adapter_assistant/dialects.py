"""What each model family wants a prompt to look like.

Every generative family in this catalog reads text differently. MusicGen was
trained on short descriptive captions and ignores narrative; ACE-Step wants a
caption plus lyrics carrying explicit section tags; YuE wants a space-separated
tag string and nothing else. Handing all three the same sentence wastes two of
them.

The assistant is a 1.5B model. It does not know any of this, and it is far too
small to work it out — so the knowledge lives here as data and is pasted into
its prompt. Keyed by the *family* the target model belongs to, because that is
what the catalog already records and what actually determines the text format.

`GENERIC` is the fallback and must stay safe for an unknown family: plain
descriptive English, which every text-conditioned model handles at least
adequately.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Dialect:
    """How to write for one family.

    `guidance` goes into the system prompt verbatim, so it is written as
    instructions to the assistant, not as documentation for us. `examples` are
    few-shot anchors: at this model size they carry more weight than the prose
    above them, which is why every dialect has at least two.
    """

    name: str
    guidance: str
    examples: tuple[str, ...] = ()
    # Roughly how long a caption should run. Enforced by asking, not by
    # truncating — a hard cut mid-phrase reads worse than a slightly long line.
    target_words: tuple[int, int] = (12, 40)
    wants_lyrics: bool = False
    # Section tags the family understands. Empty means "this family has no
    # section-tag convention"; the catalog's capabilities.lyrics_tags overrides
    # this at runtime whenever the model actually declares its own.
    lyric_tags: tuple[str, ...] = ()


GENERIC = Dialect(
    name="generic",
    guidance=(
        "Write one vivid sentence describing the music. Name the instruments, "
        "the mood, the tempo feel, and the production style. Do not address "
        "the listener, do not explain your choices, and do not use the words "
        "'song about' — describe the sound itself."
    ),
    examples=(
        "warm analogue synth pad over a slow brushed-drum groove, hazy and "
        "unhurried, tape saturation on the top end",
        "driving post-punk bass with jangly reverbed guitar, urgent, live-room "
        "drums, mixed dry and close",
    ),
)


_MUSICGEN = Dialect(
    name="musicgen",
    guidance=(
        "Write a short comma-separated list of descriptors — genre, "
        "instruments, mood, tempo. This model was trained on caption-style "
        "text: it responds to descriptor lists and ignores narrative "
        "sentences. No lyrics, no song structure, no story. Keep it under 30 "
        "words."
    ),
    examples=(
        "lo-fi hip hop, dusty piano loop, vinyl crackle, laid-back boom-bap "
        "drums, mellow, 85 bpm",
        "epic orchestral trailer, staccato strings, taiko drums, brass swells, "
        "tense, building",
    ),
    target_words=(8, 30),
)


_ACESTEP = Dialect(
    name="acestep",
    guidance=(
        "Write a caption describing the production: genre, instrumentation, "
        "vocal character, mood and era. This model composes a whole song with "
        "vocals, so mention whether the voice is male, female or a group, and "
        "how it is delivered. Keep the caption to one or two lines — the "
        "lyrics carry the words, the caption carries the sound."
    ),
    examples=(
        "melancholic indie folk, fingerpicked acoustic guitar, soft male "
        "vocal, brushed drums, room reverb, autumnal",
        "high-energy k-pop, bright synth stabs, layered female group vocals, "
        "tight sidechained bass, glossy modern mix",
    ),
    wants_lyrics=True,
    lyric_tags=("[intro]", "[verse]", "[pre-chorus]", "[chorus]", "[bridge]",
                "[outro]", "[instrumental]"),
)


_YUE = Dialect(
    name="yue",
    guidance=(
        "Write a space-separated list of tags only: genre, mood, "
        "instrumentation, vocal type. No commas, no sentences, no "
        "punctuation. This model reads a tag string, not prose."
    ),
    examples=(
        "inspiring female uplifting pop airy vocal electronic bright vocal",
        "dark trap male aggressive vocal heavy 808 minor key",
    ),
    target_words=(4, 12),
    wants_lyrics=True,
    lyric_tags=("[verse]", "[chorus]", "[bridge]"),
)


_STABLEAUDIO = Dialect(
    name="stableaudio",
    guidance=(
        "Write a production-oriented description: genre, instruments, mood, "
        "and — where it matters — an explicit tempo in BPM. This model "
        "responds well to studio language (dry, saturated, wide, close-mic'd) "
        "and to named tempos. It is strongest on instrumental music, loops "
        "and sound design rather than full songs with vocals."
    ),
    examples=(
        "128 bpm deep house, rolling sub bass, filtered chord stabs, crisp "
        "hi-hats, warm analogue master",
        "cinematic ambient drone, bowed metal, low rumble, wide stereo field, "
        "no percussion",
    ),
)


_MAGNET = Dialect(
    name="audiocraft",
    guidance=(
        "Write a compact comma-separated descriptor list — genre, "
        "instruments, mood. This family renders fixed-length clips and reads "
        "caption-style text, so keep it tight and concrete. No lyrics, no "
        "structure."
    ),
    examples=(
        "funky drum break, tight snare, dry room, syncopated, 100 bpm",
        "warm jazz trio, upright bass, brushed kit, soft rhodes, late night",
    ),
    target_words=(6, 24),
)


_MINIMAX = Dialect(
    name="minimax",
    guidance=(
        "Write a caption describing genre, mood, instrumentation and vocal "
        "style. This model writes complete songs and decides its own length "
        "from the lyrics, so the lyrics matter more than the caption — keep "
        "the caption to one line of sound description."
    ),
    examples=(
        "soulful modern r&b, electric piano, finger-snap percussion, intimate "
        "female vocal, warm and close",
        "stadium rock anthem, overdriven guitars, big live drums, male vocal "
        "with grit, wide and loud",
    ),
    wants_lyrics=True,
    lyric_tags=("[intro]", "[verse]", "[chorus]", "[bridge]", "[outro]",
                "[instrumental]"),
)


_BY_FAMILY: dict[str, Dialect] = {
    "musicgen": _MUSICGEN,
    "acestep": _ACESTEP,
    "acestepcpp": _ACESTEP,
    "yue": _YUE,
    "stableaudio": _STABLEAUDIO,
    "stableaudio3": _STABLEAUDIO,
    "diffusers": _STABLEAUDIO,
    "audiocraft": _MAGNET,
    "minimax": _MINIMAX,
    "mlxaudio": _MINIMAX,
}


def for_family(family: str | None) -> Dialect:
    """The dialect for a family id, falling back to plain English.

    Unknown families are expected: the catalog gains entries faster than this
    table does, and a user-added model can name a family we have never seen.
    """
    if not family:
        return GENERIC
    return _BY_FAMILY.get(family.strip().lower(), GENERIC)


def describe(dialect: Dialect, *, lyric_tags: list[str] | None = None) -> str:
    """Render a dialect as the prompt fragment the assistant actually reads.

    `lyric_tags` comes from the target model's own `capabilities.lyrics_tags`
    when it declares them. Preferring that over the table is the whole point:
    the catalog is generated from the models themselves, so it is right when
    this file has drifted.
    """
    lines = [dialect.guidance]
    lo, hi = dialect.target_words
    lines.append(f"Aim for roughly {lo}-{hi} words.")
    tags = [t for t in (lyric_tags or []) if t] or list(dialect.lyric_tags)
    if tags:
        lines.append(
            "Section tags this model understands, to be used on their own "
            "line above the lines they introduce: " + " ".join(tags))
    if dialect.examples:
        lines.append("Examples of good output for this model:")
        lines.extend(f"  - {e}" for e in dialect.examples)
    return "\n".join(lines)
