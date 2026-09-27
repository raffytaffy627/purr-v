# traps.S - directed tests for everything the fuzzer can't reach:
# exceptions, mret, interrupts (direct + vectored), CSRs, counters, fence.i
# plus some known-answer M-extension edge cases.
# exit code 0 = pass, otherwise the number of the check that failed :o

#define EXIT 0x1000F000
#define TIMER 0x10002000

# s11 holds the current test number, s10 = what the handler saw
#define TEST(n) li s11, n
#define EXPECT(reg, val) li t6, val; bne reg, t6, fail

    .section .text.start
    .global _start
_start:
    la      t0, handler
    csrw    mtvec, t0

    # ---- 1: ecall -> mcause 11, mepc = the ecall ----
    TEST(1)
    la      s9, 1f
1:  ecall
    EXPECT(s10, 11)
    csrr    t0, mepc                # handler already stepped it past the ecall
    addi    s9, s9, 4
    bne     t0, s9, fail

    # ---- 2: illegal instruction -> mcause 2, mtval = the bits ----
    TEST(2)
    .word   0xFFFFFFFF
    EXPECT(s10, 2)
    csrr    t0, mtval
    EXPECT(t0, 0xFFFFFFFF)

    # ---- 3: ebreak -> mcause 3 ----
    TEST(3)
    ebreak
    EXPECT(s10, 3)

    # ---- 4: misaligned load -> mcause 4, mtval = address, rd untouched ----
    TEST(4)
    li      a0, 0x123
    li      a1, 0x3001
    lw      a0, 0(a1)
    EXPECT(s10, 4)
    EXPECT(a0, 0x123)
    csrr    t0, mtval
    EXPECT(t0, 0x3001)

    # ---- 5: misaligned store -> mcause 6, memory untouched ----
    TEST(5)
    li      a1, 0x3000
    li      t0, 0x5A5A5A5A
    sw      t0, 0(a1)
    sh      zero, 1(a1)
    EXPECT(s10, 6)
    lw      t0, 0(a1)
    EXPECT(t0, 0x5A5A5A5A)

    # ---- 6: jump to a misaligned target -> mcause 0, link reg untouched ----
    TEST(6)
    li      ra, 0x77
    la      t0, 2f
    addi    t0, t0, 2
    jalr    ra, 0(t0)
2:  nop
    nop
    EXPECT(s10, 0)
    EXPECT(ra, 0x77)

    # ---- 7: writing a read-only CSR is illegal ----
    TEST(7)
    csrw    mhartid, zero
    EXPECT(s10, 2)

    # ---- 8: unknown CSR is illegal ----
    TEST(8)
    csrr    t0, 0x7C0
    EXPECT(s10, 2)

    # ---- 9: csrrs/csrrc/csrrwi semantics on mscratch ----
    TEST(9)
    li      t0, 0xF0F0
    csrw    mscratch, t0
    li      t1, 0x0F00
    csrrs   t2, mscratch, t1
    EXPECT(t2, 0xF0F0)
    csrr    t2, mscratch
    EXPECT(t2, 0xFFF0)
    csrrci  t2, mscratch, 0x10
    csrr    t2, mscratch
    EXPECT(t2, 0xFFE0)
    csrrwi  t2, mscratch, 7
    EXPECT(t2, 0xFFE0)
    csrr    t2, mscratch
    EXPECT(t2, 7)

    # ---- 10: misa says RV32IM ----
    TEST(10)
    csrr    t0, misa
    EXPECT(t0, 0x40001100)

    # ---- 11: minstret / mcycle actually count ----
    TEST(11)
    csrr    t0, minstret
    nop
    nop
    nop
    csrr    t1, minstret
    sub     t1, t1, t0
    EXPECT(t1, 4)
    csrr    t0, mcycle
    csrr    t1, mcycle
    bgeu    t0, t1, fail

    # ---- 12: timer interrupt, direct mode ----
    TEST(12)
    li      s10, -1
    li      a0, TIMER
    sw      zero, 12(a0)            # mtimecmp hi = 0
    lw      t0, 0(a0)
    addi    t0, t0, 20
    sw      t0, 8(a0)               # fire in ~20 us
    li      t0, 0x80
    csrw    mie, t0                 # MTIE
    csrsi   mstatus, 8              # MIE
    li      t1, 100000
3:  addi    t1, t1, -1
    beqz    t1, fail                # timed out waiting
    li      t2, 0x80000007
    bne     s10, t2, 3b
    # handler cleared MIE via trap entry + mret restored it
    csrr    t0, mstatus
    andi    t0, t0, 8
    EXPECT(t0, 8)
    csrci   mstatus, 8

    # ---- 13: vectored mode sends interrupts to base + 4*cause ----
    TEST(13)
    li      s10, -1
    la      t0, vectors
    ori     t0, t0, 1
    csrw    mtvec, t0
    li      a0, TIMER
    lw      t0, 0(a0)
    addi    t0, t0, 20
    sw      t0, 8(a0)
    sw      zero, 12(a0)            # (handler parked the hi word at all-ones)
    csrsi   mstatus, 8
    li      t1, 100000
4:  addi    t1, t1, -1
    beqz    t1, fail
    li      t2, 0x77
    bne     s10, t2, 4b
    csrci   mstatus, 8
    la      t0, handler
    csrw    mtvec, t0

    # ---- 14: interrupt landing while a divide is in flight ----
    TEST(14)
    li      s10, -1
    li      a0, TIMER
    lw      t0, 0(a0)
    addi    t0, t0, 3
    sw      t0, 8(a0)
    sw      zero, 12(a0)
    csrsi   mstatus, 8
    li      t1, 3000
    li      a2, 1000000007
    li      a3, 12345
5:  divu    a4, a2, a3
    remu    a5, a2, a3
    addi    t1, t1, -1
    bnez    t1, 5b
    csrci   mstatus, 8
    EXPECT(a4, 81004)               # 1000000007 / 12345
    EXPECT(a5, 5627)                # 1000000007 % 12345
    li      t2, 0x80000007
    bne     s10, t2, fail

    # ---- 15: M-extension known answers ----
    TEST(15)
    li      a0, -7
    li      a1, 2
    div     t0, a0, a1
    EXPECT(t0, -3)
    rem     t0, a0, a1
    EXPECT(t0, -1)
    li      a0, 0x80000000
    li      a1, -1
    div     t0, a0, a1
    EXPECT(t0, 0x80000000)
    rem     t0, a0, a1
    EXPECT(t0, 0)
    divu    t0, a0, zero
    EXPECT(t0, 0xFFFFFFFF)
    rem     t0, a0, zero
    EXPECT(t0, 0x80000000)
    li      a0, 0xFFFFFFFF
    mulhu   t0, a0, a0
    EXPECT(t0, 0xFFFFFFFE)
    mulh    t0, a0, a0
    EXPECT(t0, 0)
    mulhsu  t0, a0, a0
    EXPECT(t0, 0xFFFFFFFF)

    # ---- 16: fence.i picks up freshly written code ----
    TEST(16)
    la      t0, patch
    li      t1, 0x02A00513          # addi a0, zero, 42
    sw      t1, 0(t0)
    fence.i
    li      a0, 0
patch:
    nop
    EXPECT(a0, 42)

    # ---- 17: wfi is a nop, fence is a nop ----
    TEST(17)
    wfi
    fence
    li      a0, EXIT
    sw      zero, 0(a0)
6:  j       6b

fail:
    li      a0, EXIT
    sw      s11, 0(a0)
7:  j       7b

# ---------------- trap handler ----------------
# records mcause in s10. for exceptions, skip the faulting instruction.
# for the timer, push mtimecmp far into the future.
handler:
    csrr    s10, mcause
    bltz    s10, 8f
    csrr    t5, mepc
    addi    t5, t5, 4
    csrw    mepc, t5
    mret
8:  li      t5, TIMER
    li      t4, -1
    sw      t4, 12(t5)
    mret

# vectored table: entry 7 (timer) marks s10 = 0x77
    .balign 64
vectors:
    j       fail                    # 0: exceptions come here in vectored mode too
    j       fail
    j       fail
    j       fail
    j       fail
    j       fail
    j       fail
    j       vec_timer               # 7
    j       fail
    j       fail
    j       fail
    j       fail                    # 11
vec_timer:
    li      s10, 0x77
    li      t5, TIMER
    li      t4, -1
    sw      t4, 12(t5)
    mret
