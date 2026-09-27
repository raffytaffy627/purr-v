// purrv_defs.svh - shared constants for the purr-V core :3
// kept as `defines (not a package) so Icarus Verilog 12 is happy with it

`ifndef PURRV_DEFS_SVH
`define PURRV_DEFS_SVH

// ---- RV32 base opcodes (instr[6:0]) ----
`define OP_LUI      7'b0110111
`define OP_AUIPC    7'b0010111
`define OP_JAL      7'b1101111
`define OP_JALR     7'b1100111
`define OP_BRANCH   7'b1100011
`define OP_LOAD     7'b0000011
`define OP_STORE    7'b0100011
`define OP_IMM      7'b0010011
`define OP_REG      7'b0110011
`define OP_FENCE    7'b0001111
`define OP_SYSTEM   7'b1110011

// ---- ALU ops ----
`define ALU_ADD     4'd0
`define ALU_SUB     4'd1
`define ALU_SLL     4'd2
`define ALU_SLT     4'd3
`define ALU_SLTU    4'd4
`define ALU_XOR     4'd5
`define ALU_SRL     4'd6
`define ALU_SRA     4'd7
`define ALU_OR      4'd8
`define ALU_AND     4'd9
`define ALU_PASSB   4'd10   // LUI just passes the immediate through

// ---- branch predictor entry types (what the BTB remembers about a pc) ----
`define BT_BRANCH   2'd0
`define BT_JUMP     2'd1
`define BT_CALL     2'd2
`define BT_RET      2'd3

// ---- CSR addresses we implement ----
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MHPM3     12'hB03   // branch/jump mispredicts
`define CSR_MHPM4     12'hB04   // branches + jumps resolved
`define CSR_MHPM5     12'hB05   // load-use stall cycles
`define CSR_MHPM6     12'hB06   // divider stall cycles
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_CYCLE     12'hC00
`define CSR_TIME      12'hC01
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_TIMEH     12'hC81
`define CSR_INSTRETH  12'hC82
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14

// ---- mcause codes ----
`define CAUSE_MISALIGNED_FETCH  32'd0
`define CAUSE_ILLEGAL_INSTR     32'd2
`define CAUSE_BREAKPOINT        32'd3
`define CAUSE_MISALIGNED_LOAD   32'd4
`define CAUSE_MISALIGNED_STORE  32'd6
`define CAUSE_ECALL_M           32'd11
`define CAUSE_IRQ_SOFT          32'h8000_0003
`define CAUSE_IRQ_TIMER         32'h8000_0007
`define CAUSE_IRQ_EXT           32'h8000_000B

`endif
