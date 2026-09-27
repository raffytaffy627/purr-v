// purrv_core.sv - the purr-V RV32IM_Zicsr core :3
//
//  IF -> ID -> EX -> MEM -> WB    classic 5-stage in-order pipeline
//
//  * full forwarding (MEM->EX and WB->EX, plus write-first regfile for WB->ID)
//  * 1-cycle load-use bubble, nothing else stalls except the divider
//  * gshare + BTB + return address stack in IF, resolved in EX
//    (a mispredict costs 3 cycles - the redirect is registered so the long
//     "load data -> forward -> branch compare -> next pc -> BRAM address" path
//     doesn't have to fit in one clock. that got us from 26 to 27+ MHz :3)
//  * precise traps + interrupts, all decided in EX
//
// memory ports are synchronous (FPGA block RAM):
//   imem: address = next pc, so the instruction for `pc_if` is ready while
//         pc_if is in IF
//   dmem: address/write in MEM, read data shows up in WB

`include "purrv_defs.svh"

module purrv_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000,
    parameter int          GHR_BITS = 7
) (
    input  logic        clk,
    input  logic        rst,

    // instruction port
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    // data port
    output logic        dmem_re,
    output logic        dmem_we,
    output logic [3:0]  dmem_wstrb,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,     // valid the cycle after dmem_re (in WB)

    // interrupts
    input  logic        irq_timer,
    input  logic        irq_ext,
    input  logic [63:0] mtime,

    // retire trace (sim/debug only, optimised away on the FPGA)
    output logic        trace_valid,
    output logic [31:0] trace_pc,
    output logic [31:0] trace_instr,
    output logic        trace_we,
    output logic [4:0]  trace_rd,
    output logic [31:0] trace_wdata
);
    // =====================================================================
    // hazard / flow control signals (driven further down)
    // =====================================================================
    logic        redirect;           // EX says: fetch from redirect_pc instead
    logic [31:0] redirect_pc;
    logic        redirect_q;         // ...and IF actually does it one cycle later
    logic [31:0] redirect_pc_q;
    logic        stall_ex;           // divider still busy
    logic        load_use;           // ID needs a value a load in EX is fetching

    // =====================================================================
    // IF
    // =====================================================================
    logic [31:0]         pc_if, pc_if_next;
    logic                bp_taken;
    logic [31:0]         bp_target;
    logic [GHR_BITS-1:0] bp_idx;
    logic                if_fire;

    // bpu update wires (from EX)
    logic                bpu_upd_valid, bpu_upd_is_branch, bpu_upd_taken, bpu_upd_kill;
    logic [31:0]         bpu_upd_pc, bpu_upd_target;
    logic [1:0]          bpu_upd_type;
    logic [GHR_BITS-1:0] bpu_upd_idx;

    bpu #(.GHR_BITS(GHR_BITS)) u_bpu (
        .clk(clk), .rst(rst),
        .if_pc(pc_if), .if_fire(if_fire),
        .pred_taken(bp_taken), .pred_target(bp_target), .pred_idx(bp_idx),
        .upd_valid(bpu_upd_valid), .upd_pc(bpu_upd_pc), .upd_is_branch(bpu_upd_is_branch),
        .upd_taken(bpu_upd_taken), .upd_target(bpu_upd_target), .upd_type(bpu_upd_type),
        .upd_idx(bpu_upd_idx), .upd_kill(bpu_upd_kill)
    );

    logic stall_if;
    assign stall_if = stall_ex || load_use;
    assign if_fire  = !redirect && !redirect_q && !stall_if && !rst;

    always_comb begin
        if (rst)             pc_if_next = RESET_PC;
        else if (redirect_q) pc_if_next = redirect_pc_q;
        else if (stall_if)   pc_if_next = pc_if;
        else if (bp_taken)  pc_if_next = bp_target;
        else                pc_if_next = pc_if + 32'd4;
    end

    assign imem_addr = pc_if_next;

    always_ff @(posedge clk) pc_if <= pc_if_next;

    always_ff @(posedge clk) begin
        redirect_q    <= redirect && !rst;
        redirect_pc_q <= redirect_pc;
    end

    // =====================================================================
    // IF/ID
    // =====================================================================
    logic                id_valid;
    logic [31:0]         id_pc, id_instr;
    logic                id_pred_taken;
    logic [31:0]         id_pred_target;
    logic [GHR_BITS-1:0] id_pred_idx;

    always_ff @(posedge clk) begin
        if (rst || redirect || redirect_q) begin
            // redirect: kill ID. redirect_q: whatever IF grabbed was wrong-path
            id_valid <= 1'b0;
        end else if (!stall_if) begin
            id_valid       <= 1'b1;
            id_pc          <= pc_if;
            id_instr       <= imem_rdata;
            id_pred_taken  <= bp_taken;
            id_pred_target <= bp_target;
            id_pred_idx    <= bp_idx;
        end
    end

    // =====================================================================
    // ID
    // =====================================================================
    logic [4:0]  d_rd, d_rs1, d_rs2;
    logic        d_uses_rs1, d_uses_rs2, d_reg_write;
    logic [31:0] d_imm;
    logic [3:0]  d_alu_op;
    logic        d_src_a_pc, d_src_b_imm;
    logic        d_is_branch, d_is_jal, d_is_jalr;
    logic [2:0]  d_funct3;
    logic        d_is_load, d_is_store, d_is_mul, d_is_div;
    logic        d_is_csr, d_csr_use_imm;
    logic [11:0] d_csr_addr;
    logic        d_is_ecall, d_is_ebreak, d_is_mret, d_is_fence_i, d_illegal;

    decoder u_dec (
        .instr(id_instr),
        .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2),
        .uses_rs1(d_uses_rs1), .uses_rs2(d_uses_rs2), .reg_write(d_reg_write),
        .imm(d_imm), .alu_op(d_alu_op), .src_a_pc(d_src_a_pc), .src_b_imm(d_src_b_imm),
        .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr), .funct3(d_funct3),
        .is_load(d_is_load), .is_store(d_is_store), .is_mul(d_is_mul), .is_div(d_is_div),
        .is_csr(d_is_csr), .csr_addr(d_csr_addr), .csr_use_imm(d_csr_use_imm),
        .is_ecall(d_is_ecall), .is_ebreak(d_is_ebreak), .is_mret(d_is_mret),
        .is_fence_i(d_is_fence_i), .illegal(d_illegal)
    );

    // regfile (written from WB)
    logic        wb_we;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;
    logic [31:0] rf_rdata1, rf_rdata2;

    regfile u_rf (
        .clk(clk),
        .we(wb_we), .waddr(wb_rd), .wdata(wb_data),
        .raddr1(d_rs1), .raddr2(d_rs2),
        .rdata1(rf_rdata1), .rdata2(rf_rdata2)
    );

    // =====================================================================
    // ID/EX
    // =====================================================================
    logic                ex_valid;
    logic [31:0]         ex_pc, ex_instr;
    logic [4:0]          ex_rd, ex_rs1, ex_rs2;
    logic                ex_reg_write;
    logic [31:0]         ex_imm, ex_rs1_val, ex_rs2_val;
    logic [3:0]          ex_alu_op;
    logic                ex_src_a_pc, ex_src_b_imm;
    logic                ex_is_branch, ex_is_jal, ex_is_jalr;
    logic [2:0]          ex_funct3;
    logic                ex_is_load, ex_is_store, ex_is_mul, ex_is_div;
    logic                ex_is_csr, ex_csr_use_imm;
    logic [11:0]         ex_csr_addr;
    logic                ex_is_ecall, ex_is_ebreak, ex_is_mret, ex_is_fence_i, ex_illegal;
    logic                ex_pred_taken;
    logic [31:0]         ex_pred_target;
    logic [GHR_BITS-1:0] ex_pred_idx;

    always_ff @(posedge clk) begin
        if (rst || redirect || (load_use && !stall_ex)) begin
            // flush, or insert the load-use bubble
            ex_valid <= 1'b0;
        end else if (!stall_ex) begin
            ex_valid       <= id_valid;
            ex_pc          <= id_pc;
            ex_instr       <= id_instr;
            ex_rd          <= d_rd;
            ex_rs1         <= d_uses_rs1 ? d_rs1 : 5'd0;
            ex_rs2         <= d_uses_rs2 ? d_rs2 : 5'd0;
            ex_reg_write   <= d_reg_write && (d_rd != 5'd0);
            ex_imm         <= d_imm;
            ex_rs1_val     <= rf_rdata1;
            ex_rs2_val     <= rf_rdata2;
            ex_alu_op      <= d_alu_op;
            ex_src_a_pc    <= d_src_a_pc;
            ex_src_b_imm   <= d_src_b_imm;
            ex_is_branch   <= d_is_branch;
            ex_is_jal      <= d_is_jal;
            ex_is_jalr     <= d_is_jalr;
            ex_funct3      <= d_funct3;
            ex_is_load     <= d_is_load;
            ex_is_store    <= d_is_store;
            ex_is_mul      <= d_is_mul;
            ex_is_div      <= d_is_div;
            ex_is_csr      <= d_is_csr;
            ex_csr_use_imm <= d_csr_use_imm;
            ex_csr_addr    <= d_csr_addr;
            ex_is_ecall    <= d_is_ecall;
            ex_is_ebreak   <= d_is_ebreak;
            ex_is_mret     <= d_is_mret;
            ex_is_fence_i  <= d_is_fence_i;
            ex_illegal     <= d_illegal;
            ex_pred_taken  <= id_pred_taken;
            ex_pred_target <= id_pred_target;
            ex_pred_idx    <= id_pred_idx;
        end
    end

    // load-use: the instr in ID wants a register that the load in EX hasn't
    // fetched yet -> hold IF/ID one cycle, push a bubble into EX
    assign load_use = ex_valid && ex_is_load && ex_reg_write && id_valid &&
                      ((d_uses_rs1 && d_rs1 == ex_rd) || (d_uses_rs2 && d_rs2 == ex_rd));

    // =====================================================================
    // EX
    // =====================================================================
    // forwarding
    logic        mem_valid, mem_reg_write, mem_is_load;
    logic [4:0]  mem_rd;
    logic [31:0] mem_result;
    logic [31:0] fwd_a, fwd_b;

    always_comb begin
        if (mem_valid && mem_reg_write && mem_rd == ex_rs1 && ex_rs1 != 5'd0) fwd_a = mem_result;
        else if (wb_we && wb_rd == ex_rs1 && ex_rs1 != 5'd0)                  fwd_a = wb_data;
        else                                                                  fwd_a = ex_rs1_val;

        if (mem_valid && mem_reg_write && mem_rd == ex_rs2 && ex_rs2 != 5'd0) fwd_b = mem_result;
        else if (wb_we && wb_rd == ex_rs2 && ex_rs2 != 5'd0)                  fwd_b = wb_data;
        else                                                                  fwd_b = ex_rs2_val;
    end

    // ALU
    logic [31:0] alu_a, alu_b, alu_y;
    assign alu_a = ex_src_a_pc  ? ex_pc  : fwd_a;
    assign alu_b = ex_src_b_imm ? ex_imm : fwd_b;
    alu u_alu (.op(ex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

    // M extension
    logic        div_start, div_busy, div_done;
    logic [31:0] mul_y, div_y;
    logic        trap_take;

    assign div_start = ex_valid && ex_is_div && !div_done && !trap_take;
    assign stall_ex  = ex_valid && ex_is_div && !div_done && !trap_take;

    muldiv u_md (
        .clk(clk), .rst(rst),
        .funct3(ex_funct3), .a(fwd_a), .b(fwd_b),
        .mul_result(mul_y),
        .div_start(div_start), .div_busy(div_busy), .div_done(div_done), .div_result(div_y)
    );

    // branch / jump resolution
    logic        br_eq, br_lt, br_ltu, br_cond;
    assign br_eq  = (fwd_a == fwd_b);
    assign br_lt  = ($signed(fwd_a) < $signed(fwd_b));
    assign br_ltu = (fwd_a < fwd_b);
    always_comb begin
        case (ex_funct3)
            3'b000:  br_cond = br_eq;
            3'b001:  br_cond = !br_eq;
            3'b100:  br_cond = br_lt;
            3'b101:  br_cond = !br_lt;
            3'b110:  br_cond = br_ltu;
            3'b111:  br_cond = !br_ltu;
            default: br_cond = 1'b0;
        endcase
    end

    logic        is_ctrl, ctrl_taken;
    logic [31:0] ctrl_target, pc_plus4, actual_next, predicted_next;
    assign pc_plus4    = ex_pc + 32'd4;
    assign is_ctrl     = ex_is_branch || ex_is_jal || ex_is_jalr;
    assign ctrl_taken  = ex_is_jal || ex_is_jalr || (ex_is_branch && br_cond);
    assign ctrl_target = ex_is_jalr ? ((fwd_a + ex_imm) & ~32'd1) : (ex_pc + ex_imm);
    assign actual_next    = ctrl_taken ? ctrl_target : pc_plus4;
    assign predicted_next = ex_pred_taken ? ex_pred_target : pc_plus4;

    // what kind of control flow is this (for the BTB / RAS)
    logic        rd_link, rs1_link;
    logic [1:0]  ctrl_type;
    assign rd_link  = (ex_rd  == 5'd1) || (ex_rd  == 5'd5);
    assign rs1_link = (ex_rs1 == 5'd1) || (ex_rs1 == 5'd5);
    always_comb begin
        if (ex_is_branch)                               ctrl_type = `BT_BRANCH;
        else if (rd_link && ex_reg_write)               ctrl_type = `BT_CALL;
        else if (ex_is_jalr && rs1_link && !ex_reg_write) ctrl_type = `BT_RET;
        else                                            ctrl_type = `BT_JUMP;
    end

    // memory address + alignment check
    logic [31:0] mem_addr_ex;
    logic        misaligned;
    assign mem_addr_ex = fwd_a + ex_imm;
    always_comb begin
        case (ex_funct3[1:0])
            2'b00:   misaligned = 1'b0;
            2'b01:   misaligned = mem_addr_ex[0];
            default: misaligned = mem_addr_ex[1:0] != 2'b00;
        endcase
    end

    // CSR
    logic [31:0] csr_rdata, csr_wdata, trap_vector, mepc;
    logic        csr_illegal, csr_do_write;
    logic        irq_pending;
    logic [31:0] irq_cause;
    logic [31:0] trap_cause, trap_val;
    logic        exc;
    logic        mret_take;
    logic        retire;

    // careful: ex_rs1 got zeroed for the imm forms, so grab zimm straight from the instr
    assign csr_wdata    = ex_csr_use_imm ? {27'b0, ex_instr[19:15]} : fwd_a;
    assign csr_do_write = (ex_funct3[1:0] == 2'b01) ||
                          (ex_csr_use_imm ? (ex_instr[19:15] != 5'd0) : (ex_rs1 != 5'd0));

    // exceptions, highest priority first
    always_comb begin
        exc        = 1'b1;
        trap_cause = `CAUSE_ILLEGAL_INSTR;
        trap_val   = 32'b0;
        if (irq_pending) begin
            trap_cause = irq_cause;
        end else if (ex_illegal || (ex_is_csr && csr_illegal)) begin
            trap_cause = `CAUSE_ILLEGAL_INSTR;
            trap_val   = ex_instr;
        end else if (ex_is_ecall) begin
            trap_cause = `CAUSE_ECALL_M;
        end else if (ex_is_ebreak) begin
            trap_cause = `CAUSE_BREAKPOINT;
            trap_val   = ex_pc;
        end else if (ex_is_load && misaligned) begin
            trap_cause = `CAUSE_MISALIGNED_LOAD;
            trap_val   = mem_addr_ex;
        end else if (ex_is_store && misaligned) begin
            trap_cause = `CAUSE_MISALIGNED_STORE;
            trap_val   = mem_addr_ex;
        end else if (ctrl_taken && ctrl_target[1]) begin
            trap_cause = `CAUSE_MISALIGNED_FETCH;
            trap_val   = ctrl_target;
        end else begin
            exc = 1'b0;
        end
    end

    // interrupts are held off while a divide is mid-flight so it can't be torn
    // (div_busy is a registered state bit, so no comb loop through div_start)
    assign trap_take = ex_valid && exc && !(irq_pending && div_busy);
    assign mret_take = ex_valid && ex_is_mret && !trap_take;
    assign retire    = ex_valid && !trap_take && !stall_ex;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_en(ex_valid && ex_is_csr && !trap_take),
        .csr_addr(ex_csr_addr), .csr_op(ex_funct3[1:0]), .csr_do_write(csr_do_write),
        .csr_wdata(csr_wdata), .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
        .trap_take(trap_take), .trap_cause(trap_cause), .trap_pc(ex_pc), .trap_val(trap_val),
        .mret_take(mret_take), .trap_vector(trap_vector), .mepc_o(mepc),
        .irq_timer(irq_timer), .irq_ext(irq_ext),
        .irq_pending(irq_pending), .irq_cause(irq_cause),
        .instr_retired(retire),
        .ev_mispredict(bpu_upd_valid && actual_next != predicted_next),
        .ev_ctrl_resolved(bpu_upd_valid),
        .ev_load_use(load_use && !stall_ex && !redirect),
        .ev_div_stall(stall_ex),
        .mtime(mtime)
    );

    // redirect: trap > mret > fence.i > wrong prediction
    always_comb begin
        redirect    = 1'b0;
        redirect_pc = actual_next;
        if (ex_valid && !stall_ex) begin
            if (trap_take) begin
                redirect    = 1'b1;
                redirect_pc = trap_vector;
            end else if (ex_is_mret) begin
                redirect    = 1'b1;
                redirect_pc = mepc;
            end else if (ex_is_fence_i) begin
                redirect    = 1'b1;
                redirect_pc = pc_plus4;
            end else if (actual_next != predicted_next) begin
                redirect    = 1'b1;
                redirect_pc = actual_next;
            end
        end
    end

    // train the predictor
    assign bpu_upd_valid     = retire && is_ctrl;
    assign bpu_upd_pc        = ex_pc;
    assign bpu_upd_is_branch = ex_is_branch;
    assign bpu_upd_taken     = ctrl_taken;
    assign bpu_upd_target    = ctrl_target;
    assign bpu_upd_type      = ctrl_type;
    assign bpu_upd_idx       = ex_pred_idx;
    assign bpu_upd_kill      = retire && !is_ctrl && ex_pred_taken;

    // EX result
    logic [31:0] ex_result;
    always_comb begin
        if (ex_is_jal || ex_is_jalr) ex_result = pc_plus4;
        else if (ex_is_csr)          ex_result = csr_rdata;
        else if (ex_is_mul)          ex_result = mul_y;
        else if (ex_is_div)          ex_result = div_y;
        else                         ex_result = alu_y;
    end

    // store data lined up with the byte lanes
    logic [31:0] st_data;
    logic [3:0]  st_strb;
    always_comb begin
        case (ex_funct3[1:0])
            2'b00: begin
                st_data = {4{fwd_b[7:0]}};
                st_strb = 4'b0001 << mem_addr_ex[1:0];
            end
            2'b01: begin
                st_data = {2{fwd_b[15:0]}};
                st_strb = mem_addr_ex[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                st_data = fwd_b;
                st_strb = 4'b1111;
            end
        endcase
    end

    // =====================================================================
    // EX/MEM
    // =====================================================================
    logic        mem_is_store;
    logic [31:0] mem_addr, mem_wdata, mem_pc, mem_instr;
    logic [3:0]  mem_strb;
    logic [2:0]  mem_funct3;

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_valid <= 1'b0;
        end else begin
            mem_valid     <= retire;
            mem_pc        <= ex_pc;
            mem_instr     <= ex_instr;
            mem_rd        <= ex_rd;
            mem_reg_write <= ex_reg_write;
            mem_is_load   <= ex_is_load;
            mem_is_store  <= ex_is_store;
            mem_result    <= ex_result;
            mem_addr      <= mem_addr_ex;
            mem_wdata     <= st_data;
            mem_strb      <= st_strb;
            mem_funct3    <= ex_funct3;
        end
    end

    // =====================================================================
    // MEM
    // =====================================================================
    assign dmem_re    = mem_valid && mem_is_load;
    assign dmem_we    = mem_valid && mem_is_store;
    assign dmem_wstrb = mem_strb;
    assign dmem_addr  = mem_addr;
    assign dmem_wdata = mem_wdata;

    // =====================================================================
    // MEM/WB
    // =====================================================================
    logic        wbs_valid, wbs_reg_write, wbs_is_load;
    logic [4:0]  wbs_rd;
    logic [31:0] wbs_result, wbs_pc, wbs_instr;
    logic [1:0]  wbs_off;
    logic [2:0]  wbs_funct3;

    always_ff @(posedge clk) begin
        if (rst) begin
            wbs_valid <= 1'b0;
        end else begin
            wbs_valid     <= mem_valid;
            wbs_reg_write <= mem_reg_write;
            wbs_is_load   <= mem_is_load;
            wbs_rd        <= mem_rd;
            wbs_result    <= mem_result;
            wbs_off       <= mem_addr[1:0];
            wbs_funct3    <= mem_funct3;
            wbs_pc        <= mem_pc;
            wbs_instr     <= mem_instr;
        end
    end

    // =====================================================================
    // WB
    // =====================================================================
    logic [31:0] ld_shifted, ld_data;
    assign ld_shifted = dmem_rdata >> {wbs_off, 3'b000};
    always_comb begin
        case (wbs_funct3)
            3'b000:  ld_data = {{24{ld_shifted[7]}},  ld_shifted[7:0]};
            3'b001:  ld_data = {{16{ld_shifted[15]}}, ld_shifted[15:0]};
            3'b100:  ld_data = {24'b0, ld_shifted[7:0]};
            3'b101:  ld_data = {16'b0, ld_shifted[15:0]};
            default: ld_data = dmem_rdata;
        endcase
    end

    assign wb_we   = wbs_valid && wbs_reg_write;
    assign wb_rd   = wbs_rd;
    assign wb_data = wbs_is_load ? ld_data : wbs_result;

    assign trace_valid = wbs_valid;
    assign trace_pc    = wbs_pc;
    assign trace_instr = wbs_instr;
    assign trace_we    = wb_we;
    assign trace_rd    = wbs_rd;
    assign trace_wdata = wb_data;
endmodule
