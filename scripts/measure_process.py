#!/usr/bin/env python3
"""Read-only macOS process measurements. No root access or extra Python packages required."""

import argparse
import ctypes
import json
import math
import sys
import time


# sys/resource.h, rusage_info_v4/v6. CPU times are Mach ticks; energy_nj is the
# kernel's energy estimate, not a measurement of battery consumption or watts.
V4_FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size
resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time
child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins
child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default
cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy
cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time
serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles
billed_energy serviced_energy interval_max_phys_footprint runnable_time""".split()
V6_FIELDS = """flags user_ptime system_ptime pinstructions pcycles energy_nj penergy_nj
secure_time_in_system secure_ptime_in_system neural_footprint lifetime_max_neural_footprint
interval_max_neural_footprint conclave_footprint page_wait_time_mach page_cache_hits""".split()


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in V4_FIELDS + V6_FIELDS
    ] + [("reserved", ctypes.c_uint64 * 6)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--duration", type=float, default=300, help="Seconds")
    parser.add_argument("--interval", type=float, default=5, help="Seconds")
    parser.add_argument("--output", required=True, help="New JSONL file; refuses to overwrite")
    args = parser.parse_args()
    if (sys.platform != "darwin" or args.pid <= 0 or not math.isfinite(args.duration)
            or not math.isfinite(args.interval) or args.duration <= 0 or args.interval <= 0):
        parser.error("Requires macOS and positive PID, duration and interval")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    timebase = Timebase()
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
        raise RuntimeError("Cannot read Mach timebase")
    seconds_per_tick = timebase.numer / timebase.denom / 1e9
    started = time.monotonic()
    identity = None
    with open(args.output, "x", buffering=1) as output:
        while True:
            # Leave space beyond the known SDK struct so a newer kernel cannot
            # overwrite Python memory. Only the documented v6 prefix is read.
            raw = ctypes.create_string_buffer(max(4096, ctypes.sizeof(Usage)))
            flavor = 6
            if libproc.proc_pid_rusage(args.pid, flavor, raw) != 0:
                flavor = 4
                if libproc.proc_pid_rusage(args.pid, flavor, raw) != 0:
                    raise OSError(ctypes.get_errno(), "Cannot read process resource usage")
            usage = Usage.from_buffer(raw)
            if identity is None:
                identity = usage.proc_start_abstime
            elif usage.proc_start_abstime != identity:
                raise RuntimeError("PID was reused; stopping to avoid mixing processes")
            row = {
                "pid": args.pid,
                "elapsed_seconds": time.monotonic() - started,
                "unix_time": time.time(),
                "cpu_seconds": (usage.user_time + usage.system_time) * seconds_per_tick,
                "interrupt_wakeups": usage.interrupt_wkups,
                "idle_wakeups": usage.pkg_idle_wkups,
                "physical_footprint_bytes": usage.phys_footprint,
                "peak_physical_footprint_bytes": usage.lifetime_max_phys_footprint,
                "estimated_energy_joules": usage.energy_nj / 1e9 if flavor == 6 else None,
                "disk_read_bytes": usage.diskio_bytesread,
                "disk_written_bytes": usage.diskio_byteswritten,
            }
            output.write(json.dumps(row) + "\n")
            remaining = args.duration - (time.monotonic() - started)
            if remaining <= 0:
                break
            time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    main()
