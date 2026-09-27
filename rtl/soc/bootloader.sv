// bootloader.sv - load new programs over UART without re-synthesizing :3
//
// it just listens to every byte coming in. when it sees the magic word it
// holds the CPU in reset, writes the program into RAM from address 0, checks
// it, and lets the CPU go again. so you can re-flash any time, no button.
//
//   host sends:  "PURR"  len[31:0] little-endian  <len bytes>  checksum[7:0]
//   we reply:    'K' = good, CPU restarted
//                'E' = checksum mismatch, CPU stays in reset
//                'T' = host went quiet mid-transfer, CPU stays in reset
// (tools/flash.py does all of this for you)

module bootloader #(
    parameter int CLK_HZ     = 27_000_000,
    parameter int ADDR_BITS  = 13            // word address width of RAM
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic                 rx_strobe,
    input  logic [7:0]           rx_byte,
    input  logic                 tx_ready,
    output logic                 tx_valid,
    output logic [7:0]           tx_byte,

    output logic                 hold_cpu,    // keep the core in reset
    output logic [ADDR_BITS-1:0] mem_addr,
    output logic [3:0]           mem_we,
    output logic [31:0]          mem_wdata
);
    localparam logic [31:0] MAGIC = {"R", "R", "U", "P"};   // "PURR" arriving lsb first
    localparam int TIMEOUT = CLK_HZ;                          // 1 s of silence = give up

    typedef enum logic [2:0] { S_HUNT, S_LEN, S_DATA, S_SUM, S_REPLY } state_t;
    state_t state;

    logic [31:0] last4;
    logic [31:0] len;
    logic [15:0] count;          // 16 KiB of RAM max, 16 bits is plenty
    logic [1:0]  len_i;
    logic [7:0]  sum;
    logic [31:0] word;
    logic [24:0] idle;           // 2^25 clocks > 1 s at 27 MHz
    logic        failed;
    logic [7:0]  reply;

    always_ff @(posedge clk) begin
        mem_we   <= 4'b0000;
        tx_valid <= 1'b0;
        if (rst) begin
            state    <= S_HUNT;
            last4    <= 32'b0;
            hold_cpu <= 1'b0;
            failed   <= 1'b0;
        end else begin
            if (rx_strobe) begin
                last4 <= {rx_byte, last4[31:8]};
                idle  <= '0;
            end else if (state != S_HUNT && state != S_REPLY) begin
                idle <= idle + 1'b1;
            end

            case (state)
                S_HUNT: if (rx_strobe && {rx_byte, last4[31:8]} == MAGIC) begin
                    hold_cpu <= 1'b1;
                    len_i    <= 2'd0;
                    len      <= 32'd0;
                    idle     <= '0;
                    state    <= S_LEN;
                end
                S_LEN: if (rx_strobe) begin
                    len   <= {rx_byte, len[31:8]};
                    len_i <= len_i + 2'd1;
                    if (len_i == 2'd3) begin
                        count <= 16'd0;
                        sum   <= 8'd0;
                        state <= ({rx_byte, len[31:8]} == 32'd0) ? S_SUM : S_DATA;
                    end
                end
                S_DATA: if (rx_strobe) begin
                    word  <= {rx_byte, word[31:8]};
                    sum   <= sum + rx_byte;
                    count <= count + 16'd1;
                    // write a word every 4 bytes, and flush a partial last word
                    if (count[1:0] == 2'd3 || count + 16'd1 == len[15:0]) begin
                        mem_addr  <= count[ADDR_BITS+1:2];
                        mem_wdata <= {rx_byte, word[31:8]} >> {~count[1:0], 3'b000};
                        mem_we    <= 4'b1111 >> ~count[1:0];
                    end
                    if (count + 16'd1 == len[15:0]) state <= S_SUM;
                end
                S_SUM: if (rx_strobe) begin
                    failed <= (rx_byte != sum);
                    reply  <= (rx_byte == sum) ? "K" : "E";
                    state  <= S_REPLY;
                end
                S_REPLY: if (tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_byte  <= reply;
                    hold_cpu <= failed;
                    last4    <= 32'b0;
                    state    <= S_HUNT;
                end
                default: state <= S_HUNT;
            endcase

            if ((state == S_LEN || state == S_DATA || state == S_SUM) && idle >= 25'(TIMEOUT)) begin
                failed <= 1'b1;
                reply  <= "T";
                state  <= S_REPLY;
            end
        end
    end
endmodule
