// ram.sv - true dual-port block RAM, 32-bit words, byte writes on port B
//   port A: instruction fetch (read only)
//   port B: data loads/stores + the UART bootloader
// both ports see the same memory ("modified Harvard"), so .rodata and
// .data live right next to the code and loads can read them :3

module ram #(
    parameter int    WORDS     = 4096,          // 16 KiB
    parameter        INIT_FILE = ""
) (
    input  logic                      clk,

    input  logic [$clog2(WORDS)-1:0]  a_addr,
    output logic [31:0]               a_rdata,

    input  logic [$clog2(WORDS)-1:0]  b_addr,
    input  logic [3:0]                b_we,
    input  logic [31:0]               b_wdata,
    output logic [31:0]               b_rdata
);
    logic [31:0] mem [0:WORDS-1];

    initial begin
`ifdef SIM
        // testbench can pick the program at runtime: +hex=build/foo.hex
        string f;
        if ($value$plusargs("hex=%s", f)) $readmemh(f, mem);
        else if (INIT_FILE != "")          $readmemh(INIT_FILE, mem);
`else
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
`endif
    end

    always_ff @(posedge clk) a_rdata <= mem[a_addr];

    always_ff @(posedge clk) begin
        if (b_we[0]) mem[b_addr][7:0]   <= b_wdata[7:0];
        if (b_we[1]) mem[b_addr][15:8]  <= b_wdata[15:8];
        if (b_we[2]) mem[b_addr][23:16] <= b_wdata[23:16];
        if (b_we[3]) mem[b_addr][31:24] <= b_wdata[31:24];
        b_rdata <= mem[b_addr];
    end
endmodule
