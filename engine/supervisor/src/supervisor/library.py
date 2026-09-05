"""The model library: where weights live, and which of them are ours.

Weights sit in three roots, and the difference between them is the difference
between a folder we borrow and folders we own:

  * The **Hugging Face cache** — `HF_HOME`, by default `~/.cache/huggingface`.
    Not ours. It is shared with every other Hugging Face tool on the machine,
    and a folder full of repos we never asked for is the normal case rather
    than the exception. So every figure and every destructive act against it is
    scoped through the catalog: a repo counts as ours when some entry in
    `Registry.models` names it in `hf_repos`, and nothing else in that folder
    is read, measured, moved or removed.
  * The **aux root** — weights adapters fetch themselves, from direct URLs,
    torch hub or source tarballs (`engine_protocol.adapter.AUX_DIRS` names
    every directory). Ours outright, so all of it counts. It relocates with the
    library folder, because it holds real gigabytes. A second class lives
    beside them, `AUX_KEPT_DIRS`: the user's own files — downloaded amp
    captures — which are counted and always moved, and which no clear and no
    relocate disposition ever deletes.
  * The **ModelScope root** — `ms_repos`, engine-owned and *not* relocatable:
    there is no ModelScope tooling on the machine to share a location with, and
    keeping it in the data dir means wiping that dir is still a clean slate.
    Counted here, never moved.

Two states of "ours", because the difference matters to the user:

  * **installed** — some entry referencing this repo has an install marker.
  * **partial** — bytes on disk from a download that was interrupted, with no
    finished model to show for them. These are still ours and still occupy the
    disk, so they are counted, moved and cleared like anything else; a size
    that ignored them could never reach zero after a clear, which is the one
    property that makes the number worth printing.

Sizes are deduplicated by inode. A cached repo is `blobs/` plus a `snapshots/`
tree of symlinks into it, and several catalog entries can share one repo (the
ACE-Step DiT variants ride on the same core package), so anything that adds up
file sizes naively reports a library half again as large as the disk it sits
on.
"""

from __future__ import annotations

import os
import shutil
import threading
import time
import uuid
from dataclasses import dataclass, field

from engine_protocol.adapter import AUX_DIRS, AUX_KEPT_DIRS
from engine_protocol.staging import INCOMPLETE_MARKER

from .events import EventBus
from .registry import Registry

# Dispositions for the models already in the folder being left behind.
DISPOSITIONS = ("move", "delete", "leave")

# The aux root's name inside a chosen library folder. Only used when the folder
# is not the shared default — see `aux_destination`.
AUX_FOLDER_NAME = "localmusic-aux"


class LibraryError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


@dataclass
class RepoOnDisk:
    """One of our repos, as it exists in the current library folder."""

    repo_id: str
    path: str
    bytes: int
    installed: bool
    model_ids: list[str] = field(default_factory=list)

    def info(self) -> dict:
        return {"repo_id": self.repo_id, "path": self.path, "bytes": self.bytes,
                "state": "installed" if self.installed else "partial",
                "model_ids": sorted(self.model_ids)}


@dataclass
class DirOnDisk:
    """One directory in a root we own outright — an aux cache directory, or a
    ModelScope repo. No install marker and so no installed/partial split: the
    adapter that fetched it is the only thing that knows what "complete" means
    for it, and every byte counts either way."""

    name: str
    path: str
    bytes: int
    #: The user's own files (AUX_KEPT_DIRS), which a clear must not take.
    kept: bool = False

    def info(self) -> dict:
        return {"name": self.name, "path": self.path, "bytes": self.bytes,
                "kept": self.kept}


def dir_bytes(path: str) -> int:
    """Bytes a directory holds, counting each inode once and following no
    symlinks. See the module docstring for why both of those matter."""
    total = 0
    seen: set[tuple[int, int]] = set()
    for root, _dirs, files in os.walk(path, followlinks=False):
        for name in files:
            p = os.path.join(root, name)
            if os.path.islink(p):
                continue
            try:
                st = os.stat(p, follow_symlinks=False)
            except OSError:
                continue
            key = (st.st_dev, st.st_ino)
            if key in seen:
                continue
            seen.add(key)
            total += st.st_size
    return total


class LibraryManager:
    """Reads and rearranges the model library. One operation at a time."""

    def __init__(self, registry: Registry, bus: EventBus, state) -> None:
        self.registry = registry
        self.bus = bus
        # EngineState, for the busy checks and for delete_model (which also
        # collects a family's runtime venv once its last model goes).
        self.state = state
        self.lock = threading.Lock()
        self.operation: dict | None = None
        self._cancel = threading.Event()

    # MARK: reading

    @property
    def root(self) -> str:
        return self.registry.settings.hf_cache_dir

    @property
    def aux_root(self) -> str:
        return self.registry.settings.aux_cache_dir

    @property
    def ms_root(self) -> str:
        return self.registry.settings.ms_cache_dir

    def _repo_owners(self) -> dict[str, list[str]]:
        """repo_id -> the catalog entries that want it. This mapping is the
        whole definition of "ours"; anything not in it is someone else's."""
        owners: dict[str, list[str]] = {}
        for model_id, model in self.registry.models.items():
            for repo in model.get("hf_repos") or []:
                owners.setdefault(repo["repo_id"], []).append(model_id)
        return owners

    def repos_on_disk(self) -> list[RepoOnDisk]:
        """Our repos that actually have bytes in the current library folder."""
        out = []
        for repo_id, model_ids in sorted(self._repo_owners().items()):
            path = self.registry.repo_cache_dir(repo_id)
            if not os.path.isdir(path):
                continue
            size = dir_bytes(path)
            if size == 0 and not os.listdir(path):
                continue
            installed = any(self.registry.is_marked(m) for m in model_ids)
            out.append(RepoOnDisk(repo_id=repo_id, path=path, bytes=size,
                                  installed=installed, model_ids=model_ids))
        return out

    def aux_dirs_on_disk(self) -> list[DirOnDisk]:
        """Aux directories that actually have bytes. Scanned by name rather
        than by listing the root: an unlisted directory there is not something
        we put in it, and this is the same "ours is what the code names" line
        the Hugging Face side holds.

        Both kinds are returned — engine caches and the user's kept files —
        because both are counted and both move. Only the clear tells them
        apart.
        """
        out = []
        for name in sorted(AUX_DIRS + AUX_KEPT_DIRS):
            path = os.path.join(self.aux_root, name)
            if not os.path.isdir(path):
                continue
            size = dir_bytes(path)
            if size == 0 and not os.listdir(path):
                continue
            out.append(DirOnDisk(name=name, path=path, bytes=size,
                                 kept=name in AUX_KEPT_DIRS))
        return out

    def ms_dirs_on_disk(self) -> list[DirOnDisk]:
        """ModelScope repos of ours with bytes on disk."""
        out = []
        seen: set[str] = set()
        for model in self.registry.models.values():
            for repo in self.registry.ms_repos(model):
                repo_id = repo["repo_id"]
                if repo_id in seen:
                    continue
                seen.add(repo_id)
                path = self.registry.ms_repo_dir(repo_id)
                if not os.path.isdir(path):
                    continue
                size = dir_bytes(path)
                if size == 0 and not os.listdir(path):
                    continue
                out.append(DirOnDisk(name=repo_id, path=path, bytes=size))
        return sorted(out, key=lambda d: d.name)

    def _aux_inside_library(self) -> bool:
        root = os.path.realpath(self.root)
        return os.path.realpath(self.aux_root).startswith(root + os.sep)

    def info(self) -> dict:
        """Everything the Settings group draws, in one request.

        `folder_bytes` is deliberately beside `bytes`: in the shared default
        the two differ by whatever other Hugging Face tooling has cached there,
        and a single "size" figure that silently disagrees with the Finder is
        the kind of number people stop trusting. Naming both explains the gap.

        `bytes` and `folder_bytes` stay scoped to the Hugging Face folder for
        the same reason — they exist to explain that gap, and there is no gap
        to explain in a root we own. The other two roots are reported beside
        them, and `total_bytes` is the honest answer to "how much disk is this
        app's models".
        """
        repos = self.repos_on_disk()
        installed = [r for r in repos if r.installed]
        partial = [r for r in repos if not r.installed]
        aux = self.aux_dirs_on_disk()
        ms = self.ms_dirs_on_disk()
        aux_bytes = sum(d.bytes for d in aux)
        ms_bytes = sum(d.bytes for d in ms)
        try:
            usage = shutil.disk_usage(_nearest_existing(self.root))
            total, free = usage.total, usage.free
        except OSError:
            total = free = None
        model_ids = {m for r in installed for m in r.model_ids
                     if self.registry.is_marked(m)}
        return {
            "path": self.root,
            "is_default": os.path.realpath(self.root) == os.path.realpath(
                os.path.expanduser("~/.cache/huggingface")),
            "bytes": sum(r.bytes for r in repos),
            "installed_bytes": sum(r.bytes for r in installed),
            "partial_bytes": sum(r.bytes for r in partial),
            # The whole folder, ours and everyone else's — see the docstring.
            "folder_bytes": dir_bytes(self.root) if os.path.isdir(self.root) else 0,
            "model_count": len(model_ids),
            "partial_count": len(partial),
            "disk_total_bytes": total,
            "disk_free_bytes": free,
            "repos": [r.info() for r in repos],
            # Roots we own outright. Every byte in them is ours, so there is no
            # `folder_bytes` counterpart to report.
            "aux": {"path": self.aux_root, "bytes": aux_bytes,
                    # After a relocate the aux root sits inside the library
                    # folder, so `folder_bytes` counts it. Without this flag a
                    # client subtracting ours from the folder would draw our
                    # own weights as another tool's.
                    "in_library_folder": self._aux_inside_library(),
                    "dirs": [d.info() for d in aux]},
            "modelscope": {"path": self.ms_root, "bytes": ms_bytes,
                           "dirs": [d.info() for d in ms]},
            "total_bytes": sum(r.bytes for r in repos) + aux_bytes + ms_bytes,
            "operation": self.operation,
        }

    def verify(self) -> dict:
        """Check every marked model's weights are really there.

        The install marker is a claim, not evidence — a manual cleanup of the
        cache folder leaves it standing over nothing, and the symptom is a job
        that fails inside a worker rather than a Download button. This is the
        cheap way to ask the question on purpose.

        Aux directories are deliberately absent: they carry no install marker,
        because nothing downloads them ahead of time. Only the adapter that
        fetches one knows what a complete `torch-cache` looks like, and a check
        that guessed would report problems that are not problems.
        """
        findings = []
        for model_id, model in sorted(self.registry.models.items()):
            if not self.registry.is_marked(model_id):
                continue
            actual = self.registry.cache_bytes(model_id)
            expected = self.registry.marked_bytes(model_id)
            if not self.registry.is_installed(model_id):
                state = "missing" if actual == 0 else "incomplete"
            elif expected and actual < expected * 0.98:
                # Not an equality test: the marker records what the download
                # fetched, and a repo shared with a pattern-scoped sibling can
                # legitimately measure a little differently afterwards.
                state = "shrunk"
            else:
                state = "ok"
            findings.append({"model_id": model_id,
                             "display_name": model.get("display_name", model_id),
                             "state": state,
                             "expected_bytes": expected,
                             "actual_bytes": actual})
        partial = [r.info() for r in self.repos_on_disk() if not r.installed]
        return {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "models": findings,
                "problem_count": sum(1 for f in findings if f["state"] != "ok"),
                "partial_repos": partial}

    # MARK: operations

    def _require_idle(self) -> None:
        """Refuse to rearrange the library out from under work in progress."""
        with self.lock:
            if self.operation and self.operation["state"] == "running":
                raise LibraryError(409, "LIBRARY_BUSY",
                                   "a library operation is already running")
        if self.state.downloads.list():
            raise LibraryError(409, "DOWNLOAD_ACTIVE",
                               "finish or cancel the downloads first")
        if self.state.queue.any_live_job():
            raise LibraryError(409, "ENGINE_BUSY",
                               "finish or cancel the queued renders first")

    def _start(self, mode: str, run, plan: dict) -> dict:
        self._require_idle()
        self._cancel.clear()
        op = {"operation_id": f"lib_{uuid.uuid4().hex[:12]}", "mode": mode,
              "state": "running", "fraction": 0.0, "bytes_done": 0,
              "bytes_total": plan.get("bytes_total", 0),
              "message": plan.get("message", ""), "error": None,
              **{k: v for k, v in plan.items()
                 if k not in ("bytes_total", "message")}}
        with self.lock:
            self.operation = op
        self.bus.emit_threadsafe("library.progress", dict(op))
        threading.Thread(target=self._run_guarded, args=(op, run),
                         daemon=True).start()
        return {"operation_id": op["operation_id"]}

    def _run_guarded(self, op: dict, run) -> None:
        try:
            run(op)
        except Exception as e:  # noqa: BLE001 — an operation must never take the engine with it
            op["state"] = "failed"
            op["error"] = {"code": "LIBRARY_FAILED", "message": str(e)}
            self.bus.emit_threadsafe("library.failed", dict(op))
        else:
            op["state"] = "succeeded"
            op["fraction"] = 1.0
            self.bus.emit_threadsafe("library.completed", dict(op))
        finally:
            # Install state has almost certainly moved; make every client
            # re-ask rather than reason about which rows changed.
            self.bus.emit_threadsafe("models.changed", {})

    def _progress(self, op: dict, done: int, message: str) -> None:
        op["bytes_done"] = done
        op["message"] = message
        total = op.get("bytes_total") or 0
        op["fraction"] = min(1.0, done / total) if total else None
        self.bus.emit_threadsafe("library.progress", dict(op))

    def cancel(self) -> None:
        """Stop after the file in flight.

        Deliberately not mid-file, and deliberately not a rollback: half a
        library is a state the folder can genuinely be in, and the honest
        answer to "stop" is to stop somewhere describable and say where. A
        cancelled move leaves both folders holding whole repos, and the summary
        says which went.
        """
        self._cancel.set()

    # MARK: clear

    def start_clear(self, scope: str = "all") -> dict:
        """Remove our models from the current folder.

        `scope` is "all", or "partial" for the interrupted downloads alone —
        reclaiming those is a different decision from throwing away working
        models, and the one people reach for first.

        "all" reaches into the aux and ModelScope roots too. Both are ours
        outright, so there is no shared-folder question to weigh — and a clear
        that left them would leave the largest single directory on some
        installs (`msst-weights`) sitting behind a zero.
        """
        if scope not in ("all", "partial"):
            raise LibraryError(422, "VALIDATION",
                               'scope must be "all" or "partial"')
        repos = self.repos_on_disk()
        aux: list[DirOnDisk] = []
        ms: list[DirOnDisk] = []
        if scope == "partial":
            # Aux directories have no partial state to reclaim (no marker, no
            # notion of a finished download), so this scope stays HF-only.
            repos = [r for r in repos if not r.installed]
        else:
            aux = [d for d in self.aux_dirs_on_disk() if not d.kept]
            ms = self.ms_dirs_on_disk()
        if not repos and not aux and not ms:
            raise LibraryError(
                409, "LIBRARY_EMPTY",
                "there are no unfinished downloads in this folder"
                if scope == "partial"
                else "there is nothing of ours to remove")
        total = sum(r.bytes for r in repos) + sum(d.bytes for d in aux + ms)
        count = len(repos) + len(aux) + len(ms)

        def run(op: dict) -> None:
            self._clear(op, repos, aux + ms)

        return self._start("clear", run,
                           {"bytes_total": total, "scope": scope,
                            "message": f"removing {count} directories",
                            "repo_count": len(repos),
                            "dir_count": len(aux) + len(ms)})

    def _clear(self, op: dict, repos: list[RepoOnDisk],
               dirs: list[DirOnDisk] | None = None) -> int:
        """Returns the byte count reached, so a relocate that clears and then
        moves can run both halves on one progress bar."""
        done = 0
        removed = []
        outstanding = {r.repo_id: r for r in repos}

        def credit(now: int) -> int:
            """Bytes for every repo that has gone since the last check.

            Counted by looking rather than by predicting: delete_model spares a
            repo a sibling still wants, so which repos a given delete actually
            frees is not knowable in advance — and a progress bar that assumed
            otherwise would run past 100% on exactly the shared-repo libraries
            where the wait is longest.
            """
            for repo_id, repo in list(outstanding.items()):
                if not os.path.isdir(repo.path):
                    now += repo.bytes
                    del outstanding[repo_id]
            return now

        # Models first, through delete_model: it clears the marker, drops the
        # user entry if it was one, and collects the family's runtime venv once
        # its last model goes — which is the larger half of some families and
        # the whole reason a "clear" that only rmtree'd weights would leave
        # gigabytes behind.
        for model_id in sorted({m for r in repos if r.installed
                                for m in r.model_ids}):
            if self._cancel.is_set():
                break
            if not self.registry.is_marked(model_id):
                continue
            self._progress(op, done, f"removing {model_id}")
            try:
                self.state.delete_model(model_id)
                removed.append(model_id)
            except Exception:  # noqa: BLE001 — one bad entry must not strand the rest
                pass
            done = credit(done)
            self._progress(op, done, f"removing {model_id}")
        # Then whatever is still on disk: partial repos, and anything
        # delete_model spared because a sibling marker outlived it.
        for repo in list(outstanding.values()):
            if self._cancel.is_set():
                break
            self._progress(op, done, f"removing {repo.repo_id}")
            shutil.rmtree(repo.path, ignore_errors=True)
            for model_id in repo.model_ids:
                self.registry.clear_attempt(model_id)
            done += repo.bytes
            del outstanding[repo.repo_id]
        # Last, the roots we own outright. No marker to clear and no model to
        # tell about it: the directory is the whole of the state.
        for d in dirs or []:
            if self._cancel.is_set():
                break
            self._progress(op, done, f"removing {d.name}")
            shutil.rmtree(d.path, ignore_errors=True)
            done += d.bytes
        self._progress(op, done, "done")
        op["removed_model_ids"] = removed
        op["canceled"] = self._cancel.is_set()
        return done

    # MARK: relocate

    def aux_destination(self, dest: str) -> str:
        """Where the aux root goes when the library moves to `dest`.

        Inside the chosen folder, so one pick puts every weight this app
        downloads in one place — except when the pick is the shared
        `~/.cache/huggingface`, where a directory of ours would be litter in
        someone else's folder. That case goes back to the data dir, which is
        also the default, so "put it back where it was" needs no special case.
        """
        settings = self.registry.settings
        shared = os.path.realpath(os.path.expanduser("~/.cache/huggingface"))
        if os.path.realpath(dest) == shared:
            return os.path.join(settings.data_dir, "aux-cache")
        return os.path.join(dest, AUX_FOLDER_NAME)

    def _probe_writable(self, path: str) -> None:
        try:
            os.makedirs(path, exist_ok=True)
            probe = os.path.join(path, ".localmusicgen-write-test")
            with open(probe, "w") as f:
                f.write("")
            os.unlink(probe)
        except OSError as e:
            raise LibraryError(422, "VALIDATION",
                               f"cannot write to {path}: {e}") from None

    def start_relocate(self, dest: str, disposition: str) -> dict:
        if disposition not in DISPOSITIONS:
            raise LibraryError(422, "VALIDATION",
                               f"disposition must be one of {DISPOSITIONS}")
        dest = os.path.abspath(os.path.expanduser(dest))
        src_root = os.path.realpath(self.root)
        if os.path.realpath(dest) == src_root:
            raise LibraryError(422, "VALIDATION",
                               "that is already the library folder")
        if os.path.realpath(dest).startswith(src_root + os.sep):
            raise LibraryError(422, "VALIDATION",
                               "the new folder cannot be inside the old one")
        aux_dest = self.aux_destination(dest)
        aux_src = os.path.realpath(self.aux_root)
        if os.path.realpath(aux_dest).startswith(aux_src + os.sep):
            raise LibraryError(
                422, "VALIDATION",
                "the new folder cannot be inside the auxiliary cache")
        self._probe_writable(dest)
        if os.path.realpath(aux_dest) != aux_src:
            self._probe_writable(aux_dest)

        moving = disposition != "leave"
        repos = self.repos_on_disk() if moving else []
        all_aux = self.aux_dirs_on_disk()
        # The user's own files always travel. "Delete them" and "leave them
        # where they are" are decisions about weights that can be fetched
        # again; neither is a decision anyone means to make about a collection
        # they curated, and a library that arrived without it would look empty.
        kept = [d for d in all_aux if d.kept]
        plain = [d for d in all_aux if not d.kept] if moving else []
        aux = kept + (plain if disposition == "move" else [])
        # ModelScope weights are not in the folder being left behind — they
        # live in the data dir and stay there — so no disposition touches them.
        total = sum(r.bytes for r in repos)
        aux_total = sum(d.bytes for d in kept + plain)
        if disposition == "move":
            # Each root is checked against its own destination: they can be on
            # different volumes, and a same-volume move is a rename that costs
            # no space at all — only a real copy has to fit.
            for label, size, to, frm in (
                    ("moving", total, dest, self.root),
                    ("moving the auxiliary cache", aux_total, aux_dest,
                     self.aux_root)):
                if not size:
                    continue
                if os.stat(_nearest_existing(to)).st_dev == os.stat(
                        _nearest_existing(frm)).st_dev:
                    continue
                free = shutil.disk_usage(_nearest_existing(to)).free
                if free < size:
                    raise LibraryError(
                        409, "INSUFFICIENT_DISK",
                        f"{label} needs {size >> 30} GB and that disk has "
                        f"{free >> 30} GB free")
        # restart_required is stated in the plan, not on success: the engine
        # reads HF_HOME once at launch, so a relocate that fell over halfway
        # needs the restart *more* than one that finished — some repos are at
        # the destination and the client has to point there to see them.
        plan = {"bytes_total": total + aux_total, "destination": dest,
                "aux_destination": aux_dest,
                "disposition": disposition, "repo_count": len(repos),
                "dir_count": len(aux),
                "kept_dir_count": len(kept),
                "restart_required": True,
                "message": {"move": "moving models",
                            "delete": "removing models from the old folder",
                            "leave": "leaving models where they are",
                            }[disposition]}

        def run(op: dict) -> None:
            done = 0
            if disposition == "delete":
                done = self._clear(op, repos, plain)
            if disposition == "move" or kept:
                # For delete and leave this carries the kept directories alone,
                # picking up the byte count the clear left off at so the bar
                # does not walk backwards.
                self._move(op, repos if disposition == "move" else [], dest,
                           aux, aux_dest, done=done)

        return self._start("relocate", run, plan)

    def _move(self, op: dict, repos: list[RepoOnDisk], dest: str,
              aux: list[DirOnDisk] | None = None,
              aux_dest: str | None = None, done: int = 0) -> int:
        hub = os.path.join(dest, "hub")
        os.makedirs(hub, exist_ok=True)
        moved, skipped = [], []

        def relocate(src: str, target: str, label: str, size: int) -> None:
            """One directory, renamed if we can and copied if we must."""
            nonlocal done
            self._progress(op, done, f"moving {label}")
            try:
                if not os.path.exists(target):
                    # Same volume: a rename is the whole move, instantly, with
                    # the blob/symlink structure intact. Across volumes this
                    # raises EXDEV and we pay for the copy below.
                    try:
                        os.rename(src, target)
                        done += size
                        moved.append(label)
                        return
                    except OSError:
                        pass
                done, complete = self._copy_tree(op, src, label, target, done)
                if not complete:
                    # Cancelled mid-copy: the destination is partial and the
                    # source is still the only whole copy — it must survive.
                    _mark_incomplete(target)
                    return
                if not _tree_copied(src, target):
                    _mark_incomplete(target)
                    skipped.append(label)
                    return
                _clear_incomplete(target)
                shutil.rmtree(src, ignore_errors=True)
                moved.append(label)
            except Exception:  # noqa: BLE001 — report it, keep the rest going
                _mark_incomplete(target)
                skipped.append(label)
                done += size

        for repo in repos:
            if self._cancel.is_set():
                break
            relocate(repo.path, os.path.join(hub, os.path.basename(repo.path)),
                     repo.repo_id, repo.bytes)
        # The aux root travels as its directories, not as one tree: the
        # destination can already hold some of them from an earlier stint in
        # that folder, and per-directory is what makes that a merge rather
        # than a collision.
        if aux and aux_dest:
            os.makedirs(aux_dest, exist_ok=True)
            for d in aux:
                if self._cancel.is_set():
                    break
                relocate(d.path, os.path.join(aux_dest, d.name), d.name,
                         d.bytes)
        self._progress(op, done, "done")
        op["moved_repo_ids"] = moved
        op["skipped_repo_ids"] = skipped
        op["canceled"] = self._cancel.is_set()
        return done

    def _copy_tree(self, op: dict, src: str, label: str, target: str,
                   done: int) -> tuple[int, bool]:
        """Copy one directory across volumes, symlinks kept as symlinks.

        Returns (done, complete). `complete` is False when the walk stopped
        on cancel; the caller must treat the destination as partial and leave
        the source in place.

        `copytree` would do this in a line, but it is opaque: a 57 GB repo
        would sit at the same percentage for twenty minutes. Walking it here
        buys a byte count — and buys the merge, for a destination that already
        holds some of this directory from a previous stint in that folder.

        Symlinks are preserved for two reasons now: a cached repo is `blobs/`
        plus a `snapshots/` tree of links into it, and the aux root holds at
        least one link that points outside itself (InspireMusic's, into the
        Hugging Face snapshot). Copying either as files would be wrong.
        """
        for root, dirs, files in os.walk(src, followlinks=False):
            rel = os.path.relpath(root, src)
            out_root = target if rel == "." else os.path.join(target, rel)
            os.makedirs(out_root, exist_ok=True)
            for d in dirs:
                src_d = os.path.join(root, d)
                if os.path.islink(src_d):
                    _relink(src_d, os.path.join(out_root, d))
            for name in files:
                if self._cancel.is_set():
                    return done, False
                # `src` must keep naming the tree root for the whole walk —
                # rebinding it here once sent every later directory's relpath
                # through a file path and copied subtrees outside the target.
                sp = os.path.join(root, name)
                dst = os.path.join(out_root, name)
                if os.path.islink(sp):
                    # The snapshot tree is symlinks into blobs/. Copying them
                    # as files would duplicate every blob and double the size
                    # of the library on arrival.
                    _relink(sp, dst)
                    continue
                try:
                    size = os.path.getsize(sp)
                except OSError:
                    size = 0
                if os.path.exists(dst) and _same_size(dst, size):
                    done += size
                    continue
                shutil.copy2(sp, dst)
                done += size
                self._progress(op, done, f"moving {label}")
        return done, True


def _mark_incomplete(target: str) -> None:
    """Tombstone a partial destination so the adapters' staging guards
    (`engine_protocol.staging.staged`) treat it as absent, not finished."""
    try:
        with open(os.path.join(target, INCOMPLETE_MARKER), "w") as f:
            f.write("partial copy from an interrupted relocate; "
                    "restage before trusting this tree\n")
    except OSError:
        pass


def _clear_incomplete(target: str) -> None:
    try:
        os.unlink(os.path.join(target, INCOMPLETE_MARKER))
    except OSError:
        pass


def _tree_copied(src: str, target: str) -> bool:
    """Every file under src has a same-size counterpart (or same-target link)
    under target. This is the check that stands between a finished copy and
    `rmtree` of the source: some trees here (tone3000 captures, working files)
    exist nowhere else, so deletion has to be earned, not assumed."""
    for root, dirs, files in os.walk(src, followlinks=False):
        rel = os.path.relpath(root, src)
        out_root = target if rel == "." else os.path.join(target, rel)
        for d in dirs:
            sp = os.path.join(root, d)
            if os.path.islink(sp):
                try:
                    if os.readlink(os.path.join(out_root, d)) != \
                            os.readlink(sp):
                        return False
                except OSError:
                    return False
        for name in files:
            sp = os.path.join(root, name)
            dp = os.path.join(out_root, name)
            if os.path.islink(sp):
                try:
                    if os.readlink(dp) != os.readlink(sp):
                        return False
                except OSError:
                    return False
                continue
            try:
                size = os.path.getsize(sp)
            except OSError:
                continue  # source went unreadable; nothing to compare
            if not _same_size(dp, size):
                return False
    return True


def _relink(src: str, dst: str) -> None:
    target = os.readlink(src)
    if os.path.lexists(dst):
        os.unlink(dst)
    os.symlink(target, dst)


def _same_size(path: str, size: int) -> bool:
    try:
        return os.path.getsize(path) == size
    except OSError:
        return False


def _nearest_existing(path: str) -> str:
    """The closest ancestor that exists — `disk_usage` needs a real path, and
    a library folder configured but never yet created is an ordinary state."""
    path = os.path.abspath(path)
    while path != os.sep and not os.path.exists(path):
        path = os.path.dirname(path)
    return path
