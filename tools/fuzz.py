#!/usr/bin/env python3
"""fuzz.py - random differential testing: purr-V pipeline vs tools/iss.py

generates a random (but always-terminating) RV32IM program full of the stuff
that breaks pipelines: back-to-back dependencies, load-use pairs, branches
that flip between taken/not-taken, loops, calls + returns, mul/div edge cases.
then it runs it on BOTH the RTL and the ISS and diffs every retired
instruction. any mismatch = bug, with the exact pc where it went wrong :o

    python tools/fuzz.py                # 20 random programs
    python tools/fuzz.py -n 200 -s 1234 # 200 programs starting at seed 1234
"""

import argparse
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iss import ISS                      # noqa: E402
import build_sw as builder                  # noqa: E402

ROOT = builder.ROOT
GEN_DIR = os.path.join(ROOT, "build", "fuzz")

# x1 = ra, x30 = loop counter, x31 = data buffer base. random ops only touch x2..x29
DST = list(range(2, 30))
SRC = list(range(0, 32))
EDGE = [0, 1, -1, 2, 0x7FFFFFFF, -0x80000000, 0x80000001, 0xFFFF, 0x10000, 31, 32, -2]

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
         "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.lines = []
        self.label = 0
        self.nfuncs = 4

    def new_label(self):
        self.label += 1
        return f"L{self.label}"

    def reg(self):
        # bias toward a few regs so dependencies (and forwarding) happen a lot
        return self.r.choice(DST[:6]) if self.r.random() < 0.6 else self.r.choice(DST)

    def src(self):
        return self.r.choice(DST[:6]) if self.r.random() < 0.6 else self.r.choice(SRC)

    def emit(self, s):
        self.lines.append("    " + s)

    def simple(self):
        """one straight-line instruction (safe inside loops and functions)"""
        k = self.r.random()
        if k < 0.35:
            self.emit(f"{self.r.choice(R_OPS)} x{self.reg()}, x{self.src()}, x{self.src()}")
        elif k < 0.55:
            self.emit(f"{self.r.choice(I_OPS)} x{self.reg()}, x{self.src()}, {self.r.randint(-2048, 2047)}")
        elif k < 0.62:
            self.emit(f"{self.r.choice(SH_OPS)} x{self.reg()}, x{self.src()}, {self.r.randint(0, 31)}")
        elif k < 0.67:
            self.emit(f"lui x{self.reg()}, {self.r.randint(0, 0xFFFFF)}")
        elif k < 0.70:
            self.emit(f"auipc x{self.reg()}, {self.r.randint(0, 0xFFFFF)}")
        elif k < 0.85:
            op, size = self.r.choice(LOADS)
            off = self.r.randrange(0, 512, size)
            d = self.reg()
            self.emit(f"{op} x{d}, {off}(x31)")
            if self.r.random() < 0.5:     # immediately use it -> load-use stall
                self.emit(f"add x{self.reg()}, x{d}, x{self.src()}")
        else:
            op, size = self.r.choice(STORES)
            off = self.r.randrange(0, 512, size)
            self.emit(f"{op} x{self.src()}, {off}(x31)")

    def block(self):
        k = self.r.random()
        if k < 0.60:
            self.simple()
        elif k < 0.75:
            # forward branch over a couple of instructions
            lab = self.new_label()
            self.emit(f"{self.r.choice(BR_OPS)} x{self.src()}, x{self.src()}, {lab}")
            for _ in range(self.r.randint(1, 3)):
                self.simple()
            self.lines.append(f"{lab}:")
        elif k < 0.85:
            # small counted loop, with a data-dependent branch inside so the
            # predictor sees both directions
            lab, skip = self.new_label(), self.new_label()
            self.emit(f"li x30, {self.r.randint(1, 12)}")
            self.lines.append(f"{lab}:")
            for _ in range(self.r.randint(1, 4)):
                self.simple()
            self.emit(f"andi x29, x30, {self.r.choice([1, 2, 3])}")
            self.emit(f"beqz x29, {skip}")
            self.simple()
            self.lines.append(f"{skip}:")
            self.emit("addi x30, x30, -1")
            self.emit(f"bnez x30, {lab}")
        elif k < 0.95:
            self.emit(f"call func{self.r.randrange(self.nfuncs)}")
        else:
            a, b = self.r.choice(EDGE), self.r.choice(EDGE)
            ra, rb = self.reg(), self.reg()
            self.emit(f"li x{ra}, {a}")
            self.emit(f"li x{rb}, {b}")
            self.emit(f"{self.r.choice(['div', 'divu', 'rem', 'remu', 'mulh', 'mulhsu'])} x{self.reg()}, x{ra}, x{rb}")

    def program(self, n_blocks):
        self.lines += [".section .text.start", ".global _start", "_start:"]
        self.emit("li x31, 0x3000")
        for r in DST + [30]:
            self.emit(f"li x{r}, {self.r.choice(EDGE) if self.r.random() < 0.3 else self.r.randint(-2**31, 2**31 - 1)}")
        # seed the data buffer
        for off in range(0, 512, 4):
            self.emit(f"li x2, {self.r.randint(-2**31, 2**31 - 1)}")
            self.emit(f"sw x2, {off}(x31)")
        for _ in range(n_blocks):
            self.block()
        self.emit("li x2, 0x1000F000")
        self.emit("sw x0, 0(x2)")
        self.lines.append("1: j 1b")
        for f in range(self.nfuncs):
            self.lines.append(f"func{f}:")
            for _ in range(self.r.randint(1, 5)):
                self.simple()
            self.emit("ret")
        return "\n".join(self.lines) + "\n"


def run_rtl(hexf):
    vvp = os.path.join(ROOT, "build", "sim.vvp")
    r = subprocess.run(["vvp", "-n", vvp, f"+hex={hexf}", "+trace", "+quiet", "+max_cycles=400000"],
                       capture_output=True, text=True, cwd=ROOT)
    lines = r.stdout.splitlines()
    return [l for l in lines if l.startswith("T ")], [l for l in lines if l.startswith("S ")], r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=20)
    ap.add_argument("-s", "--seed", type=int, default=1)
    ap.add_argument("-b", "--blocks", type=int, default=300)
    args = ap.parse_args()
    os.makedirs(GEN_DIR, exist_ok=True)

    fails = 0
    for seed in range(args.seed, args.seed + args.n):
        src = os.path.join(GEN_DIR, f"fuzz_{seed}.S")
        with open(src, "w") as f:
            f.write(Gen(seed).program(args.blocks))
        hexf = builder.build(src)
        binf = hexf[:-4] + ".bin"

        iss = ISS(open(binf, "rb").read())
        iss.run()
        rtl_t, rtl_s, raw = run_rtl(hexf)
        # the RTL keeps spinning on `j 1b` for a couple cycles after exit, drop that
        if len(rtl_t) > len(iss.trace):
            rtl_t = rtl_t[:len(iss.trace)]

        bad = None
        for i, (a, b) in enumerate(zip(iss.trace, rtl_t)):
            if a != b:
                bad = f"trace line {i}:\n  iss: {a}\n  rtl: {b}"
                break
        if bad is None and len(iss.trace) != len(rtl_t):
            bad = f"trace length iss={len(iss.trace)} rtl={len(rtl_t)}\n{raw[-500:]}"
        if bad is None and iss.stores != rtl_s:
            for i, (a, b) in enumerate(zip(iss.stores, rtl_s)):
                if a != b:
                    bad = f"store {i}:\n  iss: {a}\n  rtl: {b}"
                    break
            bad = bad or f"store count iss={len(iss.stores)} rtl={len(rtl_s)}"

        if bad:
            fails += 1
            print(f"seed {seed}: MISMATCH :(  {bad}")
        else:
            print(f"seed {seed}: ok, {len(rtl_t)} instrs match")

    print(f"\n{args.n - fails}/{args.n} passed" + (" :3" if not fails else " :("))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
