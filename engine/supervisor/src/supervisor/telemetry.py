# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Machine telemetry: what the engine is using, measured without privileges.

Everything here is chosen because it works for an ordinary user process with no
entitlement and no helper tool — the app is a plain signed .app, and anything
needing root is not an option (`powermetrics`, which would give far more, is
exactly that).

- worker footprint: `proc_pid_rusage(RUSAGE_INFO_V4)` via libproc, which reads
  any same-uid process — and every worker is our own child. `task_info` /
  `task_for_pid` are the textbook calls and have needed root since Big Sur.
- GPU utilisation: the IOAccelerator registry entry's `PerformanceStatistics`.
  **Device-wide, never per-process** — no per-process figure is obtainable at
  all, so callers must label it as the whole machine's GPU.
- the accelerator's working-set ceiling is NOT here: only a worker can read it
  (torch/mlx live in the adapter venvs, not in the supervisor's), so it arrives
  over the worker protocol instead. See `worker_main._accelerator_profile`.

Every probe returns None rather than raising or guessing. A missing reading
makes the app hide a readout; a zero would draw a confident lie.
"""

from __future__ import annotations

import ctypes
import functools
import struct
import subprocess

# MARK: sysctl

# These cannot change while the engine runs, and /v1/system is polled every few
# seconds by the app — it used to fork a `sysctl` per request, from three
# separate call sites.


@functools.lru_cache(maxsize=1)
def physical_ram_bytes() -> int:
    return int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())


@functools.lru_cache(maxsize=1)
def machine_model() -> str:
    return subprocess.check_output(["sysctl", "-n", "hw.model"]).decode().strip()


@functools.lru_cache(maxsize=1)
def chip_name() -> str | None:
    """"Apple M1 Max" — the accelerator's name, because on Apple Silicon the GPU
    is part of the SoC and has no separate marketing name. Only reported when
    the brand string really is an Apple chip: on an Intel Mac it names a CPU,
    which would be a wrong answer to "what accelerator is this"."""
    try:
        name = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"]).decode().strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return name if name.startswith("Apple") else None


# MARK: worker footprint

_RUSAGE_INFO_V4 = 4
# ri_phys_footprint sits in the struct_rusage_info_v0 prefix that every later
# version keeps: 16 bytes of uuid, then it is the 8th uint64.
_PHYS_FOOTPRINT_OFFSET = 16 + 7 * 8
# rusage_info_v4 is ~350 bytes; over-allocate rather than transcribe a struct we
# read one field of, since a short buffer would be a silent stack smash.
_RUSAGE_BUF_BYTES = 1024
# Bounds for the child walk: generous for any real worker, finite for a
# pathological one.
_MAX_CHILDREN = 256
_MAX_TREE_PROCS = 64


@functools.lru_cache(maxsize=1)
def _libproc():
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError:
        return None
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p,
                                       ctypes.c_int]
    lib.proc_listchildpids.restype = ctypes.c_int
    return lib


def process_footprint_bytes(pid: int) -> int | None:
    """Physical footprint of a live same-uid process: what Activity Monitor
    calls "Memory", and what actually counts against this Mac. None if the
    process is gone (or on a kernel too old for RUSAGE_INFO_V4)."""
    lib = _libproc()
    if lib is None:
        return None
    buf = ctypes.create_string_buffer(_RUSAGE_BUF_BYTES)
    if lib.proc_pid_rusage(pid, _RUSAGE_INFO_V4, ctypes.byref(buf)) != 0:
        return None
    return int(struct.unpack_from("=Q", buf.raw, _PHYS_FOOTPRINT_OFFSET)[0])


def _child_pids(pid: int) -> list[int]:
    """Direct children of `pid`. Despite the name, proc_listchildpids returns a
    COUNT of pids, not a byte count (verified against a known set of children);
    -1 on failure, which reads the same as "none" here."""
    lib = _libproc()
    if lib is None:
        return []
    buf = (ctypes.c_int32 * _MAX_CHILDREN)()
    found = lib.proc_listchildpids(pid, buf, ctypes.sizeof(buf))
    if found <= 0:
        return []
    return [int(buf[i]) for i in range(min(found, _MAX_CHILDREN))]


def process_tree_footprint_bytes(pid: int) -> int | None:
    """Physical footprint of a process **and everything it spawned**.

    Adapters that drive a native runtime (acestep.cpp, YuE, whisper.cpp) hold
    none of the model in the worker itself: the worker stays ~10 MB of Python
    while its child mmaps several GB of GGUF. Measuring the worker alone made
    the sidebar report "0.0 GB" through an entire render that was in fact
    4-5 GB deep. What counts against this Mac is the tree, so the tree is what
    we report.

    None only when the root process is gone; a child that exits mid-walk is
    skipped rather than failing the whole reading.
    """
    root = process_footprint_bytes(pid)
    if root is None:
        return None
    total = root
    seen = {pid}
    frontier = [pid]
    # Breadth-first with a visit cap. Real trees here are one process deep; the
    # cap costs nothing and means a runaway spawner can never hang the sampler.
    while frontier and len(seen) < _MAX_TREE_PROCS:
        for child in _child_pids(frontier.pop()):
            if child in seen:
                continue
            seen.add(child)
            frontier.append(child)
            # Pages shared with the parent are counted twice in principle. In
            # practice these children are exec'd binaries sharing nothing but
            # dylibs, and over-reporting by a few MB beats under-reporting by
            # the whole model.
            total += process_footprint_bytes(child) or 0
    return total


# MARK: GPU utilisation

_UTF8 = 0x08000100  # kCFStringEncodingUTF8
_CF_NUMBER_SINT64 = 4  # kCFNumberSInt64Type


@functools.lru_cache(maxsize=1)
def _iokit():
    """(IOKit, CoreFoundation, "PerformanceStatistics", "Device Utilization %")
    with the signatures bound, or None if the frameworks won't load. The two
    CFStrings are created once and deliberately never released: they outlive
    every poll, and re-creating them per sample is pure churn."""
    try:
        iokit = ctypes.CDLL(
            "/System/Library/Frameworks/IOKit.framework/IOKit")
        cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return None
    # Without argtypes/restype, ctypes truncates returned pointers to 32 bits.
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                             ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFDictionaryGetValue.restype = ctypes.c_void_p
    cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
    cf.CFGetTypeID.restype = ctypes.c_ulong
    cf.CFDictionaryGetTypeID.restype = ctypes.c_ulong
    cf.CFNumberGetTypeID.restype = ctypes.c_ulong
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    iokit.IOServiceMatching.restype = ctypes.c_void_p
    iokit.IOServiceGetMatchingServices.argtypes = [
        ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    iokit.IOServiceGetMatchingServices.restype = ctypes.c_int
    iokit.IOIteratorNext.argtypes = [ctypes.c_uint32]
    iokit.IOIteratorNext.restype = ctypes.c_uint32
    iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
    iokit.IORegistryEntryCreateCFProperty.argtypes = [
        ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    iokit.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
    stats_key = cf.CFStringCreateWithCString(None, b"PerformanceStatistics", _UTF8)
    util_key = cf.CFStringCreateWithCString(None, b"Device Utilization %", _UTF8)
    if not stats_key or not util_key:
        return None
    return iokit, cf, stats_key, util_key


def gpu_utilization_percent() -> int | None:
    """How busy the GPU is, 0-100 — **device-wide**. This is every process on
    the Mac, not just our worker: Apple exposes no per-process GPU utilisation
    without root, so the honest reading is the whole device's and callers must
    say so. None when the driver doesn't publish the counter.

    Takes the busiest of the IOAccelerator entries; Apple Silicon has exactly
    one, but an Intel Mac with a discrete GPU has several.
    """
    loaded = _iokit()
    if loaded is None:
        return None
    iokit, cf, stats_key, util_key = loaded
    it = ctypes.c_uint32(0)
    # IOServiceGetMatchingServices consumes the matching dictionary's reference,
    # so it must not be released here.
    if iokit.IOServiceGetMatchingServices(
            0, iokit.IOServiceMatching(b"IOAccelerator"), ctypes.byref(it)) != 0:
        return None
    best = None
    try:
        while True:
            entry = iokit.IOIteratorNext(it)
            if not entry:
                break
            try:
                stats = iokit.IORegistryEntryCreateCFProperty(
                    entry, stats_key, None, 0)
                if not stats:
                    continue
                try:
                    if cf.CFGetTypeID(stats) != cf.CFDictionaryGetTypeID():
                        continue
                    value = cf.CFDictionaryGetValue(stats, util_key)
                    if not value or cf.CFGetTypeID(value) != cf.CFNumberGetTypeID():
                        continue
                    out = ctypes.c_int64(0)
                    if cf.CFNumberGetValue(value, _CF_NUMBER_SINT64,
                                           ctypes.byref(out)):
                        best = out.value if best is None else max(best, out.value)
                finally:
                    cf.CFRelease(stats)
            finally:
                iokit.IOObjectRelease(entry)
    finally:
        iokit.IOObjectRelease(it)
    return None if best is None else max(0, min(100, int(best)))
