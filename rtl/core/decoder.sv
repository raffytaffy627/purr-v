// decoder.sv - turns a 32-bit RV32IM + Zicsr instruction into control signals
// purely combinational, lives in the ID stage

`include "purrv_defs.svh"

module decoder (
    input  logic [31:0] instr,

    output logic [4:0]  rd,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic        uses_rs1,
    output logic        uses_rs2,
    output logic        reg_write,
    output logic [31:0] imm,

    output logic [3:0]  alu_op,
    output logic        src_a_pc,     // AUIPC / JAL use pc as operand A
    output logic        src_b_imm,    // I/S/U-type use imm as operand B

    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr,
    output logic [2:0]  funct3,

    output logic        is_load,
    output logic        is_store,

    output logic        is_mul,       // MUL/MULH/MULHSU/MULHU (single cycle)
    output logic        is_div,       // DIV/DIVU/REM/REMU (iterative, stalls)

    output logic        is_csr,
    output logic [11:0] csr_addr,
    output logic        csr_use_imm,  // CSRRWI/CSRRSI/CSRRCI
    output logic        is_ecall,
    output logic        is_ebreak,
    output logic        is_mret,
    output logic        is_fence_i,
    output logic        illegal
);
    logic [6:0] opcode, funct7;
    assign opcode   = instr[6:0];
    assign funct7   = instr[31:25];
    assign funct3   = instr[14:12];
    assign rd       = instr[11:7];
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign csr_addr = instr[31:20];

    // immediates for every format, picked below
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'b0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    always_comb begin
        // safe defaults = a nop that writes nothing
        uses_rs1    = 1'b0;
        uses_rs2    = 1'b0;
        reg_write   = 1'b0;
        imm         = imm_i;
        alu_op      = `ALU_ADD;
        src_a_pc    = 1'b0;
        src_b_imm   = 1'b0;
        is_branch   = 1'b0;
        is_jal      = 1'b0;
        is_jalr     = 1'b0;
        is_load     = 1'b0;
        is_store    = 1'b0;
        is_mul      = 1'b0;
        is_div      = 1'b0;
        is_csr      = 1'b0;
        csr_use_imm = 1'b0;
        is_ecall    = 1'b0;
        is_ebreak   = 1'b0;
        is_mret     = 1'b0;
        is_fence_i  = 1'b0;
        illegal     = 1'b0;

        case (opcode)
            `OP_LUI: begin
                reg_write = 1'b1;
                imm       = imm_u;
                src_b_imm = 1'b1;
                alu_op    = `ALU_PASSB;
            end
            `OP_AUIPC: begin
                reg_write = 1'b1;
                imm       = imm_u;
                src_a_pc  = 1'b1;
                src_b_imm = 1'b1;
            end
            `OP_JAL: begin
                reg_write = 1'b1;
                imm       = imm_j;
                is_jal    = 1'b1;
            end
            `OP_JALR: begin
                reg_write = 1'b1;
                uses_rs1  = 1'b1;
                imm       = imm_i;
                is_jalr   = 1'b1;
                if (funct3 != 3'b000) illegal = 1'b1;
            end
            `OP_BRANCH: begin
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                imm       = imm_b;
                is_branch = 1'b1;
                if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
            end
            `OP_LOAD: begin
                reg_write = 1'b1;
                uses_rs1  = 1'b1;
                imm       = imm_i;
                src_b_imm = 1'b1;
                is_load   = 1'b1;
                // valid: LB LH LW LBU LHU
                if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) illegal = 1'b1;
            end
            `OP_STORE: begin
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                imm       = imm_s;
                src_b_imm = 1'b1;
                is_store  = 1'b1;
                if (funct3 > 3'b010) illegal = 1'b1;
            end
            `OP_IMM: begin
                reg_write = 1'b1;
                uses_rs1  = 1'b1;
                imm       = imm_i;
                src_b_imm = 1'b1;
                case (funct3)
                    3'b000: alu_op = `ALU_ADD;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                    3'b001: begin
                        alu_op = `ALU_SLL;
                        if (funct7 != 7'b0000000) illegal = 1'b1;
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000)      alu_op = `ALU_SRL;
                        else if (funct7 == 7'b0100000) alu_op = `ALU_SRA;
                        else                           illegal = 1'b1;
                    end
                endcase
            end
            `OP_REG: begin
                reg_write = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                if (funct7 == 7'b0000001) begin
                    // M extension :o
                    if (funct3[2]) is_div = 1'b1;
                    else           is_mul = 1'b1;
                end else if (funct7 == 7'b0000000) begin
                    case (funct3)
                        3'b000: alu_op = `ALU_ADD;
                        3'b001: alu_op = `ALU_SLL;
                        3'b010: alu_op = `ALU_SLT;
                        3'b011: alu_op = `ALU_SLTU;
                        3'b100: alu_op = `ALU_XOR;
                        3'b101: alu_op = `ALU_SRL;
                        3'b110: alu_op = `ALU_OR;
                        3'b111: alu_op = `ALU_AND;
                    endcase
                end else if (funct7 == 7'b0100000) begin
                    if (funct3 == 3'b000)      alu_op = `ALU_SUB;
                    else if (funct3 == 3'b101) alu_op = `ALU_SRA;
                    else                       illegal = 1'b1;
                end else begin
                    illegal = 1'b1;
                end
            end
            `OP_FENCE: begin
                // FENCE is a nop here (one hart, in-order memory)
                // FENCE.I flushes the pipeline so self-modifying code / freshly
                // written code gets refetched
                if (funct3 == 3'b001)      is_fence_i = 1'b1;
                else if (funct3 != 3'b000) illegal    = 1'b1;
            end
            `OP_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    // rd/rs1 must be zero for these
                    if (instr[31:7] == 25'h0000000)          is_ecall  = 1'b1;
                    else if (instr[31:7] == 25'h0002000)     is_ebreak = 1'b1;
                    else if (instr[31:7] == 25'h0604000)     is_mret   = 1'b1;
                    else if (instr[31:7] == 25'h020A000)     ; // WFI = nop, software just spins
                    else                                     illegal   = 1'b1;
                end else if (funct3 == 3'b100) begin
                    illegal = 1'b1;
                end else begin
                    is_csr      = 1'b1;
                    reg_write   = 1'b1;
                    csr_use_imm = funct3[2];
                    uses_rs1    = !funct3[2];
                end
            end
            default: illegal = 1'b1;
        endcase

        // an illegal instruction must not have side effects
        if (illegal) begin
            reg_write = 1'b0;
            is_load   = 1'b0;
            is_store  = 1'b0;
            is_mul    = 1'b0;
            is_div    = 1'b0;
            is_csr    = 1'b0;
            is_branch = 1'b0;
            is_jal    = 1'b0;
            is_jalr   = 1'b0;
        end
    end
endmodule
