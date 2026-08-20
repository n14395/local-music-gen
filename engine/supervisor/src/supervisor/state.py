from __future__ import annotations

import time

from . import envs, telemetry
from .config import Settings
from .downloader import DownloadManager
from .events import EventBus
from .jobqueue import JobQueue
from .registry import Registry


class EngineState:
    """Shared runtime state handed to the API routers."""

    def __init__(self, settings: Settings, bus: EventBus) -> None:
        self.settings = settings
        self.bus = bus
        self.started_at = time.monotonic()
        self.hf_token: str | None = None
        self.registry = Registry(settings)
        self.downloads = DownloadManager(self.registry, bus, lambda: self.hf_token)
        self.queue = JobQueue(self.registry, bus, settings)
        # Last working set any worker reported. It describes the Mac, not the
        # process, so it stays true after that worker exits — which is the only
        # way an idle engine can report a ceiling at all.
        self.working_set_bytes: int | None = None

    def model_in_use(self, model_id: str) -> bool:
        return self.queue.model_in_use(model_id)

    # MARK: models

    def model_info(self, model_id: str) -> dict:
        """The `ModelInfo` every endpoint returns: the catalog entry plus the
        three things only this object can answer — whether its weights are
        here, whether its runtime is, and whether it is pinned."""
        active = self.downloads.active_for(model_id)
        info = self.registry.info(model_id, active.state if active else None)
        info["pinned"] = model_id == self.queue.pinned_model_id
        info["runtime_state"] = self.runtime_state(
            self.registry.models[model_id]["family"])
        return info

    def runtime_state(self, family: str) -> str:
        """Whether this family's adapter packages are installed (contract 4.1).

        A family property reported per model, because a model is what the user
        downloads and deletes: two entries of one family are ready or not
        together, and the second one costs nothing once the first has paid.
        """
        if envs.is_provisioned(family):
            return "installed"
        if family in self.downloads.provisioning_families():
            return "installing"
        return "not_installed"

    def delete_model(self, model_id: str) -> None:
        """Remove a model's weights, and its family's runtime with it once no
        downloaded model needs that runtime any more.

        The runtime is the larger half of some families (ACE-Step's venv is
        1.4 GB of torch), so leaving it behind after the last model of a family
        goes would quietly keep most of the space the user asked to reclaim.
        """
        family = self.registry.models[model_id]["family"]
        self.registry.delete(model_id)
        if self.registry.is_user_model(model_id):
            self.registry.remove_user_model(model_id)
        if self.registry.family_still_wanted(family):
            return
        # A download of a sibling has no install marker yet, so the check above
        # cannot see it — and it may be building this very venv right now.
        if family in self.downloads.families_in_flight():
            return
        # release_family refuses while a job of the family is queued or
        # running, in which case the venv stays: a runtime deleted under a
        # running worker is a crash, and the next delete will collect it.
        if self.queue.release_family(family):
            envs.remove(family)

    @property
    def active_job(self):
        return self.queue.active

    def uptime_s(self) -> float:
        return round(time.monotonic() - self.started_at, 1)

    def accelerator(self) -> dict:
        """What the engine computes on. `backend` is null while no worker is
        alive — the engine genuinely does not know which framework the next
        model will use, and "Metal" would be a guess."""
        worker = self.queue.telemetry_worker()
        if worker is not None and worker.working_set_bytes:
            self.working_set_bytes = worker.working_set_bytes
        return {"name": telemetry.chip_name(),
                "backend": worker.backend if worker else None,
                "working_set_bytes": self.working_set_bytes}

    def usage(self) -> dict:
        """Live resource use, every field independently nullable — the app hides
        a readout it has no number for rather than drawing a zero."""
        worker = self.queue.telemetry_worker()
        return {
            # device-wide, not this worker's share: see telemetry
            "gpu_percent": telemetry.gpu_utilization_percent(),
            "worker_bytes": worker.footprint_bytes() if worker else None,
            # 0 here means "no reading yet", not "no memory": the worker only
            # sends a figure once it has one
            "accelerator_bytes": (worker.mem_bytes or None) if worker else None,
        }
