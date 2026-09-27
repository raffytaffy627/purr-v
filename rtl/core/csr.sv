// csr.sv - machine-mode CSRs, traps, interrupts, and perf counters
//
// everything trap-related is decided in EX: anything older (in MEM/WB) is
// guaranteed to finish and anything younger gets flushed, so traps are precise
// without needing a separate commit stage :3

`include "purrv_defs.svh"

module csr (
    input  logic        clk,
    input  logic        rst,

    // CSR instruction in EX
    input  logic        csr_en,        // valid CSR instr executing this cycle
    input  logic [11:0] csr_addr,
    input  logic [1:0]  csr_op,        // funct3[1:0]: 01 RW, 10 RS, 11 RC
    input  logic        csr_do_write,  // RS/RC with rs1/zimm == 0 don't write
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,
    output logic        csr_illegal,

    // trap / return
    input  logic        trap_take,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_val,
    input  logic        mret_take,
    output logic [31:0] trap_vector,   // where to jump for trap_cause
    output logic [31:0] mepc_o,

    // interrupts
    input  logic        irq_timer,
    input  logic        irq_ext,
    output logic        irq_pending,   // something is enabled + pending + MIE
    output logic [31:0] irq_cause,

    // counters
    input  logic        instr_retired,
    input  logic        ev_mispredict,
    input  logic        ev_ctrl_resolved,
    input  logic        ev_load_use,
    input  logic        ev_div_stall,
    input  logic [63:0] mtime
);
    logic        mstatus_mie, mstatus_mpie;
    logic        mie_mtie, mie_meie, mie_msie;
    logic [31:0] mtvec, mscratch, mepc, mcause, mtval;
    logic [63:0] mcycle, minstret;
    logic [31:0] hpm3, hpm4, hpm5, hpm6;

    logic [31:0] mstatus_v, mie_v, mip_v;
    assign mstatus_v = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
    assign mie_v     = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
    assign mip_v     = {20'b0, irq_ext, 3'b0, irq_timer, 7'b0};

    // ---------------- read ----------------
    always_comb begin
        csr_illegal = 1'b0;
        case (csr_addr)
            `CSR_MSTATUS:   csr_rdata = mstatus_v;
            `CSR_MISA:      csr_rdata = 32'h4000_1100;          // RV32 + I + M
            `CSR_MIE:       csr_rdata = mie_v;
            `CSR_MTVEC:     csr_rdata = mtvec;
            `CSR_MSCRATCH:  csr_rdata = mscratch;
            `CSR_MEPC:      csr_rdata = mepc;
            `CSR_MCAUSE:    csr_rdata = mcause;
            `CSR_MTVAL:     csr_rdata = mtval;
            `CSR_MIP:       csr_rdata = mip_v;
            `CSR_MCYCLE,
            `CSR_CYCLE:     csr_rdata = mcycle[31:0];
            `CSR_MCYCLEH,
            `CSR_CYCLEH:    csr_rdata = mcycle[63:32];
            `CSR_MINSTRET,
            `CSR_INSTRET:   csr_rdata = minstret[31:0];
            `CSR_MINSTRETH,
            `CSR_INSTRETH:  csr_rdata = minstret[63:32];
            `CSR_TIME:      csr_rdata = mtime[31:0];
            `CSR_TIMEH:     csr_rdata = mtime[63:32];
            `CSR_MHPM3:     csr_rdata = hpm3;
            `CSR_MHPM4:     csr_rdata = hpm4;
            `CSR_MHPM5:     csr_rdata = hpm5;
            `CSR_MHPM6:     csr_rdata = hpm6;
            `CSR_MVENDORID,
            `CSR_MARCHID,
            `CSR_MIMPID,
            `CSR_MHARTID:   csr_rdata = 32'b0;
            default: begin
                csr_rdata   = 32'b0;
                csr_illegal = 1'b1;
            end
        endcase
        // read-only CSRs (addr[11:10] == 11) can't be written
        if (csr_do_write && csr_addr[11:10] == 2'b11) csr_illegal = 1'b1;
    end

    logic [31:0] new_val;
    always_comb begin
        case (csr_op)
            2'b01:   new_val = csr_wdata;
            2'b10:   new_val = csr_rdata | csr_wdata;
            2'b11:   new_val = csr_rdata & ~csr_wdata;
            default: new_val = csr_rdata;
        endcase
    end

    // ---------------- interrupts ----------------
    always_comb begin
        irq_pending = 1'b0;
        irq_cause   = `CAUSE_IRQ_EXT;
        if (mstatus_mie) begin
            // priority: external > timer
            if (irq_ext && mie_meie) begin
                irq_pending = 1'b1;
                irq_cause   = `CAUSE_IRQ_EXT;
            end else if (irq_timer && mie_mtie) begin
                irq_pending = 1'b1;
                irq_cause   = `CAUSE_IRQ_TIMER;
            end
        end
    end

    // mtvec mode 1 = vectored: interrupts jump to base + 4*cause
    assign trap_vector = (mtvec[0] && trap_cause[31]) ? {mtvec[31:2], 2'b00} + {trap_cause[29:0], 2'b00}
                                                      : {mtvec[31:2], 2'b00};
    assign mepc_o = mepc;

    // ---------------- write ----------------
    logic wr;
    assign wr = csr_en && csr_do_write && !csr_illegal;

    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mie_msie     <= 1'b0;
            mtvec        <= 32'b0;
            mscratch     <= 32'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
            mtval        <= 32'b0;
            mcycle       <= 64'b0;
            minstret     <= 64'b0;
            hpm3 <= 32'b0; hpm4 <= 32'b0; hpm5 <= 32'b0; hpm6 <= 32'b0;
        end else begin
            mcycle <= mcycle + 64'd1;
            if (instr_retired)    minstret <= minstret + 64'd1;
            if (ev_mispredict)    hpm3 <= hpm3 + 32'd1;
            if (ev_ctrl_resolved) hpm4 <= hpm4 + 32'd1;
            if (ev_load_use)      hpm5 <= hpm5 + 32'd1;
            if (ev_div_stall)     hpm6 <= hpm6 + 32'd1;

            if (trap_take) begin
                mepc         <= trap_pc;
                mcause       <= trap_cause;
                mtval        <= trap_val;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret_take) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (wr) begin
                case (csr_addr)
                    `CSR_MSTATUS: begin
                        mstatus_mie  <= new_val[3];
                        mstatus_mpie <= new_val[7];
                    end
                    `CSR_MIE: begin
                        mie_msie <= new_val[3];
                        mie_mtie <= new_val[7];
                        mie_meie <= new_val[11];
                    end
                    `CSR_MTVEC:     mtvec    <= {new_val[31:2], 1'b0, new_val[0]};
                    `CSR_MSCRATCH:  mscratch <= new_val;
                    `CSR_MEPC:      mepc     <= {new_val[31:2], 2'b00};
                    `CSR_MCAUSE:    mcause   <= new_val;
                    `CSR_MTVAL:     mtval    <= new_val;
                    `CSR_MCYCLE:    mcycle[31:0]    <= new_val;
                    `CSR_MCYCLEH:   mcycle[63:32]   <= new_val;
                    `CSR_MINSTRET:  minstret[31:0]  <= new_val;
                    `CSR_MINSTRETH: minstret[63:32] <= new_val;
                    `CSR_MHPM3:     hpm3 <= new_val;
                    `CSR_MHPM4:     hpm4 <= new_val;
                    `CSR_MHPM5:     hpm5 <= new_val;
                    `CSR_MHPM6:     hpm6 <= new_val;
                    default: ;
                endcase
            end
        end
    end
endmodule
