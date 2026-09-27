#!/usr/bin/env python3
"""run_tests.py - build + run the whole purr-V test suite

    python tools/run_tests.py            # everything
    python tools/run_tests.py --fuzz 100 # more random programs (default 25)

1. compiles the RTL with Icarus Verilog (fails loudly on any real error)
2. directed tests: traps / interrupts / CSRs / M edge cases / fence.i
3. C programs: hello (UART + LCD + math), parking (sonar + interrupts), dino
4. bootloader: flash a program over the simulated UART and run it
5. random differential fuzzing against the Python ISS
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_sw as builder  # noqa: E402

ROOT = builder.ROOT
VVP = os.path.join(ROOT, "build", "sim.vvp")


def find_iverilog():
    if shutil.which("iverilog"):
        return "iverilog", "vvp"
    for d in (r"C:\iverilog\bin", r"C:\Program Files\iverilog\bin"):
        if os.path.exists(os.path.join(d, "iverilog.exe")):
            os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]
            return "iverilog", "vvp"
    sys.exit("can't find Icarus Verilog :(  install it and put it on PATH")


def compile_rtl():
    iverilog, _ = find_iverilog()
    srcs = []
    for d in ("rtl/core", "rtl/soc", "rtl/periph"):
        srcs += sorted(os.path.join(d, f) for f in os.listdir(os.path.join(ROOT, d)) if f.endswith(".sv"))
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    r = subprocess.run([iverilog, "-g2012", "-DSIM", "-I", "rtl/core", "-o", VVP, "sim/tb_soc.sv", *srcs],
                       cwd=ROOT, capture_output=True, text=True)
    # Icarus prints harmless "sorry: constant selects in always_*" notes - hide those
    real = [l for l in (r.stdout + r.stderr).splitlines() if l.strip() and "sorry: constant selects" not in l]
    if r.returncode or real:
        print("\n".join(real))
        sys.exit("RTL didn't compile :(")


def sim(hexf, *plusargs, expect=None):
    r = subprocess.run(["vvp", "-n", VVP, f"+hex={hexf}", *plusargs], cwd=ROOT, capture_output=True, text=True)
    out = r.stdout
    ok = "[tb] PASS" in out and (expect is None or expect in out)
    m = re.search(r"exit code (\d+) after (\d+) cycles, (\d+) instrs", out)
    info = f"{m.group(3)} instrs / {m.group(2)} cycles" if m else out.strip().splitlines()[-1] if out.strip() else "no output"
    return ok, info, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=25)
    args = ap.parse_args()

    results = []

    def check(name, ok, info):
        results.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:28s} {info}")

    print("compiling RTL...")
    compile_rtl()

    print("directed tests:")
    hexf = builder.build("tests/isa/traps.S")
    check("traps / irq / csr / fence.i", *sim(hexf)[:2])

    print("programs:")
    hexf = builder.build("sw/hello")
    check("hello (uart + lcd + M ext)", *sim(hexf, expect="hello world :3")[:2])
    hexf = builder.build("sw/parking", ["-DSIM_DEMO"])
    check("parking (sonar @ 12 cm)", *sim(hexf, "+sonar_cm=12", "+max_cycles=6000000", expect="dist: 12 cm")[:2])
    hexf = builder.build("sw/dino", ["-DSIM_DEMO"])
    check("dino (lcd game, autopilot)", *sim(hexf, "+max_cycles=8000000", expect="score: 3")[:2])

    print("bootloader:")
    spin = builder.build("tests/boot/spin.S")
    builder.build("sw/hello")
    check("flash hello over UART", *sim(spin, "+load=build/hello.bin", "+max_cycles=3000000")[:2])

    print(f"fuzzing ({args.fuzz} random programs vs the ISS):")
    r = subprocess.run([sys.executable, "tools/fuzz.py", "-n", str(args.fuzz)], cwd=ROOT, capture_output=True, text=True)
    last = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "no output"
    check("random differential", r.returncode == 0, last)
    if r.returncode:
        print("\n".join(l for l in r.stdout.splitlines() if "MISMATCH" in l or "iss:" in l or "rtl:" in l))

    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed " + (":3" if passed == len(results) else ":("))
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
