// sonar.sv - HC-SR04 ultrasonic sensor, measured in hardware
// (same sensor as my arduino-parking-sensor, but now the timing is done by
//  real logic instead of pulseIn() blocking the whole program :o)
//
//   +0x0 CTRL    write bit0 = fire one ping, bit1 = auto mode (ping every 60 ms)
//   +0x4 STATUS  bit0 = new reading ready (cleared when ECHO_US is read)
//   +0x8 ECHO_US echo pulse width in µs (0 = timed out / nothing in range)
//                distance in cm ~= echo_us / 58
//
// ECHO is a 5 V signal!! put a voltage divider on it before the FPGA pin
// (1k from ECHO, 2k to GND -> ~3.3 V). TRIG is fine straight from 3.3 V.

module sonar (
    input  logic        clk,
    input  logic        rst,
    input  logic        us_tick,
    input  logic        sel,
    input  logic        we,
    input  logic        re,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    output logic        trig,
    input  logic        echo,
    output logic        irq_done
);
    typedef enum logic [1:0] { S_IDLE, S_TRIG, S_WAIT_HI, S_MEASURE } state_t;
    state_t state;

    logic [2:0]  echo_sync;
    logic        echo_s;
    logic [15:0] t;              // µs counter for the current phase
    logic [15:0] echo_us;
    logic        ready, auto_mode;
    logic [15:0] auto_t;

    always_ff @(posedge clk) echo_sync <= {echo_sync[1:0], echo};
    assign echo_s = echo_sync[2];

    logic start;
    assign start = (sel && we && addr[3:2] == 2'd0 && wdata[0]) ||
                   (auto_mode && auto_t == 16'd0 && us_tick);

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            trig      <= 1'b0;
            ready     <= 1'b0;
            echo_us   <= 16'd0;
            auto_mode <= 1'b0;
            auto_t    <= 16'd0;
        end else begin
            if (sel && we && addr[3:2] == 2'd0) auto_mode <= wdata[1];
            if (sel && re && addr[3:2] == 2'd2) ready <= 1'b0;

            if (us_tick) auto_t <= (auto_t == 16'd0) ? 16'd60_000 : auto_t - 16'd1;

            case (state)
                S_IDLE: if (start) begin
                    trig  <= 1'b1;
                    t     <= 16'd0;
                    state <= S_TRIG;
                end
                S_TRIG: if (us_tick) begin
                    t <= t + 16'd1;
                    if (t == 16'd11) begin           // 10+ µs trigger pulse
                        trig  <= 1'b0;
                        t     <= 16'd0;
                        state <= S_WAIT_HI;
                    end
                end
                S_WAIT_HI: begin
                    if (echo_s) begin
                        t     <= 16'd0;
                        state <= S_MEASURE;
                    end else if (us_tick) begin
                        t <= t + 16'd1;
                        if (t == 16'd30_000) begin   // sensor never answered
                            echo_us <= 16'd0;
                            ready   <= 1'b1;
                            state   <= S_IDLE;
                        end
                    end
                end
                S_MEASURE: begin
                    if (!echo_s) begin
                        echo_us <= t;
                        ready   <= 1'b1;
                        state   <= S_IDLE;
                    end else if (us_tick) begin
                        t <= t + 16'd1;
                        if (t == 16'd38_000) begin   // out of range
                            echo_us <= 16'd0;
                            ready   <= 1'b1;
                            state   <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        case (addr[3:2])
            2'd0:    rdata <= {30'b0, auto_mode, state != S_IDLE};
            2'd1:    rdata <= {31'b0, ready};
            2'd2:    rdata <= {16'b0, echo_us};
            default: rdata <= 32'b0;
        endcase
    end

    assign irq_done = ready;
endmodule
