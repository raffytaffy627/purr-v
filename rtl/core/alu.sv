// alu.sv - the RV32I integer ALU
//
// written to be small on a little FPGA :p
//   * ONE 33-bit adder does add, sub, slt and sltu
//   * ONE right barrel shifter does srl, sra AND sll (bit-reverse in, reverse out)
// the first version had 3 shifters + 3 subtractors and ate ~1000 LUTs lol

`include "purrv_defs.svh"

module alu (
    input  logic [3:0]  op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
    // ---------------- add / sub / compare ----------------
    logic        is_sub, cmp_signed;
    logic [32:0] a_ext, b_ext, sum;

    assign is_sub     = (op == `ALU_SUB) || (op == `ALU_SLT) || (op == `ALU_SLTU);
    assign cmp_signed = (op == `ALU_SLT);
    // sign-extend to 33 bits for signed compares, zero-extend otherwise, then
    // bit 32 of (a - b) is exactly "a < b"
    assign a_ext = {cmp_signed & a[31], a};
    assign b_ext = {cmp_signed & b[31], b};
    assign sum   = a_ext + (is_sub ? ~b_ext : b_ext) + {32'b0, is_sub};

    // ---------------- shifts ----------------
    function automatic logic [31:0] rev(input logic [31:0] v);
        for (int i = 0; i < 32; i++) rev[i] = v[31 - i];
    endfunction

    logic [31:0] sh_in, sh_out;
    logic [32:0] sh_wide;
    assign sh_in   = (op == `ALU_SLL) ? rev(a) : a;
    assign sh_wide = $signed({(op == `ALU_SRA) & a[31], sh_in}) >>> b[4:0];
    assign sh_out  = (op == `ALU_SLL) ? rev(sh_wide[31:0]) : sh_wide[31:0];

    // ---------------- result ----------------
    always_comb begin
        case (op)
            `ALU_ADD,
            `ALU_SUB:   y = sum[31:0];
            `ALU_SLT,
            `ALU_SLTU:  y = {31'b0, sum[32]};
            `ALU_SLL,
            `ALU_SRL,
            `ALU_SRA:   y = sh_out;
            `ALU_XOR:   y = a ^ b;
            `ALU_OR:    y = a | b;
            `ALU_AND:   y = a & b;
            `ALU_PASSB: y = b;
            default:    y = 32'b0;
        endcase
    end
endmodule
