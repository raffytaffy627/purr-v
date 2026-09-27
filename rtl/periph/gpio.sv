// gpio.sv - LEDs out, debounced buttons in, button-press interrupts
//   +0x0 LEDS      r/w, 1 = on (board polarity is handled in the top level)
//   +0x4 BUTTONS   r,   1 = pressed right now (debounced)
//   +0x8 PRESSED   r,   sticky "was pressed" bits. write 1s to clear
//   +0xC IRQ_EN    r/w, which buttons raise an interrupt when pressed
//
// debounce is ~5 ms with the 1 µs tick - tactile switches from the kit bounce
// for a couple of ms so this is plenty

module gpio #(
    parameter int N_LED = 8,
    parameter int N_BTN = 4
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             us_tick,
    input  logic             sel,
    input  logic             we,
    input  logic [3:0]       addr,
    input  logic [31:0]      wdata,
    output logic [31:0]      rdata,

    output logic [N_LED-1:0] leds,
    input  logic [N_BTN-1:0] buttons_raw,   // 1 = pressed
    output logic             irq_btn
);
    logic [N_BTN-1:0] s1, s2, stable, pressed, irq_en;
    logic [12:0]      cnt [0:N_BTN-1];

    always_ff @(posedge clk) begin
        s1 <= buttons_raw;
        s2 <= s1;
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            leds    <= '0;
            stable  <= '0;
            pressed <= '0;
            irq_en  <= '0;
            for (i = 0; i < N_BTN; i = i + 1) cnt[i] <= 13'd0;
        end else begin
            for (i = 0; i < N_BTN; i = i + 1) begin
                if (s2[i] == stable[i]) begin
                    cnt[i] <= 13'd0;
                end else if (us_tick) begin
                    if (cnt[i] == 13'd5000) begin
                        stable[i] <= s2[i];
                        if (s2[i]) pressed[i] <= 1'b1;
                        cnt[i] <= 13'd0;
                    end else begin
                        cnt[i] <= cnt[i] + 13'd1;
                    end
                end
            end
            if (sel && we) begin
                case (addr[3:2])
                    2'd0: leds    <= wdata[N_LED-1:0];
                    2'd2: pressed <= pressed & ~wdata[N_BTN-1:0];
                    2'd3: irq_en  <= wdata[N_BTN-1:0];
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        case (addr[3:2])
            2'd0: rdata <= {{(32-N_LED){1'b0}}, leds};
            2'd1: rdata <= {{(32-N_BTN){1'b0}}, stable};
            2'd2: rdata <= {{(32-N_BTN){1'b0}}, pressed};
            2'd3: rdata <= {{(32-N_BTN){1'b0}}, irq_en};
        endcase
    end

    assign irq_btn = |(pressed & irq_en);
endmodule
