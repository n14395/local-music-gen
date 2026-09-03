#!/usr/bin/env python3
"""Generation smoke test against the real engine, driven over HTTP.

Downloads the model if needed (into a persistent data dir so weights are reused),
submits a job, follows SSE progress, and asserts the WAV is real: exists, non-silent
(RMS), duration within tolerance, progress monotonic.

Usage:
  python3 scripts/smoke_test.py --model test-tiny --duration 2
  python3 scripts/smoke_test.py --model musicgen-small --duration 5 --play
  python3 scripts/smoke_test.py --task separate --model separation-htdemucs \
      --input song.wav
  python3 scripts/smoke_test.py --task analyze --model analysis-basic \
      --input click_120bpm.wav --expect-bpm 120
"""

from __future__ import annotations

import argparse
import array
import json
import math
import os
import secrets
import signal
import subprocess
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from contractlib import Client, SSEListener, check, report  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUP = os.path.join(ROOT, "engine", "supervisor")
DEFAULT_DATA = os.path.expanduser("~/Library/Application Support/LocalMusic")


def drain(sse, cursor: int, event: str, pred):
    """All `event` events past `cursor` that match pred → (new_cursor, matches).

    wait_for() rescans from `since` and returns the FIRST match, so polling it
    in a loop replays the same earliest event forever; progress consumers need
    a moving cursor."""
    with sse.lock:
        chunk = list(sse.events[cursor:])
        new_cursor = len(sse.events)
    return new_cursor, [d for _, e, d in chunk if e == event and pred(d)]


def wav_stats(path: str) -> tuple[float | None, int | None]:
    """(duration_s, rms) best effort — PCM16 via stdlib; None on other formats."""
    try:
        with wave.open(path) as w:
            frames = w.readframes(w.getnframes())
            dur = w.getnframes() / w.getframerate()
            if w.getsampwidth() != 2:
                return dur, None
        samples = array.array("h", frames)
        rms = int(math.sqrt(sum(s * s for s in samples) / max(1, len(samples))))
        return dur, rms
    except (wave.Error, OSError, EOFError):
        return None, None


try:
    import audio_stats  # sibling module; numpy-based, reads float32 WAVs too
except Exception:  # noqa: BLE001 — stats degrade, the suite still runs
    audio_stats = None


def full_stats(path: str):
    """(duration_s, rms_dbfs, channels, sample_rate, flatness).

    The old RMS>100 gate passed white noise and silently skipped float32
    stems (audit H8); with numpy present this reads every WAV the engine
    writes and adds a spectral-flatness figure (music < ~0.1, noise > 0.35).
    Fields are None where the available reader cannot tell.
    """
    if audio_stats is not None:
        try:
            x, sr = audio_stats.load(path)
            mono = x.mean(axis=0)
            rms = float((mono ** 2).mean() ** 0.5)
            dbfs = 20 * math.log10(rms + 1e-20)
            flat = audio_stats.flatness(mono, sr)
            if flat != flat:  # NaN — clip too short to frame
                flat = None
            return (mono.size / sr, dbfs, int(x.shape[0]), int(sr), flat)
        except Exception:  # noqa: BLE001 — fall through to the stdlib reader
            pass
    dur, rms = wav_stats(path)
    dbfs = None if rms is None else 20 * math.log10(max(rms, 1) / 32768.0)
    ch = sr = None
    try:
        with wave.open(path) as w:
            ch, sr = w.getnchannels(), w.getframerate()
    except (wave.Error, OSError, EOFError):
        pass
    return dur, dbfs, ch, sr, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="musicgen-small")
    ap.add_argument("--duration", type=float, default=5)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--prompt", default="warm lo-fi beat with vinyl crackle")
    ap.add_argument("--lyrics", default=None)
    ap.add_argument("--melody", default=None,
                    help="path to reference audio for melody-conditioned models")
    ap.add_argument("--audio-param", action="append", default=[],
                    help="generate-path audio param key=path — uploads the "
                         "file and passes its upload id (repeatable)")
    ap.add_argument("--task", default=None,
                    choices=["separate", "analyze", "transcribe", "render",
                             "caption", "lyrics", "tag", "compose"],
                    help="run a task job on --input instead of generating")
    ap.add_argument("--input", default=None,
                    help="source file for task jobs (audio; a .mid for render)")
    ap.add_argument("--expect-bpm", type=float, default=None,
                    help="analyze only: assert detected tempo within ±3 BPM")
    ap.add_argument("--expect-clap", action="store_true",
                    help="analyze only: assert a 512-dim CLAP embedding")
    ap.add_argument("--param", action="append", default=[],
                    help="extra task param key=value (repeatable)")
    ap.add_argument("--data-dir", default=DEFAULT_DATA)
    ap.add_argument("--play", action="store_true")
    ap.add_argument("--gen-timeout", type=float, default=1800)
    args = ap.parse_args()

    token = secrets.token_hex(16)
    handshake = os.path.join(args.data_dir, "Backend", "smoke-handshake.json")
    os.makedirs(os.path.dirname(handshake), exist_ok=True)
    if os.path.exists(handshake):
        os.unlink(handshake)

    proc = subprocess.Popen(
        ["uv", "run", "local-music-engine",
         "--handshake-file", handshake, "--parent-pid", str(os.getpid()),
         "--data-dir", args.data_dir,
         "--output-dir", os.path.join(args.data_dir, "Outputs"),
         "--log-level", "warning"],
        cwd=SUP, env={**os.environ, "LOCALMUSIC_AUTH_TOKEN": token,
                      "LOCALMUSIC_TEST_CATALOG": "1"},
        stderr=None, stdout=subprocess.DEVNULL)

    try:
        deadline = time.time() + 60
        while not os.path.exists(handshake) and time.time() < deadline:
            if proc.poll() is not None:
                check("engine started", False)
                return report()
            time.sleep(0.2)
        hs = json.load(open(handshake))
        c = Client(hs["port"], token)
        check("engine started", True)

        # hand over the user's HF token (gated repos) if one is available
        hf_token = os.environ.get("HF_TOKEN")
        token_file = os.path.expanduser("~/.cache/huggingface/token")
        if not hf_token and os.path.exists(token_file):
            hf_token = open(token_file).read().strip()
        if hf_token:
            c.req("POST", "/v1/settings/hf-token", {"token": hf_token})

        sse = SSEListener(hs["port"], token)
        sse.start()

        status, model = c.req("GET", f"/v1/models/{args.model}")
        if status != 200:
            check(f"model {args.model} exists", False, f"HTTP {status}")
            return report()
        if model["install_state"] != "installed":
            print(f"• downloading {args.model} "
                  f"({model['size_bytes'] / 1e9:.1f} GB)…")
            status, _ = c.req("POST", f"/v1/models/{args.model}/download")
            check("download accepted", status == 202)
            last_print = 0.0
            done = None
            cursor = sse.mark()
            end = time.time() + 7200
            while time.time() < end:
                done = sse.wait_for("download.completed", 5,
                                    lambda d: d["model_id"] == args.model)
                if done is not None:
                    break
                failed = sse.wait_for("download.failed", 0.1,
                                      lambda d: d["model_id"] == args.model)
                if failed is not None:
                    check("download completed", False, str(failed.get("error")))
                    return report()
                cursor, progs = drain(sse, cursor, "download.progress",
                                      lambda d: d["model_id"] == args.model)
                if progs and time.time() - last_print > 10:
                    prog = progs[-1]
                    pct = 100 * prog["bytes_done"] / max(1, prog["bytes_total"])
                    print(f"  {pct:5.1f}%  {prog['bytes_done'] / 1e9:.2f} GB "
                          f"({prog.get('stage')})")
                    last_print = time.time()
            check("download completed", done is not None)
            if done is None:
                return report()

        if args.task:
            params: dict = {}
            if args.task == "compose":
                # compose is text-in: its input is the string param `prompt`
                # (the top-level prompt field is not forwarded to task
                # workers), so there is nothing to upload
                params["prompt"] = args.prompt
            else:
                if not args.input or not os.path.exists(args.input):
                    check("task jobs need an existing --input file", False)
                    return report()
                with open(args.input, "rb") as f:
                    data = f.read()
                status, up = c.req_raw(
                    "POST",
                    f"/v1/uploads?filename={os.path.basename(args.input)}",
                    data)
                check("input uploaded", status == 201 and "upload_id" in up)
                input_key = ("midi_file" if args.task == "render"
                             else "source_audio")
                params[input_key] = up["upload_id"]
            for kv in args.param:
                k, _, v = kv.partition("=")
                try:
                    params[k] = json.loads(v)
                except json.JSONDecodeError:
                    params[k] = v
            print(f"• {args.task} with {args.model} "
                  f"(first run provisions the venv — can take minutes)…")
            body = {"model_ids": [args.model], "task": args.task,
                    "params": params}
        else:
            print(f"• generating {args.duration:.0f}s with {args.model} "
                  f"(first run provisions the venv — can take minutes)…")
            body = {"model_ids": [args.model], "prompt": args.prompt,
                    "duration_s": args.duration, "count": args.count}
            if args.lyrics:
                body["lyrics"] = args.lyrics
            if args.param:
                body["params"] = dict(body.get("params") or {})
                for kv in args.param:
                    k, _, v = kv.partition("=")
                    try:
                        body["params"][k] = json.loads(v)
                    except json.JSONDecodeError:
                        body["params"][k] = v
            audio_params = list(args.audio_param)
            if args.melody:
                audio_params.append(f"melody_audio={args.melody}")
            if audio_params:
                body["params"] = dict(body.get("params") or {})
                for kv in audio_params:
                    k, _, p = kv.partition("=")
                    with open(p, "rb") as f:
                        data = f.read()
                    status, up = c.req_raw(
                        "POST", f"/v1/uploads?filename={os.path.basename(p)}",
                        data)
                    check(f"{k} uploaded", status == 201 and "upload_id" in up)
                    body["params"][k] = up["upload_id"]
        status, resp = c.req("POST", "/v1/jobs", body)
        check("job accepted", status == 202, json.dumps(resp))
        if status != 202:
            return report()
        job_id = resp["jobs"][0]["job_id"]

        fractions: list[float] = []
        phases_seen: set[str] = set()
        gen_started = time.time()
        last_msg = ""
        last_print = 0.0
        cursor = sse.mark()
        # telemetry arrives unprompted on the same stream; showing it beside the
        # progress line is the cheapest way to sanity-check the readout against
        # a real render (GPU% is device-wide, not this job's share)
        tele_cursor = sse.mark()
        tele = {}
        end = time.time() + args.gen_timeout
        outcome = None
        while time.time() < end:
            done = sse.wait_for("job.completed", 2,
                                lambda d: d["job_id"] == job_id)
            if done is not None:
                outcome = "completed"
                break
            failed = sse.wait_for("job.failed", 0.1,
                                  lambda d: d["job_id"] == job_id)
            if failed is not None:
                outcome = f"failed: {failed.get('error')}"
                break
            tele_cursor, telemetry = drain(sse, tele_cursor, "system.telemetry",
                                           lambda d: True)
            if telemetry:
                tele = telemetry[-1]
            cursor, progs = drain(sse, cursor, "job.progress",
                                  lambda d: d["job_id"] == job_id
                                  and d["stage"] == "generating")
            for prog in progs:
                # fraction is null when the model does not know (contract 5.5);
                # such an event breaks no ordering, it just carries no number
                frac = prog["fraction"]
                if frac is not None:
                    fractions.append(frac)
                if prog.get("phase"):
                    phases_seen.add(prog["phase"])
                if prog["message"] != last_msg and time.time() - last_print > 2:
                    last_msg = prog["message"]
                    last_print = time.time()
                    pct = "    ?%" if frac is None else f"{frac * 100:5.1f}%"
                    phase = f"[{prog['phase']}] " if prog.get("phase") else ""
                    bits = []
                    if tele.get("gpu_percent") is not None:
                        bits.append(f"gpu {tele['gpu_percent']}%")
                    if tele.get("worker_bytes"):
                        bits.append(f"{tele['worker_bytes'] / 1e9:.1f} GB")
                    usage = f"  ({', '.join(bits)})" if bits else ""
                    print(f"  {pct}  {phase}{last_msg}{usage}")
        check("job completed", outcome == "completed", str(outcome))
        if outcome != "completed":
            return report()
        check("progress monotonic",
              all(a <= b + 1e-6 for a, b in zip(fractions, fractions[1:])),
              str(fractions[:40]))
        # Every reported phase must be one the catalog declared: a typo'd or
        # renamed phase parks the app's stage list forever (audit H8 — one
        # assertion here would have caught most of the audit's §5 findings).
        declared = [s["id"] for s in
                    (model.get("capabilities") or {}).get("pipeline") or []]
        if declared:
            stray = sorted(p for p in phases_seen if p not in declared)
            check("phases within declared pipeline", not stray,
                  f"stray={stray} declared={declared}")
        # A long job whose every fraction was exactly 0.0 is the frozen-zero
        # signature (audit H1) — honest indeterminates send null and land in
        # no list at all, so an empty list passes.
        if len(fractions) >= 3 and time.time() - gen_started > 30:
            check("progress not frozen at 0",
                  max(fractions) > 0.0, f"{len(fractions)} events, all 0.0")

        _, job = c.req("GET", f"/v1/jobs/{job_id}")

        if args.task:
            arts = (job.get("result") or {}).get("artifacts") or []
            check("artifacts reported", len(arts) >= 1,
                  str([(a.get("kind"), a.get("label")) for a in arts]))
            in_dur = wav_stats(args.input)[0] if args.input else None
            if args.task == "separate":
                stems = [a for a in arts if a["kind"] == "stem"]
                # a single-target request (BSRNN `targets=vocals`) is one
                # stem by design
                one_target = str((body.get("params") or {})
                                 .get("targets") or "all") != "all"
                want = 1 if one_target else 2
                check(f"at least {want} stem(s)", len(stems) >= want,
                      str([a["label"] for a in arts]))
                levels = []
                for a in stems:
                    ok = os.path.exists(a["path"]) and os.path.getsize(a["path"]) > 1000
                    check(f"stem exists: {a['label']}", ok)
                    dur, dbfs, _ch, _sr, _flat = full_stats(a["path"])
                    if in_dur and dur:
                        check(f"stem duration matches input ({a['label']})",
                              abs(dur - in_dur) <= 0.05 * in_dur + 0.5)
                    if dbfs is not None:
                        levels.append(dbfs)
                        print(f"  {a['label']}: {dbfs:.1f} dBFS")
                # full_stats reads float32 stems too — the old PCM16-only
                # reader skipped this check on them silently (audit H8)
                check("stem levels readable", bool(levels),
                      "no stem produced a readable level")
                if levels:
                    check("at least one non-silent stem", max(levels) > -50)
                for a in stems:
                    print(f"  → {a['path']}")
                if args.play and stems:
                    subprocess.run(["afplay", stems[0]["path"]], check=False)
            elif args.task == "transcribe":
                midis = [a for a in arts if a["kind"] == "midi"]
                previews = {a["label"]: a for a in arts
                            if a["label"].startswith("preview:")}
                check("at least 1 midi artifact", len(midis) >= 1,
                      str([a["label"] for a in arts]))
                for a in midis:
                    with open(a["path"], "rb") as f:
                        magic = f.read(4)
                    check(f"midi parses: {a['label']}", magic == b"MThd")
                    preview = previews.get(f"preview:{a['label']}")
                    ok = preview is not None and os.path.exists(preview["path"])
                    check(f"preview paired: {a['label']}", ok)
                    if ok:
                        _dur, rms = wav_stats(preview["path"])
                        check(f"preview non-silent: {a['label']}",
                              rms is None or rms > 100)
                    print(f"  → {a['path']}")
                if (body.get("params") or {}).get("emit_abc"):
                    # Asked for notation, so its absence is a failure rather
                    # than a quiet degradation — without this the whole ABC
                    # path can pass while writing nothing at all.
                    texts = [a for a in arts if a["kind"] == "text"]
                    meta = (job.get("result") or {}).get("meta") or {}
                    check("emit_abc: one text artifact per notated track",
                          len(texts) >= 1,
                          f"none written; meta says: {meta.get('abc_error')}")
                    for a in texts:
                        payload = json.load(open(a["path"]))
                        abc = str(payload.get("text") or "")
                        check(f"ABC parses as a tune: {a['label']}",
                              payload.get("kind") == "abc"
                              and abc.lstrip().startswith("X:"), abc[:60])
                        print(f"  → {a['label']}: {len(abc)} chars")
            elif args.task == "render":
                audio_arts = [a for a in arts if a["kind"] == "audio"]
                check("one audio artifact", len(audio_arts) == 1)
                if audio_arts:
                    a = audio_arts[0]
                    _dur, rms = wav_stats(a["path"])
                    check(f"render non-silent (rms={rms})",
                          rms is not None and rms > 100)
                    print(f"  → {a['path']}")
                    if args.play:
                        subprocess.run(["afplay", a["path"]], check=False)
            elif args.task == "analyze":
                ana = next((a for a in arts if a["kind"] == "analysis"), None)
                check("analysis artifact present", ana is not None)
                if ana:
                    payload = json.load(open(ana["path"]))
                    check("tempo/key/beats present",
                          all(k in payload for k in
                              ("tempo_bpm", "camelot", "beats")),
                          str(sorted(payload.keys())))
                    meta = (job.get("result") or {}).get("meta") or {}
                    check("meta mirrors headline numbers",
                          "tempo_bpm" in meta and "camelot" in meta)
                    print(f"  tempo={payload.get('tempo_bpm')} "
                          f"key={payload.get('key')} "
                          f"camelot={payload.get('camelot')} "
                          f"lufs={payload.get('lufs')}")
                    if args.expect_bpm:
                        got = payload.get("tempo_bpm") or 0
                        folded = min(abs(got - args.expect_bpm),
                                     abs(got * 2 - args.expect_bpm),
                                     abs(got / 2 - args.expect_bpm))
                        check(f"tempo {got:.1f} within ±3 of "
                              f"{args.expect_bpm:.0f}", folded <= 3.0)
                    if args.expect_clap:
                        vec = payload.get("clap") or []
                        norm = math.sqrt(sum(v * v for v in vec))
                        check("512-dim unit CLAP embedding present",
                              len(vec) == 512 and abs(norm - 1.0) < 0.01,
                              f"len={len(vec)} norm={norm:.3f}")
                    if "prompt_text" in (body.get("params") or {}):
                        score = payload.get("clap_prompt_score")
                        check("clap_prompt_score present and in range",
                              isinstance(score, (int, float))
                              and -1.0 <= score <= 1.0, str(score))
                        check("clap_prompt echoes the scored text",
                              payload.get("clap_prompt")
                              == body["params"]["prompt_text"])
            elif args.task in ("caption", "lyrics", "tag"):
                txt = next((a for a in arts if a["kind"] == "text"), None)
                check("text artifact present", txt is not None,
                      str([(a.get("kind"), a.get("label")) for a in arts]))
                if txt:
                    payload = json.load(open(txt["path"]))
                    meta = (job.get("result") or {}).get("meta") or {}
                    check("meta mirrors the payload",
                          meta.get("text") == payload)
                    if args.task == "caption":
                        check("caption text non-empty",
                              bool(str(payload.get("text") or "").strip()))
                        print(f"  caption: {payload.get('text')!r}")
                    elif args.task == "lyrics":
                        segs = payload.get("segments") or []
                        check("segments timed and monotonic",
                              all(s["start_s"] < s["end_s"] for s in segs)
                              and all(a["end_s"] <= b["start_s"] for a, b
                                      in zip(segs, segs[1:])), str(segs[:3]))
                        print(f"  lyrics ({payload.get('language')}): "
                              f"{len(segs)} segments")
                    else:  # tag
                        tags = payload.get("tags") or []
                        check("tags present", bool(tags))
                        check("tag scores in [0,1] where given",
                              all(0.0 <= t["score"] <= 1.0 for t in tags
                                  if t.get("score") is not None), str(tags))
                        print("  tags: " + ", ".join(
                            t["label"] for t in tags))
            elif args.task == "compose":
                txt = next((a for a in arts if a["kind"] == "text"), None)
                midi = next((a for a in arts if a["kind"] == "midi"), None)
                check("ABC text artifact present", txt is not None)
                if txt:
                    payload = json.load(open(txt["path"]))
                    abc = str(payload.get("text") or "")
                    check("ABC starts with a tune header (X:)",
                          abc.lstrip().startswith("X:"), abc[:40])
                    print(f"  abc: {len(abc)} chars")
                meta = (job.get("result") or {}).get("meta") or {}
                if midi is None:
                    # legal degradation: unparseable ABC ships text-only
                    check("midi absent only with meta.midi_error",
                          bool(meta.get("midi_error")), str(meta))
                else:
                    with open(midi["path"], "rb") as f:
                        check("composition midi parses",
                              f.read(4) == b"MThd")
            return report()

        outputs = job.get("result", {}).get("outputs", [])
        check(f"{args.count} output(s) reported", len(outputs) == args.count)
        declared_sr = (model.get("capabilities") or {}).get("sample_rate")
        declares_seed = any(pspec.get("key") == "seed" for pspec in
                            (model.get("capabilities") or {}).get("params")
                            or [])
        for out in outputs:
            p = out["path"]
            ok = os.path.exists(p) and os.path.getsize(p) > 1000
            check(f"output exists: {os.path.basename(p)}", ok)
            if not ok:
                continue
            dur, dbfs, ch, sr, flat = full_stats(p)
            check(f"non-silent ({dbfs:.1f} dBFS)" if dbfs is not None
                  else "non-silent", dbfs is not None and dbfs > -50)
            if flat is not None:
                # music sits well under 0.1; white noise reads > 0.35 — the
                # audit's "generating noise" class (H8)
                check(f"music-like, not noise (flatness={flat:.3f})",
                      flat < 0.35)
            if declared_sr and sr:
                check(f"sample rate {sr} matches catalog {declared_sr}",
                      sr == declared_sr)
            if sr and out.get("sample_rate"):
                check("reported sample_rate matches the file",
                      int(out["sample_rate"]) == sr)
            if ch is not None:
                print(f"  channels={ch}")
            if declares_seed:
                # would have caught B7's fabricated/no-op seeds (audit H8)
                check("seed_used reported", out.get("seed_used") is not None)
            # src-audio tasks (cover/repaint/extract/… and init_audio) lock
            # output length to the source, not the requested duration
            src_locked = any(k in (body.get("params") or {})
                             for k in ("src_audio", "init_audio"))
            if dur is None:
                check("duration readable", False)
            elif src_locked:
                check(f"duration positive ({dur:.1f}s, source-locked)",
                      dur > 0.5)
            else:
                check(f"duration {dur:.1f}s within 20% of {args.duration:.1f}s",
                      abs(dur - args.duration) <= 0.2 * args.duration + 0.5)
            print(f"  → {p}")
            if args.play:
                subprocess.run(["afplay", p], check=False)
        return report()
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
