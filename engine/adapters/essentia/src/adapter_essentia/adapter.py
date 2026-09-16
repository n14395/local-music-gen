"""Essentia model-zoo tagging: one embedding pass, many tiny heads.

The Discogs-EffNet extractor (18 MB) embeds the track once; each classifier
head is a sub-MB graph over that embedding, so genre + moods + danceability
together cost barely more than genre alone. Heads and their groupings are
declared in HEADS; `settings.heads` picks the subset a catalog entry wants.

Weights are MTG/UPF's own hosting (CC BY-NC-SA — download-at-first-use on
purpose, never re-hosted), fetched into the engine cache dir the same way the
separation family's backends fetch theirs.
"""

from __future__ import annotations

import json
import os
import urllib.request

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)

BASE = "https://essentia.upf.edu/models"
EMBED_PB = "discogs-effnet-bs64-1.pb"
EMBED_URL = f"{BASE}/feature-extractors/discogs-effnet/{EMBED_PB}"

# name -> (path spec, group, kind). "binary" heads emit their positive class
# above threshold; "multi" heads their top classes; "winner" the argmax;
# "multilabel" heads are sigmoid rather than softmax, so their scores are
# independent probabilities that do not sum to anything and need a threshold
# of their own rather than a share-of-one floor.
# The path spec is "subdir" when the file stem matches it, "subdir/stem"
# when it does not (approachability ships 2c/3c/regression variants in one
# directory — the 2c one is the taggable yes/no).
HEADS = {
    "genre": ("genre_discogs400", "genre", "multi"),
    "mood_happy": ("mood_happy", "mood", "binary"),
    "mood_sad": ("mood_sad", "mood", "binary"),
    "mood_party": ("mood_party", "mood", "binary"),
    "mood_aggressive": ("mood_aggressive", "mood", "binary"),
    "mood_relaxed": ("mood_relaxed", "mood", "binary"),
    "danceability": ("danceability", "mood", "binary"),
    "voice_instrumental": ("voice_instrumental", "instrument", "winner"),
    "mood_acoustic": ("mood_acoustic", "mood", "binary"),
    "mood_electronic": ("mood_electronic", "mood", "binary"),
    "timbre": ("timbre", "mood", "winner"),            # bright / dark
    "tonal_atonal": ("tonal_atonal", "mood", "winner"),
    "approachability": ("approachability/approachability_2c", "mood",
                        "binary"),
    "engagement": ("engagement/engagement_2c", "mood", "binary"),
    # The MTG-Jamendo heads: a second, larger vocabulary over the same
    # embedding. Where the Discogs head answers "what genre is this?" in
    # record-shop terms, these answer "what is it for, what is playing, what
    # does it feel like" in the words a music library uses — and they are
    # multi-label, so a track is allowed to be several things at once.
    "jamendo_moodtheme": ("mtg_jamendo_moodtheme", "theme", "multilabel"),
    "jamendo_genre": ("mtg_jamendo_genre", "genre", "multilabel"),
    "jamendo_instrument": ("mtg_jamendo_instrument", "instrument",
                           "multilabel"),
    "jamendo_top50": ("mtg_jamendo_top50tags", "tag", "multilabel"),
}

# Above this a sigmoid head is saying "yes". MTG's own demos read their
# multi-label heads at about this level; below it the tail is long and mostly
# noise.
MULTILABEL_FLOOR = 0.1

# The binary heads name their negative class "non_happy" / "not_danceable" /
# "not approachable"; only the positive one is ever worth a tag.
_NEGATIVE_PREFIXES = ("non_", "not_", "not ")


def _head_files(name: str) -> tuple[str, str, str]:
    spec = HEADS[name][0]
    subdir, _, stem_base = spec.partition("/")
    stem = f"{stem_base or subdir}-discogs-effnet-1"
    return (f"{BASE}/classification-heads/{subdir}/{stem}.pb",
            f"{stem}.pb", f"{stem}.json")


def _head_nodes(name: str, meta: dict) -> tuple[str, str]:
    """Input/output node names, read from the head's own metadata.

    They differ by how UPF exported each graph — genre_discogs400 is a TF2
    saved-model export (serving_default / PartitionedCall), the softmax heads
    are TF1 frozen graphs (model/Placeholder → model/Softmax), and the
    multi-label MTG-Jamendo heads are TF1 graphs ending in model/Sigmoid.
    Configuring a head with another one's names is the "not a valid node
    name" crash, so the names come from the JSON that ships beside each graph
    rather than from a rule about which family it belongs to. Every head
    marks exactly one output `predictions`; the others are logits and the
    penultimate layer.

    The hardcoded pairs remain as a fallback for a metadata file too old to
    carry a schema."""
    schema = meta.get("schema") or {}
    inputs = [i.get("name") for i in schema.get("inputs") or [] if i.get("name")]
    outputs = [o.get("name") for o in schema.get("outputs") or []
               if o.get("output_purpose") == "predictions" and o.get("name")]
    if inputs and outputs:
        return inputs[0], outputs[0]
    if HEADS[name][0].startswith("genre_discogs400"):
        return ("serving_default_model_Placeholder", "PartitionedCall:0")
    if HEADS[name][2] == "multilabel":
        return ("model/Placeholder", "model/Sigmoid")
    return ("model/Placeholder", "model/Softmax")


class EssentiaAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.embed = None
        self.heads: dict[str, tuple] = {}

    def _wanted_heads(self) -> list[str]:
        wanted = self.settings.get("heads") or list(HEADS)
        unknown = [h for h in wanted if h not in HEADS]
        if unknown:
            raise RuntimeError(f"unknown essentia heads {unknown}")
        return list(wanted)

    def _fetch(self, url: str, dest: str, progress_cb: ProgressCb) -> None:
        """Download `url` to `dest`, reporting bytes and honouring Cancel.

        This ran behind one indeterminate message for the whole transfer, so
        Cancel was ignored through a first-use fetch of the embedder and every
        head. Reporting per megabyte is also the cancel checkpoint: there is
        no CancelToken in load(), but `progress_cb` raises CancelledError on a
        cancelled job.
        """
        if os.path.exists(dest):
            return
        what = os.path.basename(dest)
        progress_cb(None, f"fetching {what} from UPF")
        part = dest + ".part"
        try:
            with urllib.request.urlopen(url, timeout=120) as resp, \
                    open(part, "wb") as f:
                length = resp.headers.get("Content-Length")
                total = int(length) if length and length.isdigit() else 0
                done = 0
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    done += len(chunk)
                    progress_cb(None, f"fetching {what} — {done >> 20} MB"
                                      + (f" of {total >> 20} MB"
                                         if total else ""))
        except BaseException:
            # A cancelled transfer must not leave its part file behind.
            try:
                os.unlink(part)
            except OSError:
                pass
            raise
        os.replace(part, dest)

    def load(self, progress_cb: ProgressCb) -> None:
        cache = aux_dir("essentia-models")
        self._fetch(EMBED_URL, os.path.join(cache, EMBED_PB), progress_cb)
        for name in self._wanted_heads():
            pb_url, pb_name, meta_name = _head_files(name)
            self._fetch(pb_url, os.path.join(cache, pb_name), progress_cb)
            self._fetch(pb_url[:-3] + ".json",
                        os.path.join(cache, meta_name), progress_cb)

        progress_cb(None, "loading the Discogs-EffNet embedder")
        import essentia.standard as es

        self.embed = es.TensorflowPredictEffnetDiscogs(
            graphFilename=os.path.join(cache, EMBED_PB),
            output="PartitionedCall:1")
        for name in self._wanted_heads():
            _url, pb_name, meta_name = _head_files(name)
            with open(os.path.join(cache, meta_name)) as f:
                meta = json.load(f)
            node_in, node_out = _head_nodes(name, meta)
            head = es.TensorflowPredict2D(
                graphFilename=os.path.join(cache, pb_name),
                input=node_in, output=node_out)
            self.heads[name] = (head, meta["classes"])
        progress_cb(None, "tagger ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "the tagger writes labels, not audio — submit a tag task instead")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "tag":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.embed is not None
        import essentia.standard as es
        import numpy as np

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        top_n = max(1, min(15, int(params.get("top_n") or 5)))

        # The embedding is 95% of the cost and pure function of the file:
        # cache it keyed on (path, size, mtime) so re-tagging — and the
        # batch card sweeping a library twice — skips straight to the heads.
        st = os.stat(src)
        emb_cache = os.path.join(aux_dir("essentia-models"), "embeddings")
        os.makedirs(emb_cache, exist_ok=True)
        import hashlib
        digest = hashlib.sha1(
            f"{src}|{st.st_size}|{int(st.st_mtime)}".encode()).hexdigest()
        emb_path = os.path.join(emb_cache, digest + ".npy")
        if os.path.exists(emb_path):
            progress_cb(0.2, "embedding cached — straight to the heads")
            embeddings = np.load(emb_path)
        else:
            progress_cb(0.05, "reading the audio")
            audio = es.MonoLoader(filename=src, sampleRate=16000,
                                  resampleQuality=4)()
            if cancel.cancelled:
                raise CancelledError()
            progress_cb(0.2, "embedding (one pass feeds every head)")
            embeddings = self.embed(audio)
            try:
                np.save(emb_path + ".part.npy", np.asarray(embeddings))
                os.replace(emb_path + ".part.npy", emb_path)
            except OSError:
                pass    # a cache miss next time, not an error now
        if cancel.cancelled:
            raise CancelledError()

        tags: list[dict] = []
        names = list(self.heads)
        for i, name in enumerate(names):
            head, classes = self.heads[name]
            preds = np.asarray(head(embeddings)).mean(axis=0)
            _subdir, group, kind = HEADS[name]
            if kind == "multi":
                for idx in np.argsort(preds)[::-1][:top_n]:
                    score = float(preds[idx])
                    if score < 0.05:
                        break
                    tags.append({"label": classes[idx],
                                 "score": round(score, 3), "group": group})
            elif kind == "multilabel":
                # Sigmoid, so the scores are independent: a track can be
                # "melancholy" and "film" and "guitar" at 0.6 each, and the
                # floor is an absolute confidence rather than a share of one.
                for idx in np.argsort(preds)[::-1][:top_n]:
                    score = float(preds[idx])
                    if score < MULTILABEL_FLOOR:
                        break
                    tags.append({"label": classes[idx],
                                 "score": round(score, 3), "group": group})
            elif kind == "binary":
                for idx, cls in enumerate(classes):
                    if cls.startswith(_NEGATIVE_PREFIXES):
                        continue
                    score = float(preds[idx])
                    if score >= 0.5:
                        tags.append({"label": cls, "score": round(score, 3),
                                     "group": group})
            else:  # winner
                idx = int(np.argmax(preds))
                tags.append({"label": classes[idx],
                             "score": round(float(preds[idx]), 3),
                             "group": group})
            progress_cb(0.2 + 0.7 * (i + 1) / len(names), f"scoring {name}")
            if cancel.cancelled:
                raise CancelledError()

        progress_cb(0.95, "writing it down")
        payload = {"text_version": 1, "kind": "tags", "text": "",
                   "tags": tags, "model": self.model_id, "engine": "essentia"}
        path = os.path.join(out_dir, "tags.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)

        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="text", label="tags", path=path,
                                format="json")],
            meta={"text": payload,
                  "top_tags": [t["label"] for t in tags[:8]]})

    def unload(self) -> None:
        self.embed = None
        self.heads = {}
