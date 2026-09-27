// tangnano9k_top.sv - purr-V on a Sipeed Tang Nano 9K (GW1NR-9, 27 MHz) :3
//
// onboard stuff:  6 LEDs (active low), S1 = reset, S2 = button 0,
//                 USB-UART through the onboard BL702 (flash programs with
//                 tools/flash.py, no re-synthesis needed)
// ELEGOO kit stuff on the headers: 1602 LCD, HC-SR04, passive buzzer,
//                 4-digit 7-seg, 3 extra push buttons
// pin numbers are in tangnano9k.cst - see docs/wiring.md before plugging
// anything 5 V in!!

module tangnano9k_top (
    input  logic       clk_27m,
    input  logic       btn_s1_n,      // onboard, active low -> reset
    input  logic       btn_s2_n,      // onboard, active low -> button 0
    input  logic [2:0] btn_ext_n,     // kit buttons to GND, internal pull-ups -> buttons 1..3

    input  logic       uart_rx,
    output logic       uart_tx,

    output logic [5:0] led_n,

    output logic       lcd_rs,
    output logic       lcd_e,
    output logic [3:0] lcd_d,

    output logic       sonar_trig,
    input  logic       sonar_echo,    // through a 1k/2k divider!

    output logic       buzz,

    output logic [7:0] seg,
    output logic [3:0] dig
);
    // hold reset for a bit after power-up, and while S1 is held
    logic [15:0] por = 16'd0;
    logic        rst;
    always_ff @(posedge clk_27m) begin
        if (!btn_s1_n)       por <= 16'd0;
        else if (!por[15])   por <= por + 16'd1;
    end
    assign rst = !por[15];

    logic [7:0] leds;
    assign led_n = ~leds[5:0];

    purrv_soc #(
        .CLK_HZ(27_000_000),
        .BAUD(115_200),
        .RAM_WORDS(4096),
        .INIT_FILE("build/demo.hex"),
        .N_LED(8),
        .N_BTN(4)
    ) u_soc (
        .clk(clk_27m), .rst(rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .leds(leds),
        .buttons({~btn_ext_n, ~btn_s2_n}),
        .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_d(lcd_d),
        .sonar_trig(sonar_trig), .sonar_echo(sonar_echo),
        .buzz(buzz),
        .seg(seg), .dig(dig)
    );
endmodule
