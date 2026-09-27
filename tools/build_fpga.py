#!/usr/bin/env python3
"""build_fpga.py - synthesize + place & route purr-V for the Tang Nano 9K
using the fully open-source flow (yosys -> nextpnr-himbaechel -> gowin_pack)

    python tools/build_fpga.py            # boots into sw/parking
    python tools/build_fpga.py sw/dino    # bake a different program into RAM

needs: pip install yowasp-yosys yowasp-nextpnr-himbaechel-gowin apycula
(or native yosys / nextpnr-himbaechel / gowin_pack on PATH)
output: build/purrv_tangnano9k.fs -> flash with openFPGALoader -b tangnano9k
"""

import glob
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_sw as builder  # noqa: E402

ROOT = builder.ROOT
BUILD = os.path.join(ROOT, "build")
DEVICE = "GW1NR-LV9QN88PC6/I5"
FAMILY = "GW1N-9C"


def tool(*names):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    # the yowasp venv this repo's README sets up
    for n in names:
        for p in glob.glob(os.path.expanduser(f"~/tools/fpga-venv/Scripts/{n}.exe")):
            return p
    sys.exit(f"can't find {names[0]} :(  see the README for the install line")


def run(cmd):
    print(">", " ".join(os.path.basename(c) if i == 0 else c for i, c in enumerate(cmd)))
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode:
        sys.exit(r.returncode)


def main():
    prog = sys.argv[1] if len(sys.argv) > 1 else "sw/parking"
    hexf = builder.build(os.path.join(ROOT, prog))
    shutil.copy(hexf, os.path.join(BUILD, "demo.hex"))

    srcs = sorted(os.path.relpath(f, ROOT).replace(os.sep, "/")
                  for d in ("rtl/core", "rtl/soc", "rtl/periph")
                  for f in glob.glob(os.path.join(ROOT, d, "*.sv")))
    srcs.append("fpga/tangnano9k/tangnano9k_top.sv")
    json = "build/purrv.json"

    yosys = tool("yosys", "yowasp-yosys")
    run([yosys, "-q", "-l", "build/yosys.log", "-p",
         f"read_verilog -sv -I rtl/core {' '.join(srcs)}; "
         f"synth_gowin -top tangnano9k_top -nowidelut -json {json}; stat"])

    nextpnr = tool("nextpnr-himbaechel", "yowasp-nextpnr-himbaechel-gowin")
    run([nextpnr, "--json", json, "--write", "build/purrv_pnr.json",
         "--device", DEVICE, "--vopt", f"family={FAMILY}",
         "--vopt", "cst=fpga/tangnano9k/tangnano9k.cst",
         "--freq", "27", "--log", "build/nextpnr.log"])

    pack = tool("gowin_pack")
    run([pack, "-d", FAMILY, "-o", "build/purrv_tangnano9k.fs", "build/purrv_pnr.json"])
    print("\nbitstream: build/purrv_tangnano9k.fs  :3")
    print("flash it:  openFPGALoader -b tangnano9k build/purrv_tangnano9k.fs")


if __name__ == "__main__":
    main()
