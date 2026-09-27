// purrv.h - tiny bare-metal library for the purr-V SoC :3
// no libc, no OS, just registers. include this and go

#ifndef PURRV_H
#define PURRV_H

#include <stdint.h>

#define REG(addr) (*(volatile uint32_t *)(addr))

// ---------------- memory map ----------------
#define UART_BASE    0x10000000u
#define GPIO_BASE    0x10001000u
#define TIMER_BASE   0x10002000u
#define LCD_BASE     0x10003000u
#define SONAR_BASE   0x10004000u
#define BUZZER_BASE  0x10005000u
#define SEG_BASE     0x10006000u
#define IRQ_BASE     0x10007000u
#define SIM_EXIT     0x1000F000u   // testbench only, ignored on the FPGA

#define UART_DATA     REG(UART_BASE + 0x0)
#define UART_STATUS   REG(UART_BASE + 0x4)
#define GPIO_LEDS     REG(GPIO_BASE + 0x0)
#define GPIO_BUTTONS  REG(GPIO_BASE + 0x4)
#define GPIO_PRESSED  REG(GPIO_BASE + 0x8)
#define GPIO_IRQ_EN   REG(GPIO_BASE + 0xC)
#define MTIME_LO      REG(TIMER_BASE + 0x0)
#define MTIME_HI      REG(TIMER_BASE + 0x4)
#define MTIMECMP_LO   REG(TIMER_BASE + 0x8)
#define MTIMECMP_HI   REG(TIMER_BASE + 0xC)
#define LCD_CMD       REG(LCD_BASE + 0x0)
#define LCD_DATA      REG(LCD_BASE + 0x4)
#define LCD_STATUS    REG(LCD_BASE + 0x8)
#define SONAR_CTRL    REG(SONAR_BASE + 0x0)
#define SONAR_STATUS  REG(SONAR_BASE + 0x4)
#define SONAR_ECHO_US REG(SONAR_BASE + 0x8)
#define BUZZ_HALF_US  REG(BUZZER_BASE + 0x0)
#define BUZZ_DUR_MS   REG(BUZZER_BASE + 0x4)
#define SEG_HEX       REG(SEG_BASE + 0x0)
#define SEG_RAW       REG(SEG_BASE + 0x4)
#define SEG_DP        REG(SEG_BASE + 0x8)
#define IRQ_PENDING   REG(IRQ_BASE + 0x0)
#define IRQ_ENABLE    REG(IRQ_BASE + 0x4)

#define IRQ_SRC_UART   (1u << 0)
#define IRQ_SRC_BUTTON (1u << 1)
#define IRQ_SRC_SONAR  (1u << 2)

// ---------------- CSRs ----------------
#define csr_read(name) ({ uint32_t __v; __asm__ volatile ("csrr %0, " #name : "=r"(__v)); __v; })
#define csr_write(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))
#define csr_set(name, v)   __asm__ volatile ("csrs " #name ", %0" :: "r"(v))
#define csr_clear(name, v) __asm__ volatile ("csrc " #name ", %0" :: "r"(v))

// perf counters (custom meanings, see README)
#define perf_mispredicts()  csr_read(0xB03)
#define perf_ctrl_flow()    csr_read(0xB04)
#define perf_load_use()     csr_read(0xB05)
#define perf_div_stalls()   csr_read(0xB06)

#define MSTATUS_MIE (1u << 3)
#define MIE_MTIE    (1u << 7)
#define MIE_MEIE    (1u << 11)

static inline void irq_enable_global(void)  { csr_set(mstatus, MSTATUS_MIE); }
static inline void irq_disable_global(void) { csr_clear(mstatus, MSTATUS_MIE); }

// ---------------- time ----------------
static inline uint64_t time_us(void) {
    uint32_t hi, lo;
    do {                       // re-read if lo wrapped between the two reads
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (hi != MTIME_HI);
    return ((uint64_t)hi << 32) | lo;
}
static inline uint32_t millis(void) { return (uint32_t)(time_us() / 1000u); }
void delay_us(uint32_t us);
void delay_ms(uint32_t ms);
void timer_set_alarm_us(uint32_t us_from_now);

// ---------------- UART ----------------
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_uint(uint32_t v);
void uart_put_int(int32_t v);
void uart_put_hex(uint32_t v);
int  uart_getc(void);          // -1 if nothing waiting

// ---------------- LCD 1602 ----------------
void lcd_clear(void);
void lcd_goto(int col, int row);
void lcd_putc(char c);
void lcd_puts(const char *s);
void lcd_put_uint(uint32_t v);
void lcd_custom_char(int slot, const uint8_t rows[8]);
void lcd_wait_idle(void);

// ---------------- sonar (HC-SR04) ----------------
uint32_t sonar_read_cm(void);  // blocking single ping, 0 = nothing in range

// ---------------- buzzer ----------------
void tone(uint32_t hz, uint32_t ms);   // non-blocking, hardware stops it
void no_tone(void);

// ---------------- misc ----------------
static inline void sim_exit(uint32_t code) { REG(SIM_EXIT) = code; for (;;) {} }
void print_perf(void);

#endif
