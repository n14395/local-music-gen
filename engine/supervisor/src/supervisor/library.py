"""The model library: what of the Hugging Face cache belongs to this app.

The cache is not ours. By default it is `~/.cache/huggingface`, shared with
every other Hugging Face tool on the machine, and a folder full of repos we
never asked for is the normal case rather than the exception. So every figure
and every destructive act here is scoped through the catalog: a repo counts as
ours when some entry in `Registry.models` names it, and nothing else in that
folder is read, measured, moved or removed.

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

from .events import EventBus
from .registry import Registry

# Dispositions for the models already in the folder being left behind.
DISPOSITIONS = ("move", "delete", "leave")


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

    def info(self) -> dict:
        """Everything the Settings group draws, in one request.

        `folder_bytes` is deliberately beside `bytes`: in the shared default
        the two differ by whatever other Hugging Face tooling has cached there,
        and a single "size" figure that silently disagrees with the Finder is
        the kind of number people stop trusting. Naming both explains the gap.
        """
        repos = self.repos_on_disk()
        installed = [r for r in repos if r.installed]
        partial = [r for r in repos if not r.installed]
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
            "operation": self.operation,
        }

    def verify(self) -> dict:
        """Check every marked model's weights are really there.

        The install marker is a claim, not evidence — a manual cleanup of the
        cache folder leaves it standing over nothing, and the symptom is a job
        that fails inside a worker rather than a Download button. This is the
        cheap way to ask the question on purpose.
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
        """
        if scope not in ("all", "partial"):
            raise LibraryError(422, "VALIDATION",
                               'scope must be "all" or "partial"')
        repos = self.repos_on_disk()
        if scope == "partial":
            repos = [r for r in repos if not r.installed]
        if not repos:
            raise LibraryError(
                409, "LIBRARY_EMPTY",
                "there are no unfinished downloads in this folder"
                if scope == "partial"
                else "there is nothing of ours in this folder")
        total = sum(r.bytes for r in repos)

        def run(op: dict) -> None:
            self._clear(op, repos)

        return self._start("clear", run,
                           {"bytes_total": total, "scope": scope,
                            "message": f"removing {len(repos)} repositories",
                            "repo_count": len(repos)})

    def _clear(self, op: dict, repos: list[RepoOnDisk]) -> None:
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
        self._progress(op, done, "done")
        op["removed_model_ids"] = removed
        op["canceled"] = self._cancel.is_set()

    # MARK: relocate

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
        try:
            os.makedirs(dest, exist_ok=True)
            probe = os.path.join(dest, ".localmusic-write-test")
            with open(probe, "w") as f:
                f.write("")
            os.unlink(probe)
        except OSError as e:
            raise LibraryError(422, "VALIDATION",
                               f"cannot write to {dest}: {e}") from None

        repos = self.repos_on_disk() if disposition != "leave" else []
        total = sum(r.bytes for r in repos)
        if disposition == "move" and total:
            free = shutil.disk_usage(dest).free
            same_volume = os.stat(dest).st_dev == os.stat(
                _nearest_existing(self.root)).st_dev
            # A same-volume move is a rename and costs no space at all; only a
            # real copy has to fit.
            if not same_volume and free < total:
                raise LibraryError(
                    409, "INSUFFICIENT_DISK",
                    f"moving needs {total >> 30} GB and that disk has "
                    f"{free >> 30} GB free")
        # restart_required is stated in the plan, not on success: the engine
        # reads HF_HOME once at launch, so a relocate that fell over halfway
        # needs the restart *more* than one that finished — some repos are at
        # the destination and the client has to point there to see them.
        plan = {"bytes_total": total, "destination": dest,
                "disposition": disposition, "repo_count": len(repos),
                "restart_required": True,
                "message": {"move": "moving models",
                            "delete": "removing models from the old folder",
                            "leave": "leaving models where they are",
                            }[disposition]}

        def run(op: dict) -> None:
            if disposition == "move":
                self._move(op, repos, dest)
            elif disposition == "delete":
                self._clear(op, repos)

        return self._start("relocate", run, plan)

    def _move(self, op: dict, repos: list[RepoOnDisk], dest: str) -> None:
        hub = os.path.join(dest, "hub")
        os.makedirs(hub, exist_ok=True)
        done = 0
        moved, skipped = [], []
        for repo in repos:
            if self._cancel.is_set():
                break
            target = os.path.join(hub, os.path.basename(repo.path))
            self._progress(op, done, f"moving {repo.repo_id}")
            try:
                if not os.path.exists(target):
                    # Same volume: a rename is the whole move, instantly, with
                    # the blob/symlink structure intact. Across volumes this
                    # raises EXDEV and we pay for the copy below.
                    try:
                        os.rename(repo.path, target)
                        done += repo.bytes
                        moved.append(repo.repo_id)
                        continue
                    except OSError:
                        pass
                done = self._copy_repo(op, repo, target, done)
                shutil.rmtree(repo.path, ignore_errors=True)
                moved.append(repo.repo_id)
            except Exception:  # noqa: BLE001 — report the repo, keep the rest going
                skipped.append(repo.repo_id)
                done += repo.bytes
        self._progress(op, done, "done")
        op["moved_repo_ids"] = moved
        op["skipped_repo_ids"] = skipped
        op["canceled"] = self._cancel.is_set()

    def _copy_repo(self, op: dict, repo: RepoOnDisk, target: str,
                   done: int) -> int:
        """Copy one repo across volumes, symlinks kept as symlinks.

        `copytree` would do this in a line, but it is opaque: a 57 GB repo
        would sit at the same percentage for twenty minutes. Walking it here
        buys a byte count — and buys the merge, for a destination that already
        holds some of this repo from a previous stint in that folder.
        """
        for root, dirs, files in os.walk(repo.path, followlinks=False):
            rel = os.path.relpath(root, repo.path)
            out_root = target if rel == "." else os.path.join(target, rel)
            os.makedirs(out_root, exist_ok=True)
            for d in dirs:
                src_d = os.path.join(root, d)
                if os.path.islink(src_d):
                    _relink(src_d, os.path.join(out_root, d))
            for name in files:
                if self._cancel.is_set():
                    return done
                src = os.path.join(root, name)
                dst = os.path.join(out_root, name)
                if os.path.islink(src):
                    # The snapshot tree is symlinks into blobs/. Copying them
                    # as files would duplicate every blob and double the size
                    # of the library on arrival.
                    _relink(src, dst)
                    continue
                try:
                    size = os.path.getsize(src)
                except OSError:
                    size = 0
                if os.path.exists(dst) and _same_size(dst, size):
                    done += size
                    continue
                shutil.copy2(src, dst)
                done += size
                self._progress(op, done, f"moving {repo.repo_id}")
        return done


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
