// muldiv.sv - the M extension
//   multiply: single cycle (maps onto the FPGA's DSP blocks)
//   divide:   radix-2 restoring divider, 32 cycles + 1, stalls the pipeline
//             divide-by-zero and overflow are handled up front in 1 cycle :3

module muldiv (
    input  logic        clk,
    input  logic        rst,

    input  logic [2:0]  funct3,     // which M op
    input  logic [31:0] a,
    input  logic [31:0] b,

    // multiply is combinational
    output logic [31:0] mul_result,

    // divide handshake: div_start for one cycle, then wait for div_done
    input  logic        div_start,
    output logic        div_busy,   // a divide is in flight (registered)
    output logic        div_done,   // result valid this cycle
    output logic [31:0] div_result
);
    // ---------------- multiply ----------------
    // sign-extend to 33 bits so one signed multiplier covers MULH/MULHSU/MULHU
    logic        a_signed, b_signed;
    logic [32:0] a_ext, b_ext;
    logic [65:0] product;

    assign a_signed = (funct3 == 3'b001) || (funct3 == 3'b010);   // MULH, MULHSU
    assign b_signed = (funct3 == 3'b001);                         // MULH
    assign a_ext    = {a_signed & a[31], a};
    assign b_ext    = {b_signed & b[31], b};
    assign product  = $signed(a_ext) * $signed(b_ext);
    assign mul_result = (funct3 == 3'b000) ? product[31:0] : product[63:32];

    // ---------------- divide ----------------
    localparam logic [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    logic [1:0]  state;
    logic [5:0]  count;
    logic [31:0] quot, rem, divisor;
    logic        neg_q, neg_r, want_rem;
    logic [31:0] result_q;

    logic        d_signed;
    logic        a_neg, b_neg;
    logic [31:0] a_abs, b_abs;
    assign d_signed = !funct3[0];                 // DIV / REM are signed
    assign a_neg    = d_signed & a[31];
    assign b_neg    = d_signed & b[31];
    assign a_abs    = a_neg ? -a : a;
    assign b_abs    = b_neg ? -b : b;

    // one step of restoring division
    logic [32:0] trial;
    assign trial = {rem[31:0], quot[31]} - {1'b0, divisor};

    assign div_busy   = (state != S_IDLE);
    assign div_done   = (state == S_DONE);
    assign div_result = result_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (div_start) begin
                    want_rem <= funct3[1];
                    if (b == 32'b0) begin
                        // divide by zero: quotient all ones, remainder = dividend
                        result_q <= funct3[1] ? a : 32'hFFFF_FFFF;
                        state    <= S_DONE;
                    end else if (d_signed && a == 32'h8000_0000 && b == 32'hFFFF_FFFF) begin
                        // signed overflow: -2^31 / -1
                        result_q <= funct3[1] ? 32'b0 : 32'h8000_0000;
                        state    <= S_DONE;
                    end else begin
                        quot    <= a_abs;
                        rem     <= 32'b0;
                        divisor <= b_abs;
                        neg_q   <= a_neg ^ b_neg;
                        neg_r   <= a_neg;
                        count   <= 6'd0;
                        state   <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (!trial[32]) begin
                        rem  <= trial[31:0];
                        quot <= {quot[30:0], 1'b1};
                    end else begin
                        rem  <= {rem[30:0], quot[31]};
                        quot <= {quot[30:0], 1'b0};
                    end
                    count <= count + 6'd1;
                    if (count == 6'd31) state <= S_DONE;   // last step lands next edge
                end
                S_DONE: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase

            // fix up signs once the loop is finished (count hits 32 on the edge
            // we enter S_DONE, so compute from the *next* values here)
            if (state == S_RUN && count == 6'd31) begin
                if (want_rem)
                    result_q <= neg_r ? -(trial[32] ? {rem[30:0], quot[31]} : trial[31:0])
                                      :  (trial[32] ? {rem[30:0], quot[31]} : trial[31:0]);
                else
                    result_q <= neg_q ? -{quot[30:0], !trial[32]} : {quot[30:0], !trial[32]};
            end
        end
    end
endmodule
