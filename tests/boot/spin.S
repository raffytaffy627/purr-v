# spin.S - "old" program for the bootloader test: blink forever, never exit.
# the testbench then flashes a new program over UART - if that one passes,
# the bootloader works :3
    .section .text.start
    .global _start
_start:
    li      t0, 0x10001000
    li      t1, 0
1:  addi    t1, t1, 1
    sw      t1, 0(t0)
    j       1b
