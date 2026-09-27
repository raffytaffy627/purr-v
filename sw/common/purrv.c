// purrv.c - the "arduino core" for purr-V, but tiny :p

#include "purrv.h"

// ---------------- time ----------------
void delay_us(uint32_t us) {
    uint64_t end = time_us() + us;
    while (time_us() < end) {}
}

void delay_ms(uint32_t ms) { delay_us(ms * 1000u); }

void timer_set_alarm_us(uint32_t us_from_now) {
    uint64_t t = time_us() + us_from_now;
    MTIMECMP_HI = 0xFFFFFFFFu;          // no false trigger while half-written
    MTIMECMP_LO = (uint32_t)t;
    MTIMECMP_HI = (uint32_t)(t >> 32);
}

// ---------------- UART ----------------
void uart_putc(char c) {
    while (!(UART_STATUS & 1u)) {}
    UART_DATA = (uint8_t)c;
}

void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_put_uint(uint32_t v) {
    char buf[11];
    int i = 0;
    do {
        buf[i++] = (char)('0' + v % 10u);   // hardware divider doing real work :3
        v /= 10u;
    } while (v);
    while (i) uart_putc(buf[--i]);
}

void uart_put_int(int32_t v) {
    if (v < 0) {
        uart_putc('-');
        uart_put_uint((uint32_t)(-(v + 1)) + 1u);
    } else {
        uart_put_uint((uint32_t)v);
    }
}

void uart_put_hex(uint32_t v) {
    for (int s = 28; s >= 0; s -= 4) uart_putc("0123456789abcdef"[(v >> s) & 0xFu]);
}

int uart_getc(void) {
    if (!(UART_STATUS & 2u)) return -1;
    return (int)(UART_DATA & 0xFFu);
}

// ---------------- LCD ----------------
static void lcd_write(volatile uint32_t *reg, uint8_t v) {
    while (LCD_STATUS & 1u) {}          // FIFO full, hardware is busy sending
    *reg = v;
}

void lcd_clear(void)            { lcd_write(&LCD_CMD, 0x01); }
void lcd_goto(int col, int row) { lcd_write(&LCD_CMD, (uint8_t)(0x80 | ((row ? 0x40 : 0x00) + col))); }
void lcd_putc(char c)           { lcd_write(&LCD_DATA, (uint8_t)c); }
void lcd_puts(const char *s)    { while (*s) lcd_putc(*s++); }

void lcd_put_uint(uint32_t v) {
    char buf[11];
    int i = 0;
    do { buf[i++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (i) lcd_putc(buf[--i]);
}

void lcd_custom_char(int slot, const uint8_t rows[8]) {
    lcd_write(&LCD_CMD, (uint8_t)(0x40 | ((slot & 7) << 3)));
    for (int i = 0; i < 8; i++) lcd_write(&LCD_DATA, rows[i]);
    lcd_write(&LCD_CMD, 0x80);          // back to DDRAM
}

void lcd_wait_idle(void) { while (!(LCD_STATUS & 2u)) {} }

// ---------------- sonar ----------------
uint32_t sonar_read_cm(void) {
    (void)SONAR_ECHO_US;                // clear any stale "ready"
    SONAR_CTRL = 1u;
    while (!(SONAR_STATUS & 1u)) {}
    return SONAR_ECHO_US / 58u;
}

// ---------------- buzzer ----------------
void tone(uint32_t hz, uint32_t ms) {
    if (hz == 0) { no_tone(); return; }
    BUZZ_DUR_MS  = ms;
    BUZZ_HALF_US = 500000u / hz;
}

void no_tone(void) { BUZZ_HALF_US = 0; }

// ---------------- perf ----------------
void print_perf(void) {
    uint32_t cyc = csr_read(mcycle), ins = csr_read(minstret);
    uint32_t mis = perf_mispredicts(), ctl = perf_ctrl_flow();
    uart_puts("\n-- perf --\ncycles:      "); uart_put_uint(cyc);
    uart_puts("\ninstrs:      ");             uart_put_uint(ins);
    uart_puts("\nCPI x1000:   ");             uart_put_uint(ins ? (uint32_t)((uint64_t)cyc * 1000u / ins) : 0);
    uart_puts("\nctrl flow:   ");             uart_put_uint(ctl);
    uart_puts("\nmispredicts: ");             uart_put_uint(mis);
    uart_puts("\nload-use:    ");             uart_put_uint(perf_load_use());
    uart_puts("\ndiv stalls:  ");             uart_put_uint(perf_div_stalls());
    uart_puts("\n");
}
