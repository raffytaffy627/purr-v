// hello - the "hello world" of purr-V: UART + LCD + a little math :3

#include "purrv.h"

static uint32_t fib(uint32_t n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(void) {
    uart_puts("hi from purr-V :3\n");

    lcd_clear();
    lcd_puts("purr-V RV32IM");
    lcd_goto(0, 1);
    lcd_puts("hello world :3");

    uart_puts("fib(15) = ");
    uart_put_uint(fib(15));
    uart_puts("\n-7 * 6 = ");
    uart_put_int(-7 * (int32_t)csr_read(mhartid) + -7 * 6);
    uart_puts("\n1000000 / 7 = ");
    volatile uint32_t big = 1000000;
    uart_put_uint(big / 7);

    SEG_HEX = 0xCAFE;
    GPIO_LEDS = 0x2A;

    lcd_wait_idle();
    print_perf();
    return fib(15) == 610 ? 0 : 1;
}
