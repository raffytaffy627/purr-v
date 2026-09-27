// parking - my arduino-parking-sensor (V5), ported to my own CPU :3
//
// same thresholds as the Arduino version:
//   > 30 cm (or nothing)  green
//   15..30 cm             yellow
//   5..15 cm              red + short beeps
//   < 5 cm                red + solid tone
//
// what's different:
//   * the HC-SR04 runs in hardware auto mode and fires an INTERRUPT when a
//     reading is ready - no pulseIn() freezing the whole loop
//   * the 7-seg is multiplexed in hardware, so no flicker when the CPU is busy
//   * the LCD gets the distance + a little bar graph
//   * button 0 (S2 on the Tang Nano) mutes the buzzer, also via interrupt

#include "purrv.h"

static volatile uint32_t distance_cm;
static volatile uint32_t new_reading;
static volatile uint32_t muted;

// one trap handler for everything. gcc saves/restores registers for us
__attribute__((interrupt("machine"))) static void on_trap(void) {
    uint32_t cause = csr_read(mcause);
    if (cause == 0x8000000Bu) {                     // external interrupt
        uint32_t pending = IRQ_PENDING;
        if (pending & IRQ_SRC_SONAR) {
            distance_cm = SONAR_ECHO_US / 58u;      // reading clears the flag
            new_reading = 1;
        }
        if (pending & IRQ_SRC_BUTTON) {
            if (GPIO_PRESSED & 1u) muted ^= 1u;
            GPIO_PRESSED = 0xF;                     // write 1s to clear
        }
    } else {
        // unexpected exception - park here so it's obvious on the LEDs
        GPIO_LEDS = 0x3F;
        for (;;) {}
    }
}

// 7-seg patterns, bit order dp g f e d c b a (same table as the Arduino sketch)
static const uint8_t digits7[10] = {
    0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F
};

static void show_7seg(uint32_t v) {
    uint32_t raw = 0;
    for (int d = 0; d < 4; d++) {
        raw |= (uint32_t)digits7[v % 10u] << (8 * d);
        v /= 10u;
    }
    SEG_RAW = raw;
}

static void show_lcd(uint32_t cm) {
    lcd_goto(0, 0);
    lcd_puts("dist: ");
    if (cm == 0) {
        lcd_puts("---   ");
    } else {
        lcd_put_uint(cm);
        lcd_puts(" cm   ");
    }
    // bar graph: closer = fuller, 16 chars = 0 cm, empty at 50+ cm
    uint32_t fill = (cm == 0 || cm >= 50u) ? 0 : 16u - cm * 16u / 50u;
    lcd_goto(0, 1);
    for (uint32_t i = 0; i < 16; i++) lcd_putc(i < fill ? (char)0xFF : ' ');
}

enum { LED_GREEN = 1, LED_YELLOW = 2, LED_RED = 4 };

int main(void) {
    uart_puts("purr-V parking sensor :3\n");
    lcd_clear();

    csr_write(mtvec, (uint32_t)&on_trap);
    GPIO_IRQ_EN = 1;                                // button 0
    IRQ_ENABLE  = IRQ_SRC_SONAR | IRQ_SRC_BUTTON;
    csr_write(mie, MIE_MEIE);
    irq_enable_global();

    SONAR_CTRL = 2;                                 // auto mode: ping every 60 ms

    uint32_t last_beep = 0;
    for (;;) {
        if (!new_reading) continue;
        new_reading = 0;
        uint32_t cm = distance_cm;

        uart_puts("Distance: ");
        uart_put_uint(cm);
        uart_puts(" cm\n");
        show_7seg(cm);
        show_lcd(cm);

        if (cm == 0 || cm > 30) {
            GPIO_LEDS = LED_GREEN;
            no_tone();
        } else if (cm > 15) {
            GPIO_LEDS = LED_YELLOW;
            no_tone();
        } else if (cm > 5) {
            GPIO_LEDS = LED_RED;
            // beep faster the closer you get
            uint32_t gap = cm * 20u;
            if (!muted && millis() - last_beep > gap) {
                tone(2000, 30);                     // hardware stops it after 30 ms
                last_beep = millis();
            }
        } else {
            GPIO_LEDS = LED_RED;
            if (!muted) tone(2000, 0);
            else        no_tone();
        }

#ifdef SIM_DEMO
        // in the testbench, stop after a few readings
        static int n;
        if (++n == 3) { lcd_wait_idle(); return 0; }
#endif
    }
}
