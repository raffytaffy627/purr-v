// lcd1602.sv - hardware driver for the HD44780 1602 LCD from the ELEGOO kit
//
// the CPU just drops bytes in a FIFO and this module does all the annoying
// timing (4-bit mode, enable pulses, 40 Âµs / 1.6 ms waits, power-on init).
// no more delayMicroseconds() everywhere like on the Arduino :p
//
//   +0x0 CMD     write: command byte (clear = 0x01, set cursor = 0x80|addr ...)
//   +0x4 DATA    write: character byte
//   +0x8 STATUS  bit0 = FIFO full, bit1 = idle (FIFO empty + nothing sending)
//
// wiring: RW tied to GND (we never read the LCD, which also means the 5 V LCD
// never drives anything back into the 3.3 V FPGA pins)

module lcd1602 #(
    parameter int INIT_US = 50_000    // power-on wait (sim shrinks this)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        us_tick,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    output logic        lcd_rs,
    output logic        lcd_e,
    output logic [3:0]  lcd_d        // D4..D7
);
    // ---------------- FIFO of {rs, byte} ----------------
    logic [8:0] fifo [0:15];
    logic [4:0] wp, rp;
    logic       empty, full, push;
    assign empty = (wp == rp);
    assign full  = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);
    assign push  = sel && we && (addr[3:2] == 2'd0 || addr[3:2] == 2'd1) && !full;

    // power-on init sequence, stored as {only_high_nibble, byte}:
    // 0x3 0x3 0x3 0x2 (nibbles, gets it into 4-bit mode no matter what state
    // it woke up in), then 0x28 0x0C 0x06 0x01
    localparam int N_INIT = 8;
    logic [3:0] init_i;
    logic [8:0] init_word;
    always_comb begin
        case (init_i[2:0])
            3'd0, 3'd1, 3'd2: init_word = {1'b1, 8'h30};
            3'd3:             init_word = {1'b1, 8'h20};
            3'd4:             init_word = {1'b0, 8'h28};   // 2 lines, 5x8 font
            3'd5:             init_word = {1'b0, 8'h0C};   // display on, cursor off
            3'd6:             init_word = {1'b0, 8'h06};   // entry mode: move right
            default:          init_word = {1'b0, 8'h01};   // clear
        endcase
    end

    // ---------------- sender FSM ----------------
    typedef enum logic [2:0] {
        S_POWERUP, S_INIT, S_IDLE, S_HI, S_LO, S_WAIT
    } state_t;
    state_t state;

    logic [15:0] wait_us;
    logic [8:0]  cur;            // {rs, byte}
    logic        cur_single;     // only send the high nibble (init)
    logic        e_phase;        // 0 = setup, 1 = E high

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= S_POWERUP;
            wait_us <= 16'(INIT_US > 65535 ? 65535 : INIT_US);
            init_i  <= 4'd0;
            lcd_e   <= 1'b0;
            lcd_rs  <= 1'b0;
            lcd_d   <= 4'd0;
            wp      <= 5'd0;
            rp      <= 5'd0;
            e_phase <= 1'b0;
        end else begin
            if (push) begin
                fifo[wp[3:0]] <= {addr[2], wdata[7:0]};   // addr 0x4 -> rs = 1
                wp <= wp + 5'd1;
            end

            case (state)
                S_POWERUP: if (us_tick) begin
                    if (wait_us == 16'd0) state <= S_INIT;
                    else                  wait_us <= wait_us - 16'd1;
                end
                S_INIT: begin
                    cur        <= {1'b0, init_word[7:0]};
                    cur_single <= init_word[8];
                    init_i     <= init_i + 4'd1;
                    state      <= S_HI;
                end
                S_IDLE: if (!empty) begin
                    cur        <= fifo[rp[3:0]];
                    cur_single <= 1'b0;
                    rp         <= rp + 5'd1;
                    state      <= S_HI;
                end
                // S_HI / S_LO: put a nibble out, wait 1 µs, E high 1 µs, E low
                S_HI, S_LO: begin
                    lcd_rs <= cur[8];
                    lcd_d  <= (state == S_HI) ? cur[7:4] : cur[3:0];
                    if (!e_phase) begin
                        if (us_tick) begin
                            lcd_e   <= 1'b1;
                            e_phase <= 1'b1;
                        end
                    end else if (us_tick) begin
                        lcd_e   <= 1'b0;
                        e_phase <= 1'b0;
                        if (state == S_HI && !cur_single) begin
                            state <= S_LO;
                        end else begin
                            state <= S_WAIT;
                            // clear/home are slow (1.52 ms), init nibbles want >4.1 ms
                            if (cur_single)
                                wait_us <= 16'd4500;
                            else if (!cur[8] && (cur[7:0] == 8'h01 || cur[7:0] == 8'h02))
                                wait_us <= 16'd2000;
                            else
                                wait_us <= 16'd50;
                        end
                    end
                end
                S_WAIT: if (us_tick) begin
                    if (wait_us == 16'd0) state <= (init_i < 4'(N_INIT)) ? S_INIT : S_IDLE;
                    else                  wait_us <= wait_us - 16'd1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        rdata <= {30'b0, empty && state == S_IDLE, full};
    end
endmodule
