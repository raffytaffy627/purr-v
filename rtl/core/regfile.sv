// regfile.sv - 32 x 32-bit registers, 2 read ports, 1 write port
// x0 is hardwired to zero. reads are "write-first": if WB is writing the same
// register this cycle, ID sees the new value right away (saves a forward path)

module regfile (
    input  logic        clk,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2
);
    logic [31:0] regs [0:31];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'b0;

    always_ff @(posedge clk)
        if (we && waddr != 5'd0) regs[waddr] <= wdata;

    always_comb begin
        if (raddr1 == 5'd0)                  rdata1 = 32'b0;
        else if (we && waddr == raddr1)      rdata1 = wdata;
        else                                 rdata1 = regs[raddr1];

        if (raddr2 == 5'd0)                  rdata2 = 32'b0;
        else if (we && waddr == raddr2)      rdata2 = wdata;
        else                                 rdata2 = regs[raddr2];
    end
endmodule
