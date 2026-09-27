#!/usr/bin/env python3
"""build.py - compile a purr-V program into .elf / .bin / .hex

usage:
    python tools/build_sw.py sw/hello            # C program folder (+ sw/common lib)
    python tools/build_sw.py tests/isa/alu.S     # standalone assembly test
    python tools/build_sw.py sw/parking -DSIM_DEMO   # extra -D flags go to gcc

outputs land in build/<name>.{elf,bin,hex,dis}
  .bin -> for tools/flash.py (UART bootloader on the real board)
  .hex -> for the testbench ($readmemh, one 32-bit word per line)
"""

import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
COMMON = os.path.join(ROOT, "sw", "common")
RAM_BYTES = 16 * 1024

CFLAGS = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-O2", "-g",
          "-ffreestanding", "-fno-builtin", "-nostdlib", "-nostartfiles",
          "-Wall", "-Wextra", "-ffunction-sections", "-fdata-sections"]
LDFLAGS = ["-T", os.path.join(COMMON, "link.ld"), "-Wl,--gc-sections", "-Wl,--no-warn-rwx-segments", "-lgcc"]


def find_prefix():
    """find a riscv gcc: env var, then PATH, then the xpack folder in ~/tools"""
    env = os.environ.get("RISCV_PREFIX")
    if env:
        return env
    for p in ("riscv-none-elf-", "riscv64-unknown-elf-", "riscv32-unknown-elf-"):
        if shutil.which(p + "gcc"):
            return p
    for d in glob.glob(os.path.expanduser("~/tools/xpack-riscv-none-elf-gcc-*/bin")):
        return os.path.join(d, "riscv-none-elf-")
    sys.exit("couldn't find a RISC-V gcc :( set RISCV_PREFIX or put one on PATH")


def run(cmd):
    r = subprocess.run(cmd)
    if r.returncode != 0:
        sys.exit(r.returncode)


def build(target, defines=()):
    target = os.path.normpath(target)
    prefix = find_prefix()
    os.makedirs(BUILD, exist_ok=True)

    if target.endswith(".S"):
        name = os.path.splitext(os.path.basename(target))[0]
        srcs = [target]
        extra = ["-I", os.path.dirname(target)]
    else:
        name = os.path.basename(target)
        srcs = sorted(glob.glob(os.path.join(target, "*.c")) + glob.glob(os.path.join(target, "*.S")))
        srcs += [os.path.join(COMMON, "start.S"), os.path.join(COMMON, "purrv.c")]
        extra = ["-I", COMMON]

    elf = os.path.join(BUILD, name + ".elf")
    binf = os.path.join(BUILD, name + ".bin")
    hexf = os.path.join(BUILD, name + ".hex")
    dis = os.path.join(BUILD, name + ".dis")

    run([prefix + "gcc", *CFLAGS, *defines, *extra, *srcs, *LDFLAGS, "-o", elf])
    run([prefix + "objcopy", "-O", "binary", elf, binf])
    with open(dis, "w") as f:
        subprocess.run([prefix + "objdump", "-d", "-M", "no-aliases,numeric", elf], stdout=f)

    data = open(binf, "rb").read()
    if len(data) > RAM_BYTES:
        sys.exit(f"{name}: {len(data)} bytes doesn't fit in {RAM_BYTES} bytes of RAM :o")
    data += b"\0" * (-len(data) % 4)
    with open(hexf, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")

    print(f"built {name}: {len(data)} bytes ({100 * len(data) // RAM_BYTES}% of RAM)")
    return hexf


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    defs = [a for a in sys.argv[1:] if a.startswith("-D")]
    for t in sys.argv[1:]:
        if not t.startswith("-D"):
            build(t, defs)
