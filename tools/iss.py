#!/usr/bin/env python3
"""iss.py - a tiny RV32IM instruction set simulator (the "golden model")

it runs the same .bin as the hardware and prints the same retire trace
format as sim/tb_soc.sv (+trace), so tools/fuzz.py can diff them line by line.
if the pipeline ever disagrees with this dumb one-instruction-at-a-time
model, the pipeline is wrong :p

    python tools/iss.py build/foo.bin [max_instrs]
"""

import sys

MASK = 0xFFFFFFFF
EXIT_ADDR = 0x1000F000


def sx(v, bits):
    """sign-extend a `bits`-wide value"""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class ISS:
    def __init__(self, image, ram_bytes=16 * 1024):
        self.mem = bytearray(ram_bytes)
        self.mem[:len(image)] = image
        self.x = [0] * 32
        self.pc = 0
        self.exit_code = None
        self.trace = []      # "T ..." lines
        self.stores = []     # "S ..." lines

    # ---- memory ----
    def load(self, addr, size):
        return int.from_bytes(self.mem[addr:addr + size], "little")

    def store(self, addr, size, val):
        if addr == EXIT_ADDR:
            self.exit_code = val & MASK
            return
        self.mem[addr:addr + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    # ---- one instruction ----
    def step(self):
        pc = self.pc
        ins = self.load(pc, 4)
        op = ins & 0x7F
        rd = (ins >> 7) & 0x1F
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 0x1F
        rs2 = (ins >> 20) & 0x1F
        f7 = ins >> 25
        a, b = self.x[rs1], self.x[rs2]
        imm_i = sx(ins >> 20, 12)
        imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)
        imm_b = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)

        nxt = (pc + 4) & MASK
        res = None

        if op == 0x37:                                   # LUI
            res = imm_u
        elif op == 0x17:                                 # AUIPC
            res = (pc + imm_u) & MASK
        elif op == 0x6F:                                 # JAL
            res, nxt = nxt, (pc + imm_j) & MASK
        elif op == 0x67:                                 # JALR
            res, nxt = nxt, (a + imm_i) & MASK & ~1
        elif op == 0x63:                                 # branches
            taken = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                     6: a < b, 7: a >= b}[f3]
            if taken:
                nxt = (pc + imm_b) & MASK
        elif op == 0x03:                                 # loads
            addr = (a + imm_i) & MASK
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            v = self.load(addr, size)
            res = v if f3 >= 4 or size == 4 else sx(v, 8 * size) & MASK
        elif op == 0x23:                                 # stores
            addr = (a + imm_s) & MASK
            size = {0: 1, 1: 2, 2: 4}[f3]
            # log it the way the hardware sees it on the bus (replicated lanes)
            if size == 1:
                data, strb = (b & 0xFF) * 0x01010101, 1 << (addr & 3)
            elif size == 2:
                data, strb = (b & 0xFFFF) * 0x00010001, 0xC if addr & 2 else 0x3
            else:
                data, strb = b, 0xF
            self.stores.append(f"S {addr:08x} {data:08x} {strb:x}")
            self.store(addr, size, b)
        elif op == 0x13:                                 # ALU imm
            sh = imm_i & 0x1F
            if f3 == 0: res = a + imm_i
            elif f3 == 2: res = int(s32(a) < imm_i)
            elif f3 == 3: res = int(a < (imm_i & MASK))
            elif f3 == 4: res = a ^ imm_i
            elif f3 == 6: res = a | imm_i
            elif f3 == 7: res = a & imm_i
            elif f3 == 1: res = a << sh
            elif f3 == 5: res = (s32(a) >> sh) if f7 & 0x20 else (a >> sh)
            res &= MASK
        elif op == 0x33 and f7 == 1:                     # M extension
            if f3 == 0: res = a * b
            elif f3 == 1: res = (s32(a) * s32(b)) >> 32
            elif f3 == 2: res = (s32(a) * b) >> 32
            elif f3 == 3: res = (a * b) >> 32
            elif f3 in (4, 6):                           # DIV / REM (signed)
                sa, sb = s32(a), s32(b)
                if sb == 0:
                    q, r = -1, sa
                elif sa == -2**31 and sb == -1:
                    q, r = sa, 0
                else:
                    q = abs(sa) // abs(sb) * (1 if (sa < 0) == (sb < 0) else -1)
                    r = sa - q * sb
                res = q if f3 == 4 else r
            else:                                        # DIVU / REMU
                if b == 0:
                    q, r = MASK, a
                else:
                    q, r = a // b, a % b
                res = q if f3 == 5 else r
            res &= MASK
        elif op == 0x33:                                 # ALU reg
            sh = b & 0x1F
            if f3 == 0: res = a - b if f7 & 0x20 else a + b
            elif f3 == 1: res = a << sh
            elif f3 == 2: res = int(s32(a) < s32(b))
            elif f3 == 3: res = int(a < b)
            elif f3 == 4: res = a ^ b
            elif f3 == 5: res = (s32(a) >> sh) if f7 & 0x20 else (a >> sh)
            elif f3 == 6: res = a | b
            elif f3 == 7: res = a & b
            res &= MASK
        elif op == 0x0F:                                 # FENCE / FENCE.I
            pass
        else:
            raise RuntimeError(f"ISS: unsupported instr {ins:08x} at {pc:08x}")

        if res is not None and rd != 0:
            self.x[rd] = res & MASK
            self.trace.append(f"T {pc:08x} {ins:08x} x{rd}={res & MASK:08x}")
        else:
            self.trace.append(f"T {pc:08x} {ins:08x}")
        self.pc = nxt

    def run(self, max_instrs=2_000_000):
        n = 0
        while self.exit_code is None and n < max_instrs:
            self.step()
            n += 1
        return self.exit_code


if __name__ == "__main__":
    iss = ISS(open(sys.argv[1], "rb").read())
    code = iss.run(int(sys.argv[2]) if len(sys.argv) > 2 else 2_000_000)
    print("\n".join(iss.trace))
    print(f"exit {code}")
