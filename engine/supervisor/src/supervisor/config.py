from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field


@dataclass
class Settings:
    data_dir: str
    output_dir: str
    handshake_file: str
    parent_pid: int | None
    auth_token: str
    log_level: str = "info"
    # Library roots `ensure_dirs` could not create, as (path, reason). Filled
    # in by `ensure_dirs`; `main.run` turns each one into an engine.warning so
    # the app can say which drive is missing. Empty on a healthy start.
    unavailable_roots: list[tuple[str, str]] = field(default_factory=list)

    @property
    def mem_guard_bytes(self) -> int:
        """Accelerator-memory ceiling for workers; breach = kill before swap.
        macOS won't OOM-kill a runaway Metal allocator — it swaps until the
        machine crawls — so the guard fails the job cleanly instead. Default 90%
        of physical RAM; LOCALMUSICGEN_MEM_GUARD_BYTES overrides (0 disables)."""
        env = os.environ.get("LOCALMUSICGEN_MEM_GUARD_BYTES")
        if env is not None:
            return int(env or 0)
        from .telemetry import physical_ram_bytes
        return int(physical_ram_bytes() * 0.9)

    @property
    def hf_cache_dir(self) -> str:
        # The shared system Hugging Face cache — models are visible to (and
        # reusable by) any other HF tooling on the machine, and vice versa.
        # An HF_HOME already in the environment wins; the verification suite
        # relies on that for isolation (its delete tests rmtree repo dirs).
        return (os.environ.get("HF_HOME")
                or os.path.expanduser("~/.cache/huggingface"))

    @property
    def ms_cache_dir(self) -> str:
        # ModelScope-hosted weights (catalog `ms_repos`). Engine-owned rather
        # than shared like the HF cache: there is no ModelScope tooling on the
        # machine to share with, and keeping it inside data_dir means wiping
        # the data dir is still a clean slate.
        return os.path.join(self.data_dir, "ms-cache")

    @property
    def aux_cache_dir(self) -> str:
        # Weights adapters fetch themselves — direct URLs, torch hub, source
        # tarballs (engine_protocol.adapter.AUX_DIRS names them all). Owned by
        # the engine like ms-cache, but relocatable with the library folder,
        # because unlike ms-cache it holds real gigabytes. These used to be
        # derived per-adapter as a sibling of HF_HOME, which meant a library
        # move silently stranded them; one root, named here, is the fix.
        return (os.environ.get("LOCALMUSICGEN_AUX_CACHE")
                or os.path.join(self.data_dir, "aux-cache"))

    @property
    def envs_dir(self) -> str:
        return os.path.join(self.data_dir, "envs")

    @property
    def logs_dir(self) -> str:
        return os.path.join(self.data_dir, "Backend", "logs")

    @property
    def uploads_dir(self) -> str:
        return os.path.join(self.data_dir, "uploads")

    def acquire_instance_lock(self) -> None:
        """One engine per data dir, enforced before anything is touched.

        A second engine's startup purge used to rmtree the first's live
        uploads — hit live during the 2026-09 audit when the app launched
        beside a smoke run and destroyed its in-flight job (audit H6).
        Refusing to start, loudly, is the honest behavior. The fd is held
        for the process lifetime; the OS releases it on any exit.
        """
        import fcntl
        os.makedirs(self.data_dir, exist_ok=True)
        path = os.path.join(self.data_dir, "engine.lock")
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise SystemExit(
                f"another engine already serves this data dir "
                f"({self.data_dir}) — quit the app or the other engine "
                f"first, or point this one at its own --data-dir")
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        self._lock_fd = fd  # noqa: SLF001 — keeps the flock alive

    def ensure_dirs(self) -> None:
        # The lock must precede the purge below: without it a second engine
        # on the same data dir deletes the first one's live uploads.
        self.acquire_instance_lock()
        # Uploads are transient job inputs (jobs are in-memory, so references
        # cannot outlive the engine); purge them on every startup.
        import glob
        import shutil
        shutil.rmtree(self.uploads_dir, ignore_errors=True)
        # Render previews are transient too, and the one path that deliberately
        # leaves them behind is a cancel — the app may still be copying the last
        # frame out for "Keep partial", so the engine must not delete it from
        # under that. It collects them on the next start instead, by which time
        # the decision has long been made.
        for stale in glob.glob(os.path.join(self.output_dir, "*", "preview-*.wav")):
            try:
                os.remove(stale)
            except OSError:
                pass
        # The engine's own roots. Nothing works without these, so a failure
        # here is still fatal.
        for d in (self.data_dir, self.output_dir, self.envs_dir,
                  self.logs_dir, self.uploads_dir):
            os.makedirs(d, exist_ok=True)
        # The library roots are the ones that can sit on another volume, so
        # they are the ones that can be missing. This used to take the engine
        # down before it ever answered: with the library drive unmounted,
        # makedirs('/Volumes/<drive>/…') raises PermissionError (errno 13, not
        # 2 — /Volumes is root-owned), the traceback escaped run() before the
        # handshake file was written, and the app crash-restarted four times
        # into a Settings screen that needs a live engine to draw — the one
        # screen that could have repointed the folder.
        #
        # Coming up without them is safe: every reader of these roots stats
        # before it walks, so the models simply read `not_installed`, and no
        # marker, DB row, venv or aux dir is removed over an absent root.
        self.unavailable_roots = []
        for d in (self.hf_cache_dir, self.ms_cache_dir, self.aux_cache_dir):
            try:
                os.makedirs(d, exist_ok=True)
            except OSError as e:
                # One missing drive, one warning: after a relocate the aux
                # root lives inside the library folder, and naming both would
                # tell the user twice about the same unplugged disk.
                if any(d.startswith(p + os.sep) for p, _ in self.unavailable_roots):
                    continue
                reason = e.strerror or str(e)
                self.unavailable_roots.append((d, reason))
                # stderr as well as the event: the app tails this stream, and
                # a client that connects after startup misses an event emitted
                # before it subscribed.
                print(f"warning: model library folder {d} is unavailable "
                      f"({reason}) — its models will read as not installed "
                      f"until the drive is reconnected, or choose another "
                      f"folder in Settings", file=sys.stderr)
        # Every hub download (supervisor or worker) goes through the app's cache dir.
        os.environ["HF_HOME"] = self.hf_cache_dir
        # Likewise every adapter's own download; the worker sets this explicitly
        # too, so the two agree whatever the import order turns out to be.
        os.environ["LOCALMUSICGEN_AUX_CACHE"] = self.aux_cache_dir
