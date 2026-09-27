// sevenseg.sv - drives the kit's 4-digit 7-segment display (5461AS, common
// cathode) by multiplexing one digit at a time, ~1 ms each so it looks solid
//
//   +0x0 HEX   write a 16-bit value, shown as 4 hex digits (hardware decodes)
//   +0x4 RAW   write 4 raw segment bytes, byte0 = rightmost digit
//              bit order in a byte: dp g f e d c b a
//   +0x8 DP    bit n = decimal point on digit n (HEX mode)
// whichever of HEX/RAW you wrote last is what gets shown
//
// segment pins go through 220 ohm resistors (from the kit). digit pins sink
// the whole digit's current, so drive them through the kit's NPN transistors
// if you want it bright - directly off the FPGA is fine but dimmer

module sevenseg #(
    parameter bit ACTIVE_LOW_DIGITS = 1'b1   // common cathode: pull digit low to light it
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        us_tick,
    input  logic        sel,
    input  logic        we,
    input  logic [3:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    output logic [7:0]  seg,      // dp g f e d c b a, active high
    output logic [3:0]  dig
);
    logic [15:0] hex_val;
    logic [31:0] raw_val;
    logic [3:0]  dp;
    logic        raw_mode;
    logic [9:0]  t;
    logic [1:0]  cur;

    always_ff @(posedge clk) begin
        if (rst) begin
            hex_val  <= 16'h0000;
            raw_val  <= 32'h0;
            dp       <= 4'h0;
            raw_mode <= 1'b1;        // blank until software writes something
            t        <= 10'd0;
            cur      <= 2'd0;
        end else begin
            if (sel && we) begin
                case (addr[3:2])
                    2'd0: begin hex_val <= wdata[15:0]; raw_mode <= 1'b0; end
                    2'd1: begin raw_val <= wdata;       raw_mode <= 1'b1; end
                    2'd2: dp <= wdata[3:0];
                    default: ;
                endcase
            end
            if (us_tick) begin
                if (t == 10'd999) begin
                    t   <= 10'd0;
                    cur <= cur + 2'd1;
                end else begin
                    t <= t + 10'd1;
                end
            end
        end
    end

    function automatic logic [6:0] hex7(input logic [3:0] h);
        case (h)                       //   gfedcba
            4'h0: hex7 = 7'b0111111;
            4'h1: hex7 = 7'b0000110;
            4'h2: hex7 = 7'b1011011;
            4'h3: hex7 = 7'b1001111;
            4'h4: hex7 = 7'b1100110;
            4'h5: hex7 = 7'b1101101;
            4'h6: hex7 = 7'b1111101;
            4'h7: hex7 = 7'b0000111;
            4'h8: hex7 = 7'b1111111;
            4'h9: hex7 = 7'b1101111;
            4'hA: hex7 = 7'b1110111;
            4'hB: hex7 = 7'b1111100;
            4'hC: hex7 = 7'b0111001;
            4'hD: hex7 = 7'b1011110;
            4'hE: hex7 = 7'b1111001;
            default: hex7 = 7'b1110001;   // F
        endcase
    endfunction

    logic [3:0] nib;
    logic [7:0] rawb;
    assign nib  = hex_val >> {cur, 2'b00};
    assign rawb = raw_val >> {cur, 3'b000};

    always_ff @(posedge clk) begin
        seg <= raw_mode ? rawb : {dp[cur], hex7(nib)};
        dig <= ACTIVE_LOW_DIGITS ? ~(4'b0001 << cur) : (4'b0001 << cur);
    end

    always_ff @(posedge clk) begin
        case (addr[3:2])
            2'd0:    rdata <= {16'b0, hex_val};
            2'd1:    rdata <= raw_val;
            2'd2:    rdata <= {28'b0, dp};
            default: rdata <= 32'b0;
        endcase
    end
endmodule
