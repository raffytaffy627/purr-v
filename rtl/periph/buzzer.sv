// buzzer.sv - square wave generator for the kit's passive buzzer
//   +0x0 HALF_US  half-period in µs (0 = silent)
//                 e.g. 440 Hz (A4) -> 1_000_000 / 440 / 2 = 1136
//   +0x4 DUR_MS   play for this many ms then stop by itself (0 = forever)
// so software can go "beep!" and move on without babysitting it :3

module buzzer (
    input  logic        clk,
    input  logic        rst,
    input  logic        us_tick,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    output logic        buzz
);
    logic [15:0] half_us, cnt;
    logic [15:0] dur_ms;
    logic [9:0]  ms_pre;

    always_ff @(posedge clk) begin
        if (rst) begin
            half_us <= 16'd0;
            dur_ms  <= 16'd0;
            cnt     <= 16'd0;
            ms_pre  <= 10'd0;
            buzz    <= 1'b0;
        end else begin
            if (sel && we && addr[3:2] == 2'd0) begin
                half_us <= wdata[15:0];
                cnt     <= 16'd0;
            end
            if (sel && we && addr[3:2] == 2'd1) begin
                dur_ms <= wdata[15:0];
                ms_pre <= 10'd0;
            end

            if (half_us == 16'd0) begin
                buzz <= 1'b0;
            end else if (us_tick) begin
                if (cnt >= half_us - 16'd1) begin
                    cnt  <= 16'd0;
                    buzz <= !buzz;
                end else begin
                    cnt <= cnt + 16'd1;
                end

                // auto-stop timer
                if (dur_ms != 16'd0) begin
                    if (ms_pre == 10'd999) begin
                        ms_pre <= 10'd0;
                        dur_ms <= dur_ms - 16'd1;
                        if (dur_ms == 16'd1) half_us <= 16'd0;
                    end else begin
                        ms_pre <= ms_pre + 10'd1;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk)
        rdata <= addr[2] ? {16'b0, dur_ms} : {16'b0, half_us};
endmodule
