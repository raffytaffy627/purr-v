# start.S - first thing purr-V runs after reset :3
# sets up the stack + gp, clears .bss, calls main(), then reports main's
# return value as the exit code (the testbench watches for that write)

    .section .text.start
    .global _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    # zero .bss
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    # exit(main's return value)
    li      t0, 0x1000F000
    sw      a0, 0(t0)
3:  j       3b
