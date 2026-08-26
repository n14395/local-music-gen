from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass
class Settings:
    data_dir: str
    output_dir: str
    handshake_file: str
    parent_pid: int | None
    auth_token: str
    log_level: str = "info"

    @property
    def mem_guard_bytes(self) -> int:
        """Accelerator-memory ceiling for workers; breach = kill before swap.
        macOS won't OOM-kill a runaway Metal allocator — it swaps until the
        machine crawls — so the guard fails the job cleanly instead. Default 90%
        of physical RAM; LOCALMUSIC_MEM_GUARD_BYTES overrides (0 disables)."""
        env = os.environ.get("LOCALMUSIC_MEM_GUARD_BYTES")
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
    def envs_dir(self) -> str:
        return os.path.join(self.data_dir, "envs")

    @property
    def logs_dir(self) -> str:
        return os.path.join(self.data_dir, "Backend", "logs")

    @property
    def uploads_dir(self) -> str:
        return os.path.join(self.data_dir, "uploads")

    def ensure_dirs(self) -> None:
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
        for d in (self.data_dir, self.output_dir, self.hf_cache_dir,
                  self.ms_cache_dir, self.envs_dir, self.logs_dir,
                  self.uploads_dir):
            os.makedirs(d, exist_ok=True)
        # Every hub download (supervisor or worker) goes through the app's cache dir.
        os.environ["HF_HOME"] = self.hf_cache_dir
