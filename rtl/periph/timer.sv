// timer.sv - RISC-V style mtime / mtimecmp, ticking once per microsecond
//   +0x0 MTIME lo    +0x4 MTIME hi
//   +0x8 MTIMECMP lo +0xC MTIMECMP hi
// irq_timer stays high while mtime >= mtimecmp (write a new cmp to clear it)
// us_tick is shared with the other peripherals so they all count in µs :3

module timer #(
    parameter int CLK_HZ = 27_000_000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    output logic [63:0] mtime,
    output logic        us_tick,
    output logic        irq_timer
);
    localparam int TICKS_PER_US = (CLK_HZ / 1_000_000) > 0 ? (CLK_HZ / 1_000_000) : 1;

    logic [7:0]  pre;
    logic [63:0] mtimecmp;

    assign us_tick = (pre == 8'(TICKS_PER_US - 1));

    always_ff @(posedge clk) begin
        if (rst) begin
            pre      <= 8'd0;
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            pre <= us_tick ? 8'd0 : pre + 8'd1;
            if (us_tick) mtime <= mtime + 64'd1;
            if (sel && we) begin
                case (addr[3:2])
                    2'd0: mtime[31:0]     <= wdata;
                    2'd1: mtime[63:32]    <= wdata;
                    2'd2: mtimecmp[31:0]  <= wdata;
                    2'd3: mtimecmp[63:32] <= wdata;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        case (addr[3:2])
            2'd0: rdata <= mtime[31:0];
            2'd1: rdata <= mtime[63:32];
            2'd2: rdata <= mtimecmp[31:0];
            2'd3: rdata <= mtimecmp[63:32];
        endcase
    end

    assign irq_timer = (mtime >= mtimecmp);
endmodule
