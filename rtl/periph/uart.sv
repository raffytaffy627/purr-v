// uart.sv - 8N1 UART with a small RX FIFO, memory mapped
//   +0x0 DATA    write: send a byte    read: pop a received byte
//   +0x4 STATUS  bit0 = tx ready, bit1 = rx has data
//
// rx_byte/rx_strobe are also brought out so the bootloader can snoop the
// incoming stream for the flash magic word :p

module uart #(
    parameter int CLK_HZ = 27_000_000,
    parameter int BAUD   = 115_200
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        sel,
    input  logic        we,
    input  logic        re,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    input  logic        rx,
    output logic        tx,

    // bootloader side door
    input  logic        bl_tx_valid,
    input  logic [7:0]  bl_tx_byte,
    output logic        tx_ready,
    output logic        rx_strobe,
    output logic [7:0]  rx_byte,

    output logic        irq_rx
);
    localparam int DIV = CLK_HZ / BAUD;

    // ---------------- TX ----------------
    logic [9:0]  tx_shift;
    logic [3:0]  tx_bits;
    logic [15:0] tx_cnt;
    logic        tx_go;
    logic [7:0]  tx_data;

    assign tx_ready = (tx_bits == 4'd0);
    assign tx_go    = tx_ready && (bl_tx_valid || (sel && we && addr[3:2] == 2'd0));
    assign tx_data  = bl_tx_valid ? bl_tx_byte : wdata[7:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_shift <= 10'h3FF;
            tx_bits  <= 4'd0;
            tx_cnt   <= 16'd0;
        end else if (tx_go) begin
            tx_shift <= {1'b1, tx_data, 1'b0};    // stop, data (lsb first), start
            tx_bits  <= 4'd10;
            tx_cnt   <= 16'd0;
        end else if (tx_bits != 4'd0) begin
            if (tx_cnt == DIV - 1) begin
                tx_cnt   <= 16'd0;
                tx_shift <= {1'b1, tx_shift[9:1]};
                tx_bits  <= tx_bits - 4'd1;
            end else begin
                tx_cnt <= tx_cnt + 16'd1;
            end
        end
    end
    assign tx = (tx_bits == 4'd0) ? 1'b1 : tx_shift[0];

    // ---------------- RX ----------------
    logic [2:0]  rx_sync;
    logic        rx_s;
    logic [15:0] rx_cnt;
    logic [3:0]  rx_bits;
    logic [7:0]  rx_shift;
    logic        rx_busy;

    always_ff @(posedge clk) rx_sync <= {rx_sync[1:0], rx};
    assign rx_s = rx_sync[2];

    always_ff @(posedge clk) begin
        rx_strobe <= 1'b0;
        if (rst) begin
            rx_busy <= 1'b0;
        end else if (!rx_busy) begin
            if (!rx_s) begin                        // start bit edge
                rx_busy <= 1'b1;
                rx_cnt  <= 16'(DIV / 2);            // sample mid-bit
                rx_bits <= 4'd0;
            end
        end else if (rx_cnt == 16'd0) begin
            rx_cnt <= 16'(DIV - 1);
            if (rx_bits == 4'd0) begin
                if (rx_s) rx_busy <= 1'b0;          // glitch, not a real start bit
                rx_bits <= 4'd1;
            end else if (rx_bits <= 4'd8) begin
                rx_shift <= {rx_s, rx_shift[7:1]};
                rx_bits  <= rx_bits + 4'd1;
            end else begin
                rx_busy <= 1'b0;                    // stop bit
                if (rx_s) begin
                    rx_strobe <= 1'b1;
                    rx_byte   <= rx_shift;
                end
            end
        end else begin
            rx_cnt <= rx_cnt - 16'd1;
        end
    end

    // 16-byte RX FIFO
    logic [7:0] fifo [0:15];
    logic [4:0] wp, rp;
    logic       empty, full, pop;
    assign empty = (wp == rp);
    assign full  = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);
    assign pop   = sel && re && addr[3:2] == 2'd0 && !empty;

    always_ff @(posedge clk) begin
        if (rst) begin
            wp <= 5'd0;
            rp <= 5'd0;
        end else begin
            if (rx_strobe && !full) begin
                fifo[wp[3:0]] <= rx_byte;
                wp <= wp + 5'd1;
            end
            if (pop) rp <= rp + 5'd1;
        end
    end

    // registered read (data shows up in WB like block RAM does)
    always_ff @(posedge clk) begin
        case (addr[3:2])
            2'd0:    rdata <= empty ? 32'hFFFF_FFFF : {24'b0, fifo[rp[3:0]]};
            2'd1:    rdata <= {30'b0, !empty, tx_ready};
            default: rdata <= 32'b0;
        endcase
    end

    assign irq_rx = !empty;
endmodule
