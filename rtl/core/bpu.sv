// bpu.sv - branch prediction unit :o
//
//   * BTB  - direct-mapped branch target buffer, remembers "this pc is a
//            branch/jump/call/return and last time it went HERE"
//   * gshare - 2-bit saturating counters indexed by pc XOR global history,
//              decides taken / not-taken for conditional branches
//   * RAS  - return address stack, so `ret` predicts right even when the
//            function is called from a bunch of different places
//
// prediction happens in IF (same cycle the pc is sent to memory), the real
// outcome gets fed back from EX. if IF guessed wrong, EX flushes 2 instrs.

`include "purrv_defs.svh"

module bpu #(
    parameter int BTB_BITS  = 4,     // 16 entries
    parameter int GHR_BITS  = 7,     // 128 gshare counters
    parameter int RAS_DEPTH = 4
) (
    input  logic                clk,
    input  logic                rst,

    // ---- IF lookup ----
    input  logic [31:0]         if_pc,
    input  logic                if_fire,       // IF instr really moves on (push/pop RAS)
    output logic                pred_taken,
    output logic [31:0]         pred_target,
    output logic [GHR_BITS-1:0] pred_idx,      // gshare index used, carried to EX

    // ---- EX update ----
    input  logic                upd_valid,     // a control-flow instr resolved
    input  logic [31:0]         upd_pc,
    input  logic                upd_is_branch,
    input  logic                upd_taken,
    input  logic [31:0]         upd_target,
    input  logic [1:0]          upd_type,
    input  logic [GHR_BITS-1:0] upd_idx,
    input  logic                upd_kill       // BTB hit on something that isn't a jump - drop it
);
    localparam int BTB_N = 1 << BTB_BITS;
    localparam int PHT_N = 1 << GHR_BITS;
    localparam int TAG_W = 10;

    // ---------------- storage ----------------
    logic                btb_valid  [0:BTB_N-1];
    logic [TAG_W-1:0]    btb_tag    [0:BTB_N-1];
    logic [31:2]         btb_target [0:BTB_N-1];
    logic [1:0]          btb_type   [0:BTB_N-1];
    logic [1:0]          pht        [0:PHT_N-1];
    logic [GHR_BITS-1:0] ghr;
    logic [31:0]         ras        [0:RAS_DEPTH-1];
    logic [$clog2(RAS_DEPTH)-1:0] ras_top;   // points at newest entry

    integer i;
    // start everything at a known value. an X target in sim makes the EX
    // compare go X and silently skip a redirect (found that one via the fuzzer :o)
    initial begin
        for (i = 0; i < PHT_N; i = i + 1)     pht[i] = 2'b01;   // weakly not-taken
        for (i = 0; i < BTB_N; i = i + 1)     begin btb_tag[i] = '0; btb_target[i] = '0; btb_type[i] = '0; end
        for (i = 0; i < RAS_DEPTH; i = i + 1) ras[i] = 32'b0;
    end

    // ---------------- lookup (IF) ----------------
    logic [BTB_BITS-1:0] if_set;
    logic [TAG_W-1:0]    if_tag;
    logic                btb_hit;
    logic [1:0]          hit_type;

    assign if_set   = if_pc[BTB_BITS+1:2];
    assign if_tag   = if_pc[BTB_BITS+TAG_W+1:BTB_BITS+2];
    assign btb_hit  = btb_valid[if_set] && (btb_tag[if_set] == if_tag);
    assign hit_type = btb_type[if_set];
    assign pred_idx = if_pc[GHR_BITS+1:2] ^ ghr;

    // plain assigns (not always_comb) so Icarus doesn't wake up on every
    // array element change
    logic [1:0]  pht_ctr;
    logic [31:0] btb_tgt, ras_tgt;
    assign pht_ctr = pht[pred_idx];
    assign btb_tgt = {btb_target[if_set], 2'b00};
    assign ras_tgt = ras[ras_top];

    assign pred_taken  = btb_hit && ((hit_type == `BT_BRANCH) ? pht_ctr[1] : 1'b1);
    assign pred_target = (hit_type == `BT_RET) ? ras_tgt : btb_tgt;

    // ---------------- update ----------------
    logic [BTB_BITS-1:0] u_set;
    assign u_set = upd_pc[BTB_BITS+1:2];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BTB_N; i = i + 1) btb_valid[i] <= 1'b0;
            ghr     <= '0;
            ras_top <= '0;
        end else begin
            // RAS moves speculatively in IF. no repair on a flush - worst case
            // a return mispredicts once and EX fixes it, still correct :p
            if (if_fire && btb_hit && pred_taken) begin
                if (hit_type == `BT_CALL) begin
                    ras[ras_top + 1'b1] <= if_pc + 32'd4;
                    ras_top             <= ras_top + 1'b1;
                end else if (hit_type == `BT_RET) begin
                    ras_top <= ras_top - 1'b1;
                end
            end

            if (upd_valid) begin
                if (upd_is_branch) begin
                    ghr <= {ghr[GHR_BITS-2:0], upd_taken};
                    if (upd_taken  && pht[upd_idx] != 2'b11) pht[upd_idx] <= pht[upd_idx] + 2'b01;
                    if (!upd_taken && pht[upd_idx] != 2'b00) pht[upd_idx] <= pht[upd_idx] - 2'b01;
                end
                // only remember things that actually jumped somewhere
                if (upd_taken) begin
                    btb_valid[u_set]  <= 1'b1;
                    btb_tag[u_set]    <= upd_pc[BTB_BITS+TAG_W+1:BTB_BITS+2];
                    btb_target[u_set] <= upd_target[31:2];
                    btb_type[u_set]   <= upd_type;
                end
            end else if (upd_kill) begin
                btb_valid[u_set] <= 1'b0;
            end
        end
    end
endmodule
