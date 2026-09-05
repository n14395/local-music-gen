"""Model catalog: curated JSON + install-state merge.

Install state is tracked with marker files (data/installed/<model_id>.json) written
after a completed download; a model with cache bytes but no marker is "partial".
"""

from __future__ import annotations

import fnmatch
import json
import os
import shutil
import time
from importlib import resources

from .config import Settings

_TEST_MODEL = {
    # Tiny public repo so verification can exercise real HF downloads in seconds.
    "id": "test-tiny",
    "family": "musicgen",
    "display_name": "Test Tiny (verification)",
    "description": "Tiny random MusicGen used by the verification suite.",
    "hf_repos": [{"repo_id": "hf-internal-testing/tiny-random-MusicgenForConditionalGeneration",
                  "gated": False}],
    # Deliberately above SMALL_MODEL_BYTES: this entry stands in for a real
    # generation model, so it must exercise the resident-slot path (the actual
    # download is a few MB — disk_bytes below keeps the disk precheck honest).
    "size_bytes": 2_000_000_000,
    "capabilities": {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": 5, "default_s": 2},
        "sample_rate": 32000, "outputs_per_job_max": 2,
        "est_seconds_per_audio_second": 1.0,
        # It runs the real musicgen adapter, so it emits that family's phases —
        # and a model whose adapter names stages the catalog never declared is
        # exactly the mismatch verify_engine's staged-progress invariant looks
        # for. Standing in for a generation model means standing in fully.
        "pipeline": [{"id": "prompt_encode", "label": "Prompt encode"},
                     {"id": "lm_decode", "label": "Token decode"},
                     {"id": "master", "label": "Master & save"}],
        "params": [{"key": "seed", "type": "int", "label": "Seed", "default": None,
                    "nullable": True, "min": 0, "max": 4294967295},
                   # exercises the upload-id → path plumbing (the non-melody
                   # musicgen adapter ignores the value)
                   {"key": "melody_audio", "type": "audio",
                    "label": "Melody reference", "default": None,
                    "nullable": True}],
    },
    "requirements": {"min_ram_bytes": 1, "disk_bytes": 10000000,
                     "speed_tier": "fast"},
    "license": {"name": "Apache-2.0", "commercial_use": True,
                "requires_hf_token": False, "url": None},
    "notes": None,
}


# Same repo as test-tiny: exercises shared-repo reference counting on delete
# (the ACE-Step DiT variants share their core package the same way).
_TEST_MODEL_SHARED = {
    **_TEST_MODEL,
    "id": "test-tiny-shared",
    "display_name": "Test Tiny Shared (verification)",
}


# Pattern-scoped download (its own repo so a full sibling download can't
# pre-populate the snapshot): only the matching files may land on disk.
_TEST_MODEL_PATTERNS = {
    **_TEST_MODEL,
    "id": "test-tiny-patterns",
    "display_name": "Test Tiny Patterns (verification)",
    "hf_repos": [{"repo_id": "hf-internal-testing/tiny-random-T5ForConditionalGeneration",
                  "gated": False,
                  "allow_patterns": ["*.json", "spiece.model"]}],
}


# Weightless task model on the real dsp family: exercises the whole task-job
# path (empty-hf_repos install, task→task_result protocol, artifacts, json
# param upload resolution, cancel) with a venv that provisions in seconds and
# runs on CPU.
_TEST_MODEL_SPLIT = {
    "id": "test-split",
    "family": "dsp",
    "display_name": "Test Split (verification)",
    "description": "Weightless dsp mixdown model used by the verification suite.",
    "hf_repos": [],
    "size_bytes": 0,
    "capabilities": {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
        "sample_rate": 44100, "outputs_per_job_max": 1,
        "est_seconds_per_audio_second": 0,
        "tasks": ["mix"],
        "params": [{"key": "mix_spec", "type": "json", "label": "Mix spec",
                    "default": None, "nullable": False,
                    "internal": True, "resolve_uploads": True},
                   {"key": "target_lufs", "type": "float", "label": "Loudness",
                    "default": -14.0, "nullable": False,
                    "min": -30.0, "max": -6.0, "step": 0.5},
                   {"key": "keep_tracks", "type": "bool", "label": "Keep tracks",
                    "default": False, "nullable": False},
                   # The Editor's side-channel params. Declared here because
                   # the supervisor DROPS anything a model does not declare
                   # (see JobQueue.submit) — a fixture missing them would let
                   # the verification suite "pass" while the worker never saw
                   # them. Kept in step with dsp-mixdown in the catalog.
                   {"key": "normalize", "type": "bool",
                    "label": "Normalize loudness", "default": True,
                    "nullable": False},
                   {"key": "limiter", "type": "bool",
                    "label": "True-peak limiter", "default": True,
                    "nullable": False},
                   {"key": "output_format", "type": "enum",
                    "label": "Output format", "default": "wav",
                    "nullable": False,
                    "choices": [{"value": v, "label": v.upper()}
                                for v in ("wav", "aiff", "flac", "mp3")]},
                   {"key": "bit_depth", "type": "enum", "label": "Bit depth",
                    "default": "pcm16", "nullable": False,
                    "choices": [{"value": "pcm16", "label": "16-bit"},
                                {"value": "pcm24", "label": "24-bit"},
                                {"value": "float32", "label": "32-bit float"}]}],
    },
    "requirements": {"min_ram_bytes": 1, "disk_bytes": 0, "speed_tier": "fast"},
    "license": {"name": "GPL-3.0", "commercial_use": True,
                "requires_hf_token": False, "url": None},
    "notes": None,
}


# Weightless entry on a family that exists nowhere: the verification suite
# points LOCALMUSICGEN_ADAPTERS_DIR at a scratch root holding one dependency-free
# `test-provision` project, which is the only way to watch a venv being built
# from cold — every real family is already synced in a dev checkout, and the
# download path skips a family it already has.
_TEST_MODEL_PROVISION = {
    **_TEST_MODEL_SPLIT,
    "id": "test-provision",
    "family": "test-provision",
    "display_name": "Test Provision (verification)",
    "description": "Weightless entry used to verify venv provisioning.",
}


def _catalog_path() -> str:
    # Repo layout: engine/catalog/models.json next to supervisor/. Packaged layout
    # (M9) ships the same relative structure inside Resources/engine/.
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.path.join(here, "..", "..", "..", "catalog", "models.json"),
        os.path.join(here, "catalog", "models.json"),
    ):
        if os.path.exists(candidate):
            return os.path.abspath(candidate)
    raise FileNotFoundError("catalog/models.json not found")


class Registry:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        with open(_catalog_path()) as f:
            models = json.load(f)["models"]
        if os.environ.get("LOCALMUSICGEN_TEST_CATALOG"):
            models = models + [_TEST_MODEL, _TEST_MODEL_SHARED,
                               _TEST_MODEL_PATTERNS, _TEST_MODEL_SPLIT,
                               _TEST_MODEL_PROVISION]
        self.models: dict[str, dict] = {m["id"]: m for m in models}
        # model_id -> (marker mtime_ns, bytes). Sizing an installed model means
        # walking its repo directories, and /v1/models asks for every entry at
        # once. A plain dict with no lock: each entry is written and read in a
        # single dict operation, which the GIL makes atomic, and the worst a
        # racing writer can do is replace one entry with an equally valid one.
        self._bytes_cache: dict[str, tuple[int, int]] = {}
        os.makedirs(self.markers_dir, exist_ok=True)
        for m in self._load_user_models():
            self.models.setdefault(m["id"], m)

    @property
    def _user_models_path(self) -> str:
        return os.path.join(self.settings.data_dir, "user_models.json")

    def _load_user_models(self) -> list[dict]:
        try:
            with open(self._user_models_path) as f:
                return json.load(f)["models"]
        except (OSError, json.JSONDecodeError, KeyError):
            return []

    def add_user_model(self, entry: dict) -> None:
        self.models[entry["id"]] = entry
        user = [m for m in self._load_user_models() if m["id"] != entry["id"]]
        user.append(entry)
        tmp = self._user_models_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"models": user}, f, indent=2)
        os.replace(tmp, self._user_models_path)

    def is_user_model(self, model_id: str) -> bool:
        return any(m["id"] == model_id for m in self._load_user_models())

    def remove_user_model(self, model_id: str) -> None:
        user = [m for m in self._load_user_models() if m["id"] != model_id]
        tmp = self._user_models_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"models": user}, f, indent=2)
        os.replace(tmp, self._user_models_path)
        self.models.pop(model_id, None)

    @property
    def markers_dir(self) -> str:
        return os.path.join(self.settings.data_dir, "installed")

    def _marker_path(self, model_id: str) -> str:
        return os.path.join(self.markers_dir, f"{model_id}.json")

    def _attempt_path(self, model_id: str) -> str:
        return os.path.join(self.markers_dir, f"{model_id}.attempt")

    # "partial" must mean *this* model's download was started and interrupted.
    # Bytes on disk can't answer that: catalog entries share repos (the ACE-Step
    # core) and even individual files (the GGUF stack's shared embedding/LM/VAE
    # quants), so a model the user never touched can have gigabytes of its
    # content already present — which showed up as a bogus "Resume download".
    def mark_attempted(self, model_id: str) -> None:
        with open(self._attempt_path(model_id), "w") as f:
            json.dump({"started_at": time.time()}, f)

    def clear_attempt(self, model_id: str) -> None:
        try:
            os.unlink(self._attempt_path(model_id))
        except FileNotFoundError:
            pass

    def was_attempted(self, model_id: str) -> bool:
        return os.path.exists(self._attempt_path(model_id))

    def repo_cache_dir(self, repo_id: str) -> str:
        return os.path.join(self.settings.hf_cache_dir, "hub",
                            "models--" + repo_id.replace("/", "--"))

    # ModelScope repos (catalog `ms_repos`, absent on most entries) live in a
    # flat per-repo directory — no blob/snapshot indirection, because nothing
    # else on the machine shares this cache. Completeness is the marker the
    # download worker writes after the last file (see ms_download_worker).
    @staticmethod
    def ms_repos(model: dict) -> list[dict]:
        return model.get("ms_repos") or []

    def ms_repo_dir(self, repo_id: str) -> str:
        return os.path.join(self.settings.ms_cache_dir,
                            "models--" + repo_id.replace("/", "--"))

    def _ms_complete(self, repo_id: str) -> bool:
        from .ms_download_worker import COMPLETE_MARKER
        return os.path.exists(os.path.join(self.ms_repo_dir(repo_id),
                                           COMPLETE_MARKER))

    def _ms_bytes(self, repo_id: str) -> int:
        total = 0
        for root, _dirs, files in os.walk(self.ms_repo_dir(repo_id)):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total

    def cache_bytes(self, model_id: str) -> int:
        """Bytes on disk that belong to THIS entry.

        Pattern-scoped repos are shared between entries wanting different files
        (the multi-quant GGUF stack), so summing the whole repo directory would
        credit an entry with its siblings' downloads — inflating its reported
        size and starting its progress bar past 100%. Match through the
        snapshot symlinks instead and size the blobs they point at.
        """
        total = 0
        for repo in self.ms_repos(self.models[model_id]):
            total += self._ms_bytes(repo["repo_id"])
        for repo in self.models[model_id]["hf_repos"]:
            d = self.repo_cache_dir(repo["repo_id"])
            pats = repo.get("allow_patterns")
            if not pats:
                for root, _dirs, files in os.walk(d):
                    for f in files:
                        p = os.path.join(root, f)
                        try:
                            if not os.path.islink(p):
                                total += os.path.getsize(p)
                        except OSError:
                            pass
                continue
            snaps = os.path.join(d, "snapshots")
            try:
                revs = os.listdir(snaps)
            except OSError:
                continue
            for rev in revs:
                base = os.path.join(snaps, rev)
                for root, _dirs, files in os.walk(base):
                    for f in files:
                        p = os.path.join(root, f)
                        rel = os.path.relpath(p, base)
                        if not any(fnmatch.fnmatch(rel, pat) for pat in pats):
                            continue
                        try:
                            total += os.path.getsize(os.path.realpath(p))
                        except OSError:
                            pass
        return total

    def write_marker(self, model_id: str, bytes_total: int) -> None:
        with open(self._marker_path(model_id), "w") as f:
            json.dump({"bytes": bytes_total}, f)

    def is_marked(self, model_id: str) -> bool:
        """Was this model's download completed? A claim about history, not
        about the bytes on disk right now — `is_installed` is the one that
        checks whether the weights are still there."""
        return os.path.exists(self._marker_path(model_id))

    def marked_bytes(self, model_id: str) -> int:
        """What the completed download recorded, or 0 if that is unreadable."""
        try:
            with open(self._marker_path(model_id)) as f:
                return int(json.load(f)["bytes"])
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
            return 0

    def remove_marker(self, model_id: str) -> None:
        try:
            os.unlink(self._marker_path(model_id))
        except FileNotFoundError:
            pass

    def is_installed(self, model_id: str) -> bool:
        # The marker alone is not proof: weights can vanish underneath it (a
        # manual cache cleanup, or historically a shared-repo delete). Trusting
        # a stale marker sends jobs to a worker with no snapshots — an opaque
        # crash instead of a "Download" button.
        if not self.is_marked(model_id):
            return False
        model = self.models[model_id]
        # ModelScope repos carry their own completeness marker, written after
        # the last file — presence of the directory alone is not enough (an
        # interrupted download leaves files behind).
        for repo in self.ms_repos(model):
            if not self._ms_complete(repo["repo_id"]):
                return False
        snaps = self.hf_snapshot_dirs(model_id)
        if len(snaps) != len(model["hf_repos"]):
            return False
        # Pattern-scoped repos (multi-quant GGUF stacks) are shared between
        # entries wanting different files, so the snapshot dir existing is not
        # enough — every requested pattern must have a match on disk.
        for repo in model["hf_repos"]:
            pats = repo.get("allow_patterns")
            if not pats:
                continue
            snap = snaps[repo["repo_id"]]
            names = []
            for root, _dirs, files in os.walk(snap):
                names += [os.path.relpath(os.path.join(root, f), snap)
                          for f in files]
            if not all(any(fnmatch.fnmatch(n, p) for n in names)
                       for p in pats):
                return False
        return True

    def family_still_wanted(self, family: str, ignoring: str | None = None) -> bool:
        """Does any downloaded model still need this family's runtime?

        Marker-based, like the shared-repo check in `delete`: a model whose
        weights are on disk needs its runtime whether or not it happens to be
        loadable this second, and `is_installed` walks the cache for every
        entry — far too much work for a question asked once per delete.
        """
        for other_id, other in self.models.items():
            if other_id == ignoring or other["family"] != family:
                continue
            if self.is_marked(other_id):
                return True
        return False

    def snapshot_dirs(self, model_id: str) -> dict[str, str]:
        """repo_id -> local dir, for handing to workers. HF repos resolve to
        their latest snapshot; ModelScope repos to their flat cache dir. One
        namespace on purpose — adapters look paths up by the repo id they
        know, and nothing about where the bytes came from changes that."""
        out = self.hf_snapshot_dirs(model_id)
        for repo in self.ms_repos(self.models[model_id]):
            d = self.ms_repo_dir(repo["repo_id"])
            if os.path.isdir(d):
                out[repo["repo_id"]] = d
        return out

    def hf_snapshot_dirs(self, model_id: str) -> dict[str, str]:
        """repo_id -> latest snapshot dir, HF repos only (the install check
        counts these against hf_repos, so ModelScope dirs must stay out)."""
        out = {}
        for repo in self.models[model_id]["hf_repos"]:
            base = os.path.join(self.repo_cache_dir(repo["repo_id"]), "snapshots")
            try:
                revs = sorted(os.listdir(base),
                              key=lambda r: os.path.getmtime(os.path.join(base, r)))
            except FileNotFoundError:
                continue
            if revs:
                out[repo["repo_id"]] = os.path.join(base, revs[-1])
        return out

    def delete(self, model_id: str) -> None:
        # Repos can be shared (the ACE-Step DiT variants all ride on the same
        # core package): only remove blobs no other installed model references.
        self.remove_marker(model_id)
        self.clear_attempt(model_id)   # deleted ≠ interrupted mid-download
        still_needed = set()
        for other_id, other in self.models.items():
            if other_id != model_id and self.is_marked(other_id):
                still_needed.update(r["repo_id"] for r in other["hf_repos"])
                still_needed.update(r["repo_id"] for r in self.ms_repos(other))
        for repo in self.models[model_id]["hf_repos"]:
            if repo["repo_id"] in still_needed:
                continue
            shutil.rmtree(self.repo_cache_dir(repo["repo_id"]), ignore_errors=True)
        for repo in self.ms_repos(self.models[model_id]):
            if repo["repo_id"] in still_needed:
                continue
            shutil.rmtree(self.ms_repo_dir(repo["repo_id"]), ignore_errors=True)

    def _installed_bytes(self, model_id: str) -> int:
        """`cache_bytes` memoised on the install marker's mtime.

        The bytes an installed model occupies cannot change while the marker
        that says its download finished stays put, and every event that could
        change them — a re-download, a repair, a delete — rewrites or removes
        that marker, so a stale answer misses the cache by construction. A
        model with no marker is not cached at all: its bytes are whatever a
        download is writing right now.
        """
        try:
            mtime = os.stat(self._marker_path(model_id)).st_mtime_ns
        except OSError:
            return self.cache_bytes(model_id)
        hit = self._bytes_cache.get(model_id)
        if hit is not None and hit[0] == mtime:
            return hit[1]
        total = self.cache_bytes(model_id)
        self._bytes_cache[model_id] = (mtime, total)
        return total

    def _any_cache_dir(self, model_id: str) -> bool:
        """Is any of this entry's repos present on disk at all?

        A few stats standing in for a walk: most of the catalog has never been
        touched on any given machine, and for those entries `cache_bytes` can
        only ever return 0 after opening every repo directory to find out.
        Shared repos mean a never-attempted entry can still have bytes on
        disk, which is why this asks about the directories rather than
        assuming from the marker.
        """
        model = self.models[model_id]
        for repo in model["hf_repos"]:
            if os.path.exists(self.repo_cache_dir(repo["repo_id"])):
                return True
        for repo in self.ms_repos(model):
            if os.path.exists(self.ms_repo_dir(repo["repo_id"])):
                return True
        return False

    def info(self, model_id: str, active_download_state: str | None = None) -> dict:
        m = dict(self.models[model_id])
        if self.is_installed(model_id):
            installed_bytes = (self.marked_bytes(model_id)
                               or self._installed_bytes(model_id))
            state = "installed"
        elif active_download_state:
            state, installed_bytes = "downloading", self.cache_bytes(model_id)
        else:
            attempted = self.was_attempted(model_id)
            installed_bytes = (self.cache_bytes(model_id)
                               if attempted or self._any_cache_dir(model_id)
                               else 0)
            state = "partial" if attempted else "not_installed"
        m["install_state"] = state
        m["installed_bytes"] = installed_bytes
        return m
