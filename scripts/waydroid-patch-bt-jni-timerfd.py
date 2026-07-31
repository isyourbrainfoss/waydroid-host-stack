#!/usr/bin/env python3
"""Patch libbluetooth_jni.so so timerfd uses CLOCK_BOOTTIME instead of ALARM.

Android Fluoride's RepeatingAlarm / bt_common::time::Alarm call
timerfd_create(CLOCK_BOOTTIME_ALARM, ...). That clock requires CAP_WAKE_ALARM
and fails for the bluetooth app (uid 1002) inside Waydroid LXC, aborting with:

  assertion 'fd_ != -1' failed

This rewrites the three known AArch64 sites that load #9 (BOOTTIME_ALARM)
immediately before bl timerfd_create to load #7 (CLOCK_BOOTTIME) instead.

Usage:
  waydroid-patch-bt-jni-timerfd.py INPUT.so OUTPUT.so
  waydroid-patch-bt-jni-timerfd.py --check INPUT.so   # exit 0 if already patched / patchable
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# AArch64: mov w0, #imm16  => 0x52800000 | (imm16 << 5)
# CLOCK_BOOTTIME_ALARM = 9, CLOCK_BOOTTIME = 7
MOV_W0_IMM9 = struct.pack("<I", 0x52800000 | (9 << 5))  # 20 01 80 52
MOV_W0_IMM7 = struct.pack("<I", 0x52800000 | (7 << 5))  # e0 00 80 52

# Known file offsets of `mov w0, #9` before timerfd_create@plt in Lineage 20
# TQ3A / A13 libbluetooth_jni.so (both stock waydroid and lineage common aarch64 images).
# Verified against BuildID-bearing A13 aarch64 library used .
DEFAULT_SITES = (0xAAD400, 0xAAF340, 0xB34BC8)


def va_to_off(data: bytes, va: int) -> int:
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        p_offset, p_vaddr, _p_paddr, p_filesz, p_memsz, _align = struct.unpack_from(
            "<QQQQQQ", data, off + 8
        )
        if p_type == 1 and p_vaddr <= va < p_vaddr + p_memsz:  # PT_LOAD
            file_off = p_offset + (va - p_vaddr)
            if file_off + 4 > p_offset + p_filesz:
                raise ValueError(f"va {va:#x} maps outside file-backed LOAD")
            return file_off
    raise ValueError(f"va {va:#x} not in any PT_LOAD")


def find_sites(data: bytes) -> list[int]:
    """Return list of VA sites that still have mov w0,#9 (or already #7)."""
    found = []
    for va in DEFAULT_SITES:
        off = va_to_off(data, va)
        cur = data[off : off + 4]
        if cur in (MOV_W0_IMM9, MOV_W0_IMM7):
            found.append(va)
    return found


def patch(data: bytearray) -> int:
    n = 0
    for va in DEFAULT_SITES:
        off = va_to_off(data, va)
        cur = bytes(data[off : off + 4])
        if cur == MOV_W0_IMM7:
            continue
        if cur != MOV_W0_IMM9:
            raise RuntimeError(
                f"unexpected insn at va {va:#x} off {off:#x}: {cur.hex()} "
                f"(want {MOV_W0_IMM9.hex()} or already-patched {MOV_W0_IMM7.hex()})"
            )
        data[off : off + 4] = MOV_W0_IMM7
        n += 1
    return n


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", type=Path, help="libbluetooth_jni.so")
    p.add_argument("output", type=Path, nargs="?", help="patched output (omit with --check)")
    p.add_argument(
        "--check",
        action="store_true",
        help="only verify sites look patchable or already patched",
    )
    args = p.parse_args(argv)

    raw = args.input.read_bytes()
    if raw[:4] != b"\x7fELF":
        print("not an ELF file", file=sys.stderr)
        return 2

    sites = find_sites(raw)
    if len(sites) != len(DEFAULT_SITES):
        print(
            f"expected {len(DEFAULT_SITES)} known sites, found {len(sites)}",
            file=sys.stderr,
        )
        return 3

    if args.check:
        data = bytearray(raw)
        # dry-run: ensure patch() would succeed
        try:
            n = patch(bytearray(raw))
        except RuntimeError as e:
            print(f"CHECK_FAIL {e}", file=sys.stderr)
            return 4
        already = sum(
            1
            for va in DEFAULT_SITES
            if raw[va_to_off(raw, va) : va_to_off(raw, va) + 4] == MOV_W0_IMM7
        )
        print(f"CHECK_OK sites={len(sites)} need_patch={n} already={already}")
        return 0

    if args.output is None:
        print("output path required unless --check", file=sys.stderr)
        return 2

    data = bytearray(raw)
    n = patch(data)
    args.output.write_bytes(data)
    print(f"PATCH_OK wrote {args.output} patched_insns={n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
