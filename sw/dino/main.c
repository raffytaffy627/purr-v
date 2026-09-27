// dino - chrome-dino-style runner on the 16x2 LCD :3
//   button 0 (or any button) = jump, dodge the cacti, score goes up,
//   game speeds up the longer you survive. buzzer goes boop.
//   the score also shows on the 7-seg, high score survives restarts
//   (well, until you unplug it :p)

#include "purrv.h"

enum { CH_DINO = 0, CH_DINO2 = 1, CH_CACTUS = 2, CH_HEART = 3 };

static const uint8_t dino_a[8]  = {0x07, 0x05, 0x07, 0x16, 0x1F, 0x1E, 0x0E, 0x04};
static const uint8_t dino_b[8]  = {0x07, 0x05, 0x07, 0x16, 0x1F, 0x1E, 0x0E, 0x02};  // other leg
static const uint8_t cactus[8]  = {0x04, 0x05, 0x15, 0x15, 0x16, 0x0C, 0x04, 0x04};
static const uint8_t heart[8]   = {0x00, 0x0A, 0x1F, 0x1F, 0x0E, 0x04, 0x00, 0x00};

#define W 16
static char ground[W];       // what's on the bottom row
static uint32_t rng = 0xC0FFEE;

static uint32_t rand32(void) {             // xorshift, good enough for cacti
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

static int button_pressed(void) {
    uint32_t p = GPIO_PRESSED;
    GPIO_PRESSED = 0xF;
    return p != 0;
}

static void draw(int dino_up, int frame, uint32_t score) {
    lcd_goto(0, 0);
    lcd_putc(' ');
    lcd_putc(dino_up ? (char)CH_DINO : ' ');
    lcd_puts("         ");
    // score, right aligned in 5 chars
    char buf[6] = "     ";
    uint32_t s = score;
    for (int i = 4; i >= 0 && (s || i == 4); i--) { buf[i] = (char)('0' + s % 10u); s /= 10u; }
    lcd_puts(buf);

    lcd_goto(0, 1);
    for (int i = 0; i < W; i++) {
        if (i == 1 && !dino_up) lcd_putc((char)((frame & 1) ? CH_DINO2 : CH_DINO));
        else                    lcd_putc(ground[i] ? (char)CH_CACTUS : ' ');
    }
}

static uint32_t play(uint32_t high) {
    for (int i = 0; i < W; i++) ground[i] = 0;
    uint32_t score = 0, frame = 0, gap = 0;
#ifdef SIM_DEMO
    uint32_t tick_ms = 2;                 // sim time is expensive :p
#else
    uint32_t tick_ms = 180;
#endif
    int air = 0;                          // frames left in the air

    button_pressed();
    for (;;) {
        uint32_t t0 = millis();

#ifdef SIM_DEMO
        int jump = ground[3] && !air;     // autopilot for the testbench
#else
        int jump = button_pressed();
#endif
        if (jump && !air) {
            air = 3;
            tone(880, 40);
        }

        // scroll the world left
        for (int i = 0; i < W - 1; i++) ground[i] = ground[i + 1];
        // new cactus sometimes, but always leave room to land
        if (gap >= 3 && (rand32() & 3) == 0) {
            ground[W - 1] = 1;
            gap = 0;
        } else {
            ground[W - 1] = 0;
            gap++;
        }

        if (ground[1] && !air) break;    // ouch
        if (ground[1]) score++;          // jumped over one
        if (air) air--;

        draw(air > 0, (int)frame++, score);
        SEG_HEX = score;

        if (score && score % 5 == 0 && tick_ms > 80) tick_ms -= 1;   // speed up
#ifdef SIM_DEMO
        if (score >= 3) return score;
#endif
        while (millis() - t0 < tick_ms) {}
    }

    // game over :(
    tone(220, 300);
    lcd_goto(0, 0);
    lcd_puts(score > high ? "NEW HIGH SCORE! " : "  game over :(  ");
    lcd_goto(0, 1);
    lcd_puts("score ");
    lcd_put_uint(score);
    lcd_puts("  hi ");
    lcd_put_uint(score > high ? score : high);
    lcd_puts("   ");
    delay_ms(1500);
    return score;
}

int main(void) {
    uart_puts("purr-V dino :3  press a button to jump\n");
    lcd_custom_char(CH_DINO, dino_a);
    lcd_custom_char(CH_DINO2, dino_b);
    lcd_custom_char(CH_CACTUS, cactus);
    lcd_custom_char(CH_HEART, heart);
    lcd_clear();

    uint32_t high = 0;
    for (;;) {
        lcd_goto(0, 0);
        lcd_puts(" purr-V  dino ");
        lcd_putc((char)CH_HEART);
        lcd_puts(" ");
        lcd_goto(0, 1);
        lcd_puts(" press to start ");
#ifndef SIM_DEMO
        while (!button_pressed()) rng += 7;  // timing of the press seeds the rng
#endif
        rng ^= (uint32_t)time_us();
        uint32_t s = play(high);
        if (s > high) high = s;
        uart_puts("score: ");
        uart_put_uint(s);
        uart_puts("\n");
#ifdef SIM_DEMO
        lcd_wait_idle();
        return s >= 3 ? 0 : 1;
#endif
    }
}
