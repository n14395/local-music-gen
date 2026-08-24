#!/usr/bin/env python3
"""End-to-end verification of the stub engine against docs/api-contract.md.

Stdlib only. Spawns the stub exactly the way the app will (handshake file, auth token
via env, parent-pid watchdog), then exercises every endpoint. Exit 0 = all checks pass.

Usage: python3 scripts/verify_stub.py [--play]   (--play: afplay the generated WAV)
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import secrets
import subprocess
import sys
import tempfile
import time
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from contractlib import Client, SSEListener, check, report  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--play", action="store_true")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="localmusic-verify-")
    handshake = os.path.join(tmp, "handshake.json")
    token = secrets.token_hex(16)
    env = {**os.environ, "LOCALMUSIC_AUTH_TOKEN": token,
           "LOCALMUSIC_STUB_DOWNLOAD_S": "2", "LOCALMUSIC_STUB_PROVISION_S": "1",
           "LOCALMUSIC_STUB_JOB_SPEED": "4"}
    proc = subprocess.Popen(
        ["uv", "run", "python", "stub_server.py",
         "--handshake-file", handshake, "--parent-pid", str(os.getpid()),
         "--data-dir", os.path.join(tmp, "data"),
         "--output-dir", os.path.join(tmp, "outputs")],
        cwd=os.path.join(ROOT, "stub-backend"), env=env,
        stderr=subprocess.PIPE, stdout=subprocess.PIPE)

    try:
        print("• bootstrap")
        deadline = time.time() + 60
        while not os.path.exists(handshake) and time.time() < deadline:
            if proc.poll() is not None:
                print(proc.stderr.read().decode())
                check("stub stayed alive during startup", False)
                return report()
            time.sleep(0.1)
        check("handshake file appears", os.path.exists(handshake))
        hs = json.load(open(handshake))
        check("handshake has port/pid/contract",
              all(k in hs for k in ("port", "pid", "version", "contract")))
        c = Client(hs["port"], token)

        status, body = c.req("GET", "/healthz", auth=False)
        check("GET /healthz without auth", status == 200 and body["status"] == "ok")
        status, body = c.req("GET", "/v1/system", auth=False)
        check("401 without bearer token",
              status == 401 and body["error"]["code"] == "UNAUTHORIZED")
        status, body = c.req("GET", "/v1/system")
        check("GET /v1/system", status == 200 and body["ram_bytes"] > 0
              and body["free_disk_bytes"] > 0)
        # contract 3: telemetry, every field nullable. Nothing is loaded yet, so
        # the memory figures must be null rather than 0 — the app hides the
        # readout instead of drawing an empty bar.
        accel, usage = body.get("accelerator") or {}, body.get("usage") or {}
        check("system reports the accelerator",
              accel.get("backend") in ("mlx", "metal", "cpu")
              and 0 < accel.get("working_set_bytes", 0) < body["ram_bytes"],
              str(accel))
        check("system reports device-wide GPU utilisation",
              0 <= usage.get("gpu_percent", -1) <= 100, str(usage))
        check("memory is null with nothing loaded, never zero",
              "worker_bytes" in usage and usage["worker_bytes"] is None
              and usage["accelerator_bytes"] is None, str(usage))

        print("• models & downloads")
        status, body = c.req("GET", "/v1/models")
        models = {m["id"]: m for m in body["models"]}
        check("catalog has 11 models, all not_installed",
              len(models) == 11 and all(m["install_state"] == "not_installed"
                                        for m in models.values()))
        check("task models advertise capabilities.tasks",
              models["separation-stub"]["capabilities"].get("tasks")
              == ["separate", "analyze"]
              and models["dsp-stub"]["capabilities"].get("tasks") == ["mix"]
              and models["transcription-stub"]["capabilities"].get("tasks")
              == ["transcribe"]
              and models["render-stub"]["capabilities"].get("tasks")
              == ["render"]
              and models["assistant-stub"]["capabilities"].get("tasks")
              == ["assist"]
              and models["caption-stub"]["capabilities"].get("tasks")
              == ["caption", "tag"]
              and models["lyrics-stub"]["capabilities"].get("tasks")
              == ["lyrics"]
              and models["notation-stub"]["capabilities"].get("tasks")
              == ["compose"]
              and "tasks" not in models["musicgen-small"]["capabilities"])
        check("catalog capability variety",
              models["musicgen-small"]["capabilities"]["instrumental_only"]
              and models["acestep-base"]["capabilities"]["supports_lyrics"]
              and models["stableaudio-small"]["license"]["requires_hf_token"])
        check("every model carries usage tags",
              all(isinstance(m.get("tags"), list) and m["tags"]
                  for m in models.values()),
              str({k: v.get("tags") for k, v in models.items()}))
        # tags are derived from capabilities, so they track the fixture: the
        # stub's musicgen carries a melody param, and separation-stub is
        # deliberately dual-task (separate + analyze)
        check("tags describe usage, per model kind",
              models["musicgen-small"]["tags"] == ["Instrumental & loops",
                                                   "Melody-guided"]
              and models["acestep-base"]["tags"] == ["Songs with vocals",
                                                     "Remix & restyle"]
              and models["assistant-stub"]["tags"] == ["Writing help"]
              and models["separation-stub"]["tags"] == ["Stem separation",
                                                        "Musical analysis"]
              and models["transcription-stub"]["tags"] == ["Notes & MIDI"]
              and models["dsp-stub"]["tags"] == ["Mixing & recombining"]
              and models["caption-stub"]["tags"] == ["Hears & describes"]
              and models["lyrics-stub"]["tags"] == ["Hears & describes"]
              and models["notation-stub"]["tags"] == ["Notes & MIDI"],
              str({k: v["tags"] for k, v in models.items()}))
        # contract 5.5: generation models declare the stages their adapter can
        # name; task models declare none, so the app falls back to one bar
        pipe = models["acestep-base"]["capabilities"].get("pipeline")
        check("generation models declare capabilities.pipeline",
              pipe is not None
              and [s["id"] for s in pipe] == ["lm_reasoning", "prompt_encode",
                                              "diffusion", "vocoder", "master"]
              and all(isinstance(s.get("label"), str) and s["label"]
                      for s in pipe),
              str(pipe))
        check("a skippable stage is flagged optional",
              [s["id"] for s in pipe if s.get("optional")] == ["lm_reasoning"])
        check("task models declare no pipeline",
              all("pipeline" not in models[m]["capabilities"]
                  for m in ("separation-stub", "dsp-stub", "transcription-stub",
                            "render-stub")))
        # contract 4.1: params name the section of the form they belong in, and
        # controls a task selector makes inert say which tasks they serve
        ace = {p["key"]: p
               for p in models["acestep-base"]["capabilities"]["params"]}
        check("generation params declare a group",
              ace["steps"].get("group") == "sampling"
              and ace["bpm"].get("group") == "musical"
              and ace["task_type"].get("group") == "task",
              str({k: v.get("group") for k, v in ace.items()}))
        check("a param may omit group and be classified by the app",
              "group" not in ace["variant"])
        check("task-gated params declare applies_when",
              ace["audio_cover_strength"].get("applies_when")
              == {"param": "task_type", "values": ["cover"]}
              and (ace["src_audio"].get("applies_when") or {}).get("values")
              == ["cover", "repaint"],
              str(ace["audio_cover_strength"].get("applies_when")))
        check("params that apply to every task carry no applies_when",
              all("applies_when" not in ace[k]
                  for k in ("steps", "seed", "task_type")))
        check("task models leave grouping to the app",
              all("group" not in p for p in
                  models["separation-stub"]["capabilities"]["params"]))
        status, _ = c.req("GET", "/v1/models/nope")
        check("404 unknown model", status == 404)

        sse = SSEListener(hs["port"], token)
        sse.start()
        time.sleep(0.3)

        status, body = c.req("POST", "/v1/models/musicgen-small/download")
        check("start download", status == 202 and body["download_id"].startswith("dl_"))
        dl_id = body["download_id"]
        status, body2 = c.req("POST", "/v1/models/musicgen-small/download")
        check("re-POST download is idempotent", body2["download_id"] == dl_id)
        # contract 4.2: the first model of a family builds its runtime first,
        # and reports that on this download's own events
        prov = sse.wait_for("download.progress", 10,
                            lambda d: d["state"] == "provisioning")
        check("venv provisioning reported as a download stage",
              prov is not None and prov["stage"] == "provisioning"
              and prov["message"] != "", str(prov))
        check("provisioning reports no transfer rate",
              prov is not None and prov["speed_bps"] == 0, str(prov))
        # pause is accepted and ignored there: an installer that cannot be
        # suspended must not report itself paused
        c.req("POST", f"/v1/downloads/{dl_id}/pause")
        _, body = c.req("GET", "/v1/downloads")
        row = next((d for d in body["downloads"] if d["download_id"] == dl_id), None)
        check("pause while provisioning does not claim to have paused",
              row is not None and row["state"] in ("provisioning", "downloading"),
              str(row))
        # `state`, not `stage`: a download announces itself on arrival with the
        # stage it *expects* (4.2), so "weights" alone can still be a download
        # that has not started.
        prog = sse.wait_for("download.progress", 10,
                            lambda d: d["stage"] == "weights"
                            and d["state"] == "downloading")
        check("download.progress on SSE", prog is not None)
        check("weights progress carries counters and a rate",
              prog is not None and prog["bytes_total"] > 0
              and prog["bytes_done"] >= 0 and prog["speed_bps"] > 0, str(prog))
        # The stub grows a POST /v1/downloads/{id}/_step in manual mode, which
        # lets the app's own tests drive a transfer tick by tick instead of
        # racing its clock. It is a fixture control, not contract surface, and
        # the registration is inside an `if MANUAL_DOWNLOADS` for that reason.
        # This is what keeps that honest: in an ordinary run — which is what
        # every other check here verifies against — the route must not exist.
        step_status, _ = c.req("POST", f"/v1/downloads/{dl_id}/_step")
        check("the manual-step control is absent outside manual mode",
              step_status == 404, f"got {step_status}")

        status, _ = c.req("POST", f"/v1/downloads/{dl_id}/pause")
        time.sleep(0.6)
        status, body = c.req("GET", "/v1/downloads")
        paused = next((d for d in body["downloads"] if d["download_id"] == dl_id), None)
        check("pause reflected in GET /v1/downloads",
              paused is not None and paused["state"] == "paused")
        check("a paused download reports no rate",
              paused is not None and paused["speed_bps"] == 0, str(paused))
        c.req("POST", f"/v1/downloads/{dl_id}/resume")
        done = sse.wait_for("download.completed", 30,
                            lambda d: d["model_id"] == "musicgen-small")
        check("download.completed", done is not None)
        _, body = c.req("GET", "/v1/models/musicgen-small")
        check("model becomes installed", body["install_state"] == "installed")
        # contract 4.1: a finished download means ready to render — weights AND
        # the family runtime that had to be built before them
        check("a downloaded model reports its runtime installed",
              body.get("runtime_state") == "installed",
              str(body.get("runtime_state")))

        # contract 4.1/4.2: the runtime is per family, deleted with the last
        # model of it, and re-installable on its own
        c.req("DELETE", "/v1/models/musicgen-small")
        _, body = c.req("GET", "/v1/models/musicgen-small")
        check("deleting the last model of a family drops its runtime",
              body["install_state"] == "not_installed"
              and body.get("runtime_state") == "not_installed", str(body))
        status, body = c.req("POST", "/v1/models/musicgen-small/runtime")
        check("runtime install accepted on its own",
              status == 202 and body["download_id"].startswith("dl_"))
        rt_id = body["download_id"]
        _, body = c.req("GET", "/v1/downloads")
        rt = next((d for d in body["downloads"] if d["download_id"] == rt_id), None)
        check("a runtime install says it carries no weights",
              rt is not None and rt.get("runtime_only") is True
              and rt["stage"] == "provisioning", str(rt))
        status, body = c.req("POST", "/v1/models/musicgen-small/runtime")
        check("a second runtime request joins the one already running",
              body["download_id"] == rt_id, str(body))
        _, body = c.req("GET", "/v1/models/musicgen-small")
        check("every model of the family reads 'installing' meanwhile",
              body.get("runtime_state") == "installing",
              str(body.get("runtime_state")))
        done = sse.wait_for("download.completed", 30,
                            lambda d: d["download_id"] == rt_id)
        check("runtime install completes", done is not None)
        check("its completion says no model arrived",
              done is not None and done.get("runtime_only") is True, str(done))
        _, body = c.req("GET", "/v1/models/musicgen-small")
        check("runtime install leaves the weights alone",
              body.get("runtime_state") == "installed"
              and body["install_state"] == "not_installed", str(body))
        # put the weights back for the checks that follow. `since` matters:
        # this model has completed a download before, and an unmarked wait
        # would match that one and let the next check run against a transfer
        # still holding the single download slot.
        mark = sse.mark()
        c.req("POST", "/v1/models/musicgen-small/download")
        check("re-download after a runtime install completes",
              sse.wait_for("download.completed", 60,
                           lambda d: d["model_id"] == "musicgen-small",
                           since=mark) is not None)

        # gated repo with no token: the one failure that must NOT leave the
        # entry resumable, since nothing was fetched and a retry without
        # access fails identically (contract 4.1).
        mark = sse.mark()
        _, body = c.req("POST", "/v1/models/stableaudio-small/download")
        failed = sse.wait_for("download.failed", 30,
                              lambda d: d["model_id"] == "stableaudio-small",
                              since=mark)
        check("gated download with no token fails UNAUTHORIZED",
              failed is not None
              and failed["error"]["code"] == "UNAUTHORIZED", str(failed))
        _, body = c.req("GET", "/v1/models/stableaudio-small")
        check("a gated failure does not leave the model resumable",
              body["install_state"] == "not_installed", str(body))
        # ...and the same download goes through once a token is in place,
        # which is what makes the failure above a gate rather than a wall.
        c.req("POST", "/v1/settings/hf-token", {"token": "hf_stub_token"})
        mark = sse.mark()
        c.req("POST", "/v1/models/stableaudio-small/download")
        check("a gated download succeeds once a token is set",
              sse.wait_for("download.completed", 60,
                           lambda d: d["model_id"] == "stableaudio-small",
                           since=mark) is not None)

        # cancel path on a second model
        _, body = c.req("POST", "/v1/models/acestep-base/download")
        dl2 = body["download_id"]
        time.sleep(0.5)
        status, _ = c.req("DELETE", f"/v1/downloads/{dl2}")
        check("cancel download accepted", status == 202)
        time.sleep(0.5)
        _, body = c.req("GET", "/v1/models/acestep-base")
        check("canceled download leaves partial/not_installed",
              body["install_state"] in ("partial", "not_installed"))

        # contract 4.2: downloads transfer one at a time, and the ones waiting
        # say `queued` rather than reporting a transfer moving at 0 B/s
        _, body = c.req("POST", "/v1/models/acestep-base/download")
        dl_a = body["download_id"]
        _, body = c.req("POST", "/v1/models/separation-stub/download")
        dl_b = body["download_id"]
        _, body = c.req("GET", "/v1/downloads")
        rows = {d["download_id"]: d for d in body["downloads"]}
        check("a second download waits its turn instead of running",
              rows.get(dl_b, {}).get("state") == "queued"
              and rows.get(dl_a, {}).get("state") in ("provisioning",
                                                      "downloading"),
              str(rows))
        check("a queued download invents no transfer",
              rows.get(dl_b, {}).get("speed_bps") == 0, str(rows.get(dl_b)))
        # a download nobody has started still has to appear on the stream: the
        # dispatch event says nothing about the ones behind it
        check("the waiting download announced itself over SSE",
              sse.wait_for("download.progress", 5,
                           lambda d: d["download_id"] == dl_b
                           and d["state"] == "queued") is not None)
        c.req("POST", f"/v1/downloads/{dl_b}/pause")
        _, body = c.req("GET", "/v1/downloads")
        rows = {d["download_id"]: d for d in body["downloads"]}
        check("pause on a queued download does not claim to have paused",
              rows.get(dl_b, {}).get("state") == "queued", str(rows.get(dl_b)))
        sse.wait_for("download.progress", 15,
                     lambda d: d["download_id"] == dl_a
                     and d["stage"] == "weights"
                     and d["state"] == "downloading")
        c.req("POST", f"/v1/downloads/{dl_a}/pause")
        time.sleep(0.8)
        _, body = c.req("GET", "/v1/downloads")
        rows = {d["download_id"]: d for d in body["downloads"]}
        # the slot is what makes "pause everything" hold: releasing it would
        # start the next model behind the user's back
        check("a paused download keeps its slot, so nothing behind it starts",
              rows.get(dl_a, {}).get("state") == "paused"
              and rows.get(dl_b, {}).get("state") == "queued", str(rows))
        c.req("DELETE", f"/v1/downloads/{dl_b}")
        c.req("DELETE", f"/v1/downloads/{dl_a}")
        time.sleep(0.6)
        _, body = c.req("GET", "/v1/downloads")
        check("cancel clears both a running and a never-started download",
              not any(d["download_id"] in (dl_a, dl_b)
                      for d in body["downloads"]), str(body))

        print("• jobs")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["acestep-base"], "prompt": "x"})
        check("409 MODEL_NOT_INSTALLED",
              status == 409 and body["error"]["code"] == "MODEL_NOT_INSTALLED")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "prompt": "x", "lyrics": "la la"})
        check("422 lyrics on instrumental model",
              status == 422 and body["error"]["code"] == "VALIDATION")

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "prompt": "warm lo-fi with vinyl crackle",
            "duration_s": 4, "count": 2,
            "params": {"guidance_scale": 4.0, "bogus_key": 1}})
        check("submit job", status == 202 and len(body["jobs"]) == 1)
        job_id = body["jobs"][0]["job_id"]
        group_id = body["group_id"]
        dropped = sse.wait_for("job.log", 5, lambda d: "bogus_key" in d.get("line", ""))
        check("unknown param dropped via job.log", dropped is not None)
        started = sse.wait_for("job.started", 10, lambda d: d["job_id"] == job_id)
        check("job.started", started is not None)
        job_mark = sse.mark()
        prog = sse.wait_for(
            "job.progress", 10,
            lambda d: (d["job_id"] == job_id and d["stage"] == "generating"
                       and d["fraction"] is not None))
        check("job.progress with stage/fraction",
              prog is not None and 0 <= prog["fraction"] <= 1)
        indeterminate = sse.wait_for(
            "job.progress", 10,
            lambda d: d["job_id"] == job_id and d["fraction"] is None)
        check("indeterminate progress reaches the wire as null",
              indeterminate is not None)
        # An adapter that cannot quantify a phase still names it. This is the
        # commonest shape in the real engine — five of nine generation families
        # open every take with it — so the fixture has to produce it too, or
        # the UI path that draws a spinner beside a named stage is exercised by
        # nothing.
        named_indeterminate = next(
            (d for _, e, d in sse.events[job_mark:]
             if e == "job.progress" and d["job_id"] == job_id
             and d["stage"] == "generating" and d["fraction"] is None
             and d.get("phase")), None)
        check("a named phase can be indeterminate while generating",
              named_indeterminate is not None)
        done = sse.wait_for("job.completed", 60, lambda d: d["job_id"] == job_id)
        check("job.completed", done is not None)

        # contract 5.5: the staged fields survive the whole hop, and a phase the
        # model cannot count reports no step numbers rather than fake ones
        events = [d for _, e, d in sse.events[job_mark:]
                  if e == "job.progress" and d["job_id"] == job_id]
        phases = [d["phase"] for d in events if d.get("phase")]
        stages = [s["id"] for s in models["musicgen-small"]["capabilities"]["pipeline"]]
        # collapse the repeats within a phase, then the run must be exactly the
        # declared list once per take: every stage reported, in order, none
        # interleaved. This job asked for two takes, and a take is a whole pass
        # of the pipeline — one walk for two takes would mean the second take
        # rendered without ever saying what it was doing.
        walked = [p for i, p in enumerate(phases) if i == 0 or phases[i - 1] != p]
        check("job.progress walks the declared stages once per take, in order",
              walked == stages * 2, str(phases))

        # contract 5.5: `take` says which of `count` is rendering. Without it a
        # client can only infer the position from `fraction`, which is null for
        # exactly the adapters that cannot count — so every counter in the app
        # reported a four-take render as one piece of work.
        takes = [d["take"] for d in events if d["stage"] == "generating"]
        check("job.progress names the take it is rendering",
              bool(takes) and all(t in (0, 1) for t in takes), str(takes[:6]))
        check("take advances across the job",
              takes[:1] == [0] and takes[-1] == 1, str(takes))
        # Monotonic: a take index that went backwards would draw the render
        # walking back through takes it had already finished.
        check("take never goes backwards",
              all(b >= a for a, b in zip(takes, takes[1:])), str(takes))
        loading = [d["take"] for d in events if d["stage"] == "loading"]
        check("nothing is rendering during a load, and take says so",
              bool(loading) and all(t is None for t in loading), str(loading))
        encoding = [d["take"] for d in events if d["stage"] == "encoding"]
        check("the final encode stays on the last take rather than blanking",
              bool(encoding) and all(t == 1 for t in encoding), str(encoding))
        counted = [d for d in events if d.get("steps")]
        check("a counted phase carries step within steps",
              bool(counted) and all(d["phase"] == "lm_decode"
                                    and 1 <= d["step"] <= d["steps"]
                                    for d in counted),
              str(counted[:3]))
        uncounted = [d for d in events
                     if d.get("phase") in ("prompt_encode", "master")]
        check("an uncountable phase carries no step numbers",
              bool(uncounted) and all(d["step"] is None and d["steps"] is None
                                      for d in uncounted),
              str(uncounted[:3]))

        status, job = c.req("GET", f"/v1/jobs/{job_id}")
        ok = (status == 200 and job["status"] == "succeeded"
              and len(job["result"]["outputs"]) == 2
              and job["group_id"] == group_id)
        check("job result: 2 takes, succeeded", ok)
        wav_ok = False
        if ok:
            p = job["result"]["outputs"][0]["path"]
            if os.path.exists(p) and os.path.getsize(p) > 1000:
                with wave.open(p) as w:
                    dur = w.getnframes() / w.getframerate()
                wav_ok = abs(dur - 4.0) < 0.5
                if args.play and wav_ok:
                    subprocess.run(["afplay", p], check=False)
        check("output WAV exists with correct duration", wav_ok)

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small", "musicgen-small"],
            "prompt": "multi-model fan-out is gone"})
        check("422 on multi-model submission",
              status == 422 and body["error"]["code"] == "VALIDATION")

        # serial queue + cancel running
        _, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"],
            "prompt": "two serial jobs", "duration_s": 30})
        j1 = body["jobs"][0]["job_id"]
        _, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"],
            "prompt": "two serial jobs", "duration_s": 30})
        j2 = body["jobs"][0]["job_id"]
        sse.wait_for("job.started", 10, lambda d: d["job_id"] == j1)
        _, info2 = c.req("GET", f"/v1/jobs/{j2}")
        check("second job queued with position ≥ 1",
              info2["status"] == "queued" and info2["queue_position"] >= 1)
        status, _ = c.req("POST", f"/v1/jobs/{j1}/cancel")
        canceled = sse.wait_for("job.canceled", 10, lambda d: d["job_id"] == j1)
        check("cancel running job", status == 202 and canceled is not None)
        status, _ = c.req("POST", f"/v1/jobs/{j2}/cancel")
        check("cancel queued job", status == 202)
        status, body = c.req("POST", f"/v1/jobs/{job_id}/cancel")
        check("409 cancel terminal job",
              status == 409 and body["error"]["code"] == "JOB_NOT_CANCELABLE")

        print("• queue hold & order")
        status, _ = c.req("POST", "/v1/queue/pause")
        held = sse.wait_for("queue.state", 5, lambda d: d["held"] is True)
        check("queue pause accepted and announced",
              status == 202 and held is not None)
        _, body = c.req("GET", "/v1/system")
        check("system reports the hold", body.get("queue_held") is True)
        hold_ids = []
        for i in range(3):
            _, body = c.req("POST", "/v1/jobs", {
                "model_ids": ["musicgen-small"], "prompt": f"hold {i}",
                "duration_s": 2})
            hold_ids.append(body["jobs"][0]["job_id"])
        time.sleep(1.0)
        states = [c.req("GET", f"/v1/jobs/{j}")[1]["status"] for j in hold_ids]
        check("nothing starts while the queue is held",
              set(states) == {"queued"}, str(states))
        # contract 5.8: an explicit order beats submission order, and every
        # queued job's position is re-announced (positions move for jobs
        # nobody touched)
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/queue/order",
                          {"job_ids": [hold_ids[2], hold_ids[0]]})
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[2]}")
        check("an explicitly ordered job takes the front",
              status == 202 and info["queue_position"] == 0
              and info["priority"] > 0, str(info))
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[1]}")
        check("an unlisted job falls behind every ordered one",
              info["queue_position"] == 2 and info["priority"] == 0, str(info))
        requeued = sse.wait_for(
            "job.queued", 5,
            lambda d: d["job_id"] == hold_ids[1] and d["queue_position"] == 2,
            since=mark)
        check("a reorder re-announces the jobs nobody dragged",
              requeued is not None)
        status, body = c.req("PATCH", f"/v1/jobs/{hold_ids[1]}/priority",
                             {"priority": "high"})
        check("422 non-integer priority",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, _ = c.req("PATCH", f"/v1/jobs/{hold_ids[1]}/priority",
                          {"priority": 99})
        _, info = c.req("GET", f"/v1/jobs/{hold_ids[1]}")
        check("a priority patch overrides an earlier explicit order",
              status == 202 and info["queue_position"] == 0, str(info))
        run_mark = sse.mark()
        status, _ = c.req("POST", "/v1/queue/resume")
        released = sse.wait_for("queue.state", 5, lambda d: d["held"] is False)
        check("queue resume accepted and announced",
              status == 202 and released is not None)
        # the FIRST start after the release is the assertion: all three run
        # eventually, so waiting for this job's own start would pass on any
        # order at all
        started = sse.wait_for("job.started", 20,
                               lambda d: d["job_id"] in hold_ids,
                               since=run_mark)
        check("the job the user put first is the one that starts",
              started is not None and started["job_id"] == hold_ids[1],
              str(started))
        for j in hold_ids:
            c.req("POST", f"/v1/jobs/{j}/cancel")
        status, body = c.req("PATCH", f"/v1/jobs/{hold_ids[0]}/priority",
                             {"priority": 1})
        check("409 reordering a job that is no longer queued",
              status == 409 and body["error"]["code"] == "JOB_NOT_QUEUED",
              str(body))

        print("• uploads (audio params)")
        status, body = c.req_raw("POST", "/v1/uploads?filename=melody.wav",
                                 b"RIFF fake wav bytes")
        check("upload accepted", status == 201 and body.get("upload_id", "")
              .startswith("up_") and body["bytes"] == 19)
        upload_id = body.get("upload_id", "")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "prompt": "hum this",
            "duration_s": 2, "params": {"melody_audio": "up_nonexistent"}})
        check("422 unknown upload id",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "prompt": "hum this",
            "duration_s": 2, "params": {"melody_audio": upload_id}})
        check("job accepts audio param", status == 202)
        mel_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == mel_job)
        check("audio-param job completes", done is not None)

        print("• task jobs (separate / analyze / mix)")
        _, body = c.req("POST", "/v1/models/separation-stub/download")
        done = sse.wait_for("download.completed", 30,
                            lambda d: d["model_id"] == "separation-stub")
        check("separation-stub installs", done is not None)
        _, body = c.req("POST", "/v1/models/dsp-stub/download")
        done = sse.wait_for("download.completed", 30,
                            lambda d: d["model_id"] == "dsp-stub")
        _, body = c.req("GET", "/v1/models/dsp-stub")
        check("weightless dsp-stub installs (venv-only)",
              done is not None and body["install_state"] == "installed")

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "separate",
            "params": {"source_audio": upload_id}})
        check("promptless separate accepted", status == 202)
        sep_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == sep_job)
        check("separate job completes", done is not None)
        status, job = c.req("GET", f"/v1/jobs/{sep_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        check("separate: task echoed + null duration",
              job.get("task") == "separate" and job.get("duration_s") is None)
        check("separate: 4 stem artifacts with labels",
              len(arts) == 4 and all(a["kind"] == "stem" for a in arts)
              and {a["label"] for a in arts} == {"vocals", "drums", "bass",
                                                 "other"})
        check("separate: artifact files exist",
              all(os.path.exists(a["path"]) and os.path.getsize(a["path"]) > 1000
                  for a in arts))

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "analyze",
            "params": {"source_audio": upload_id}})
        ana_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == ana_job)
        status, job = c.req("GET", f"/v1/jobs/{ana_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        meta = (job.get("result") or {}).get("meta") or {}
        ana_ok = (done is not None and len(arts) == 1
                  and arts[0]["kind"] == "analysis"
                  and arts[0]["format"] == "json"
                  and os.path.exists(arts[0]["path"]))
        if ana_ok:
            parsed = json.load(open(arts[0]["path"]))
            ana_ok = parsed.get("tempo_bpm") == 120.0 and "beats" in parsed
        check("analyze: analysis artifact parses", ana_ok)
        check("analyze: meta summary present",
              meta.get("tempo_bpm") == 120.0 and meta.get("camelot") == "8B")

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "prompt": "x"})
        check("422 generate on task-only model",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "separate", "count": 2,
            "params": {"source_audio": upload_id}})
        check("422 count>1 on task job",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "separate",
            "lyrics": "la", "params": {"source_audio": upload_id}})
        check("422 lyrics on task job",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "remix",
            "params": {"source_audio": upload_id}})
        check("422 unknown task name",
              status == 422 and body["error"]["code"] == "VALIDATION")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["separation-stub"], "task": "separate", "params": {}})
        check("422 missing required input",
              status == 422 and "missing required input"
              in body["error"]["message"])

        spec_json = json.dumps({"target": {"bpm": 120.0},
                                "tracks": [{"source": upload_id,
                                            "gain_db": -1.5}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": spec_json}})
        check("mix job accepted", status == 202)
        mix_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == mix_job)
        status, job = c.req("GET", f"/v1/jobs/{mix_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        check("mix: audio artifact 'mixdown'",
              done is not None and len(arts) == 1
              and arts[0]["kind"] == "audio" and arts[0]["label"] == "mixdown"
              and os.path.exists(arts[0]["path"]))
        # Timeline-shaped spec: every field must survive submission verbatim
        # (upload ids aside). The fast suite is where a field-stripping
        # regression gets caught in seconds instead of a full engine run.
        timeline_spec = json.dumps({
            "target": {"bpm": 124.0, "sample_rate": 44100, "duration_s": 96.0},
            "tracks": [{"source": upload_id, "role": "vocals",
                        "gain_db": -1.5, "mute": False,
                        "offset_s": 1.9354838709677419,
                        "section": {"start_s": 43.2, "end_s": 71.9},
                        "fade_in_s": 0.25, "fade_out_s": 2.0,
                        "source_bpm": 98.0, "source_downbeats": [0.51, 2.96],
                        "stretch": {"mode": "beat", "transient_mode": "smooth",
                                    "preserve_formants": True},
                        "pitch_shift_st": 2.0}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": timeline_spec}})
        check("timeline-shaped mix_spec accepted", status == 202)
        tl_job = body["jobs"][0]["job_id"]
        _, tl_info = c.req("GET", f"/v1/jobs/{tl_job}")
        echoed = json.loads(tl_info["params"]["mix_spec"])
        track = (echoed.get("tracks") or [{}])[0]
        check("mix_spec fields survive submission verbatim",
              echoed["target"].get("duration_s") == 96.0
              and track.get("offset_s") == 1.9354838709677419
              and track.get("fade_in_s") == 0.25
              and track.get("fade_out_s") == 2.0
              and (track.get("section") or {}).get("end_s") == 71.9
              and track.get("source") != upload_id,   # resolved to a path
              json.dumps(track)[:200])

        # Editor-shaped spec: reverse + effects chain survive verbatim, and
        # the output params reshape the artifact (contract 5.4).
        edit_spec = json.dumps({
            "target": {"sample_rate": 44100},
            "tracks": [{"source": upload_id, "role": "edit",
                        "gain_db": 0.0, "offset_s": 0.0,
                        "reverse": True, "fade_in_curve": "scurve",
                        "effects": [
                            {"type": "highpass", "cutoff_hz": 80.0},
                            {"type": "eq3", "low_db": 2.5, "mid_db": 0.0,
                             "high_db": 1.5},
                            {"type": "compressor", "threshold_db": -18.0,
                             "ratio": 3.0, "attack_ms": 8.0,
                             "release_ms": 120.0},
                            {"type": "gate", "threshold_db": -54.0}],
                        "stretch": {"mode": "none",
                                    "transient_mode": "smooth",
                                    "preserve_formants": True},
                        "pitch_shift_st": 0.0}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": edit_spec, "normalize": False,
                       "limiter": False, "output_format": "flac",
                       "bit_depth": "pcm24"}})
        check("editor-shaped mix accepted", status == 202)
        ed_job = body["jobs"][0]["job_id"]
        _, ed_info = c.req("GET", f"/v1/jobs/{ed_job}")
        ed_track = (json.loads(ed_info["params"]["mix_spec"])
                    .get("tracks") or [{}])[0]
        check("reverse + effects survive submission verbatim",
              ed_track.get("reverse") is True
              and ed_track.get("fade_in_curve") == "scurve"
              and [fx.get("type") for fx in (ed_track.get("effects") or [])]
              == ["highpass", "eq3", "compressor", "gate"]
              and ed_info["params"].get("normalize") is False
              and ed_info["params"].get("limiter") is False,
              json.dumps(ed_track)[:200])
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == ed_job)
        _, ed_done = c.req("GET", f"/v1/jobs/{ed_job}")
        ed_arts = (ed_done.get("result") or {}).get("artifacts") or []
        ed_meta = (ed_done.get("result") or {}).get("meta") or {}
        check("output_format reshapes the mixdown artifact",
              done is not None and len(ed_arts) == 1
              and ed_arts[0]["format"] == "flac"
              and ed_arts[0]["path"].endswith("mixdown.flac")
              and os.path.exists(ed_arts[0]["path"]))
        check("normalize=false drops lufs from meta", "lufs" not in ed_meta)
        # float32 FLAC is impossible; the job must fail, not emit a lie
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": edit_spec, "output_format": "flac",
                       "bit_depth": "float32"}})
        check("float32 flac job accepted then fails", status == 202)
        f32_job = body["jobs"][0]["job_id"]
        failed = sse.wait_for("job.failed", 60,
                              lambda d: d["job_id"] == f32_job)
        check("float32 flac fails the job", failed is not None)

        bad_spec = json.dumps({"tracks": [{"source": "up_nope"}]})
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": bad_spec}})
        check("422 unknown upload inside mix_spec",
              status == 422 and "up_nope" in body["error"]["message"])
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix",
            "params": {"mix_spec": "not json{"}})
        check("422 invalid JSON in json param",
              status == 422 and body["error"]["code"] == "VALIDATION")

        print("• task jobs (transcribe / render)")
        c.req("POST", "/v1/models/transcription-stub/download")
        done = sse.wait_for("download.completed", 60,
                            lambda d: d["model_id"] == "transcription-stub")
        check("transcription-stub installs", done is not None)
        c.req("POST", "/v1/models/render-stub/download")
        done = sse.wait_for("download.completed", 60,
                            lambda d: d["model_id"] == "render-stub")
        check("render-stub installs", done is not None)

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["transcription-stub"], "task": "transcribe",
            "params": {"source_audio": upload_id}})
        check("transcribe job accepted", status == 202)
        tr_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == tr_job)
        _, job = c.req("GET", f"/v1/jobs/{tr_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        midis = [a for a in arts if a["kind"] == "midi"]
        previews = {a["label"] for a in arts if a["kind"] == "audio"}
        midi_ok = (done is not None and len(midis) == 2
                   and all(os.path.exists(a["path"]) for a in midis)
                   and all(open(a["path"], "rb").read(4) == b"MThd"
                           for a in midis))
        check("transcribe: midi artifacts parse", midi_ok)
        check("transcribe: previews paired",
              all(f"preview:{a['label']}" in previews for a in midis))

        midi_bytes = open(midis[0]["path"], "rb").read() if midis else b"MThd"
        status, up = c.req_raw("POST", "/v1/uploads?filename=notes.mid",
                               midi_bytes)
        check("midi upload accepted", status == 201)
        midi_upload = up.get("upload_id", "")
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["render-stub"], "task": "render",
            "params": {"midi_file": midi_upload}})
        check("render job accepted", status == 202)
        r_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60,
                            lambda d: d["job_id"] == r_job)
        _, job = c.req("GET", f"/v1/jobs/{r_job}")
        arts = (job.get("result") or {}).get("artifacts") or []
        check("render: audio artifact",
              done is not None and len(arts) == 1
              and arts[0]["kind"] == "audio" and arts[0]["label"] == "render"
              and os.path.exists(arts[0]["path"]))
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["render-stub"], "task": "render",
            "params": {"midi_file": "up_bogus"}})
        check("422 unknown midi upload id",
              status == 422 and body["error"]["code"] == "VALIDATION")

        print("• task jobs (caption / lyrics / tag / compose)")
        for mid in ("caption-stub", "lyrics-stub", "notation-stub"):
            c.req("POST", f"/v1/models/{mid}/download")
            done = sse.wait_for("download.completed", 60,
                                lambda d, m=mid: d["model_id"] == m)
            check(f"{mid} installs", done is not None)

        def run_text_task(model_id, task, params):
            status, body = c.req("POST", "/v1/jobs", {
                "model_ids": [model_id], "task": task, "params": params})
            if status != 202:
                return None, None, status
            job_id = body["jobs"][0]["job_id"]
            sse.wait_for("job.completed", 60,
                         lambda d: d["job_id"] == job_id)
            _, job = c.req("GET", f"/v1/jobs/{job_id}")
            return job, (job.get("result") or {}), 202

        job, result, status = run_text_task(
            "caption-stub", "caption", {"source_audio": upload_id})
        arts = result.get("artifacts") or []
        meta = result.get("meta") or {}
        cap_ok = (status == 202 and len(arts) == 1
                  and arts[0]["kind"] == "text"
                  and arts[0]["format"] == "json"
                  and arts[0]["label"] == "caption"
                  and os.path.exists(arts[0]["path"]))
        if cap_ok:
            parsed = json.load(open(arts[0]["path"]))
            cap_ok = (parsed.get("kind") == "caption"
                      and parsed.get("text")
                      # contract: the whole payload also rides result.meta
                      and meta.get("text") == parsed
                      and meta.get("caption_preview")
                      == parsed["text"][:200])
        check("caption: text artifact parses and meta mirrors it", cap_ok)

        job, result, status = run_text_task(
            "caption-stub", "caption",
            {"source_audio": upload_id, "question": "What key is this in?"})
        meta = result.get("meta") or {}
        check("caption: question echoed through payload and meta",
              status == 202
              and (meta.get("text") or {}).get("question")
              == "What key is this in?"
              and meta.get("question") == "What key is this in?")

        job, result, status = run_text_task(
            "lyrics-stub", "lyrics", {"source_audio": upload_id})
        arts = result.get("artifacts") or []
        meta = result.get("meta") or {}
        lyr_ok = (status == 202 and len(arts) == 1
                  and arts[0]["kind"] == "text"
                  and os.path.exists(arts[0]["path"]))
        if lyr_ok:
            parsed = json.load(open(arts[0]["path"]))
            segs = parsed.get("segments") or []
            lyr_ok = (parsed.get("kind") == "lyrics" and len(segs) >= 2
                      # segments are timed and monotonic
                      and all(s["start_s"] < s["end_s"] for s in segs)
                      and all(a["end_s"] <= b["start_s"]
                              for a, b in zip(segs, segs[1:]))
                      and meta.get("segments") == len(segs)
                      and meta.get("language") == parsed.get("language"))
        check("lyrics: timed segments, monotonic, meta summary", lyr_ok)

        job, result, status = run_text_task(
            "caption-stub", "tag", {"source_audio": upload_id})
        arts = result.get("artifacts") or []
        meta = result.get("meta") or {}
        tag_ok = (status == 202 and len(arts) == 1
                  and arts[0]["kind"] == "text"
                  and os.path.exists(arts[0]["path"]))
        if tag_ok:
            parsed = json.load(open(arts[0]["path"]))
            tags = parsed.get("tags") or []
            tag_ok = (parsed.get("kind") == "tags" and tags
                      and all(0.0 <= t["score"] <= 1.0 for t in tags
                              if t.get("score") is not None)
                      and all(t.get("group") in ("genre", "mood",
                                                 "instrument")
                              for t in tags)
                      and meta.get("top_tags")
                      == [t["label"] for t in tags])
        check("tag: scored, grouped tags with meta top_tags", tag_ok)

        job, result, status = run_text_task(
            "notation-stub", "compose",
            {"prompt": "a cheerful folk tune in D"})
        arts = result.get("artifacts") or []
        meta = result.get("meta") or {}
        texts = [a for a in arts if a["kind"] == "text"]
        midis = [a for a in arts if a["kind"] == "midi"]
        abc_ok = (status == 202 and len(texts) == 1 and len(midis) == 1
                  and midis[0]["label"] == "composition"
                  and os.path.exists(texts[0]["path"])
                  and open(midis[0]["path"], "rb").read(4) == b"MThd")
        if abc_ok:
            parsed = json.load(open(texts[0]["path"]))
            abc_ok = (parsed.get("kind") == "abc"
                      and str(parsed.get("text") or "").startswith("X:")
                      and meta.get("abc_preview"))
        check("compose: ABC text + paired midi", abc_ok)

        # compose's primary input is a string param, which submit validation
        # does not presence-check — the worker fails the job instead
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["notation-stub"], "task": "compose", "params": {}})
        check("compose with no prompt is accepted then fails in the worker",
              status == 202)
        if status == 202:
            empty_job = body["jobs"][0]["job_id"]
            failed = sse.wait_for("job.failed", 60,
                                  lambda d: d["job_id"] == empty_job)
            check("compose empty-prompt job fails", failed is not None)

        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "task": "caption",
            "params": {"source_audio": upload_id}})
        check("422 caption on a model that does not declare it",
              status == 422 and body["error"]["code"] == "VALIDATION")

        status, body = c.req_raw("POST", "/v1/uploads?filename=long.wav",
                                 b"\x00" * (101 * 1024 * 1024), timeout=60)
        check("101 MB upload accepted (cap now 256 MB)",
              status == 201 and body.get("bytes") == 101 * 1024 * 1024)
        status, body = c.req_raw("POST", "/v1/uploads?filename=huge.wav",
                                 b"\x00" * (257 * 1024 * 1024), timeout=60)
        check("257 MB upload rejected",
              status == 422 and body["error"]["code"] == "VALIDATION")

        print("• streaming render previews")
        # contract 5.6: declared per model, because only some adapters can
        # decode audio the model has genuinely produced part-way through
        check("preview support is declared per model",
              models["musicgen-small"]["capabilities"].get("supports_preview")
              is True
              and models["stableaudio-small"]["capabilities"]
              .get("supports_preview") is True
              and all("supports_preview" not in models[m]["capabilities"]
                      for m in ("acestep-base", "separation-stub", "dsp-stub",
                                "render-stub")),
              str({k: v["capabilities"].get("supports_preview")
                   for k, v in models.items()}))
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["dsp-stub"], "task": "mix", "preview": True,
            "params": {"mix_spec": spec_json}})
        check("422 preview on a model that cannot",
              status == 422 and body["error"]["code"] == "VALIDATION")
        # the job just run without asking must have produced nothing: previews
        # are opt-in precisely because they cost a decode apiece
        check("no previews for a job that did not ask",
              not [d for _, e, d in sse.events[job_mark:]
                   if e == "job.preview" and d["job_id"] == job_id])

        c.req("POST", "/v1/models/stableaudio-small/download")
        done = sse.wait_for("download.completed", 30,
                            lambda d: d["model_id"] == "stableaudio-small")
        check("stableaudio-small installs", done is not None)

        pv_mark = sse.mark()
        status, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["musicgen-small"], "prompt": "watch it render",
            "duration_s": 4, "preview": True})
        check("preview job accepted", status == 202)
        pv_job = body["jobs"][0]["job_id"]
        _, info = c.req("GET", f"/v1/jobs/{pv_job}")
        check("job echoes the preview flag", info.get("preview") is True)
        first = sse.wait_for("job.preview", 30,
                             lambda d: d["job_id"] == pv_job, since=pv_mark)
        wav_ok = False
        if first is not None and os.path.exists(first["path"]):
            with wave.open(first["path"]) as w:
                rate = w.getframerate()
                heard = w.getnframes() / rate
            wav_ok = (abs(heard - first["duration_s"]) < 0.1
                      and rate == first["sample_rate"])
        check("job.preview names a readable wav of the length it claims",
              wav_ok, str(first))
        out_root = os.path.realpath(os.path.join(tmp, "outputs", pv_job))
        check("preview lives under the job's own output directory",
              first is not None
              and os.path.realpath(first["path"]).startswith(out_root + os.sep),
              str(first))
        done = sse.wait_for("job.completed", 60, lambda d: d["job_id"] == pv_job)
        grew = [d["duration_s"] for _, e, d in sse.events[pv_mark:]
                if e == "job.preview" and d["job_id"] == pv_job]
        # an autoregressive model has MORE audio each frame; the app sizes the
        # decoded span from duration_s alone, so this shape has to be produced
        check("an autoregressive preview grows a frame at a time",
              done is not None and len(grew) >= 2 and grew[0] < grew[-1]
              and grew == sorted(grew) and grew[0] < 4.0, str(grew))
        check("previews are gone once the take succeeds",
              not [n for n in os.listdir(out_root) if n.startswith("preview-")],
              str(os.listdir(out_root)))

        sa_mark = sse.mark()
        _, body = c.req("POST", "/v1/jobs", {
            "model_ids": ["stableaudio-small"], "prompt": "diffuse it",
            "duration_s": 4, "preview": True})
        sa_job = body["jobs"][0]["job_id"]
        done = sse.wait_for("job.completed", 60, lambda d: d["job_id"] == sa_job)
        spans = [d["duration_s"] for _, e, d in sse.events[sa_mark:]
                 if e == "job.preview" and d["job_id"] == sa_job]
        # a diffusion model decodes the WHOLE clip from its first frame and only
        # gets cleaner — the other shape the same UI has to draw
        check("a diffusion preview covers the whole clip from the start",
              done is not None and len(spans) >= 2
              and all(abs(s - 4.0) < 0.01 for s in spans), str(spans))
        steps = [d["step"] for _, e, d in sse.events[sa_mark:]
                 if e == "job.preview" and d["job_id"] == sa_job]
        check("a preview carries the step it was decoded at",
              bool(steps) and all(s is not None and 1 <= s <= 8 for s in steps),
              str(steps))

        print("• pin (keep model loaded)")
        status, body = c.req("PUT", "/v1/models/nope/pin", {"enabled": True})
        check("404 pin unknown model", status == 404)
        status, body = c.req("PUT", "/v1/models/acestep-base/pin",
                             {"enabled": True})
        check("409 pin uninstalled model",
              status == 409 and body["error"]["code"] == "MODEL_NOT_INSTALLED")
        mark = sse.mark()
        status, _ = c.req("PUT", "/v1/models/musicgen-small/pin",
                          {"enabled": True})
        loaded = sse.wait_for("worker.state", 5,
                              lambda d: d["state"] == "loaded"
                              and d["model_id"] == "musicgen-small", since=mark)
        check("pin → 202 + worker.state loaded", status == 202 and loaded)
        _, body = c.req("GET", "/v1/models/musicgen-small")
        check("model reports pinned", body.get("pinned") is True)
        _, body = c.req("GET", "/v1/system")
        check("system reports warm/pinned model",
              body.get("warm_model_id") == "musicgen-small"
              and body.get("pinned_model_id") == "musicgen-small")
        # a resident model is a live worker, so now there IS memory to report
        usage = body.get("usage") or {}
        check("resident model reports its memory",
              (usage.get("worker_bytes") or 0) > 0
              and 0 < (usage.get("accelerator_bytes") or 0) <= usage["worker_bytes"],
              str(usage))
        # contract 6: the same object arrives unprompted, so the sidebar stays
        # live without polling. wait_for scans what already arrived, so this
        # only ever blocks on a suite faster than the idle 10 s cadence.
        tele = sse.wait_for("system.telemetry", 12)
        check("system.telemetry event carries the usage object",
              tele is not None and set(tele) == {"gpu_percent", "worker_bytes",
                                                 "accelerator_bytes"},
              str(tele))
        status, _ = c.req("PUT", "/v1/models/musicgen-small/pin",
                          {"enabled": False})
        _, body = c.req("GET", "/v1/system")
        check("unpin keeps the model resident",
              status == 202 and body.get("warm_model_id") == "musicgen-small")
        mark = sse.mark()
        status, _ = c.req("POST", "/v1/worker/unload")
        stopped = sse.wait_for("worker.state", 5,
                               lambda d: d["state"] == "stopped", since=mark)
        check("unload → worker.state stopped", status == 202 and stopped)
        _, body = c.req("GET", "/v1/system")
        check("system clear after unload", body.get("warm_model_id") is None)

        print("• SSE replay & shutdown")
        # contract 6: the heartbeat is on a clock, not on silence — telemetry
        # events now fill every gap shorter than 15 s, and a heartbeat that
        # waited for a quiet stream would never fire again
        deadline = time.time() + 20
        while time.time() < deadline and sse.heartbeats == 0:
            time.sleep(0.25)
        check("SSE heartbeat survives the telemetry stream", sse.heartbeats > 0)
        with sse.lock:
            mid_id = sse.events[len(sse.events) // 2][0]
            expected = [e for e in sse.events if e[0] > mid_id]
        sse2 = SSEListener(hs["port"], token, last_event_id=str(mid_id))
        sse2.start()
        time.sleep(1.0)
        with sse2.lock:
            replayed = list(sse2.events)
        check("Last-Event-ID replay",
              len(replayed) >= len(expected)
              and [r[0] for r in replayed[:len(expected)]] == [e[0] for e in expected])
        sse2.stop()

        status, _ = c.req("POST", "/v1/shutdown")
        check("POST /v1/shutdown accepted", status == 202)
        try:
            proc.wait(timeout=10)
            check("engine exits after shutdown", True)
        except subprocess.TimeoutExpired:
            check("engine exits after shutdown", False)
        sse.stop()
        return report()
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()



if __name__ == "__main__":
    sys.exit(main())
