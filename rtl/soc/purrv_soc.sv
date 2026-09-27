// purrv_soc.sv - core + RAM + bootloader + peripherals, all glued together
//
// memory map (also in sw/common/purrv.h):
//   0x0000_0000  RAM        16 KiB (code + data + stack)
//   0x1000_0000  UART
//   0x1000_1000  GPIO       LEDs + buttons
//   0x1000_2000  TIMER      mtime / mtimecmp (1 µs tick)
//   0x1000_3000  LCD1602
//   0x1000_4000  SONAR      HC-SR04
//   0x1000_5000  BUZZER
//   0x1000_6000  SEVENSEG
//   0x1000_7000  IRQ        external interrupt pending / enable

module purrv_soc #(
    parameter int    CLK_HZ       = 27_000_000,
    parameter int    BAUD         = 115_200,
    parameter int    RAM_WORDS    = 4096,        // 16 KiB (fits the GW1NR-9's block RAM)
    parameter        INIT_FILE    = "",
    parameter int    LCD_INIT_US  = 50_000,
    parameter int    N_LED        = 8,
    parameter int    N_BTN        = 4
) (
    input  logic             clk,
    input  logic             rst,

    input  logic             uart_rx,
    output logic             uart_tx,

    output logic [N_LED-1:0] leds,
    input  logic [N_BTN-1:0] buttons,     // 1 = pressed

    output logic             lcd_rs,
    output logic             lcd_e,
    output logic [3:0]       lcd_d,

    output logic             sonar_trig,
    input  logic             sonar_echo,

    output logic             buzz,

    output logic [7:0]       seg,
    output logic [3:0]       dig
);
    localparam int AW = $clog2(RAM_WORDS);

    // ---------------- core ----------------
    logic        cpu_rst, bl_hold;
    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_re, dmem_we;
    logic [3:0]  dmem_wstrb;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        irq_timer, irq_ext;
    logic [63:0] mtime;

    assign cpu_rst = rst || bl_hold;

    purrv_core u_core (
        .clk(clk), .rst(cpu_rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_re(dmem_re), .dmem_we(dmem_we), .dmem_wstrb(dmem_wstrb),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .irq_timer(irq_timer), .irq_ext(irq_ext), .mtime(mtime),
        .trace_valid(), .trace_pc(), .trace_instr(), .trace_we(), .trace_rd(), .trace_wdata()
    );

    // ---------------- address decode (MEM stage) ----------------
    logic        is_ram, is_io;
    logic [3:0]  dev;
    assign is_ram = (dmem_addr[31:28] == 4'h0);
    assign is_io  = (dmem_addr[31:28] == 4'h1);
    assign dev    = dmem_addr[15:12];

    logic [15:0] io_sel;
    always_comb begin
        io_sel = 16'b0;
        if (is_io) io_sel[dev] = 1'b1;
    end

    // ---------------- RAM + bootloader ----------------
    logic [AW-1:0] bl_addr;
    logic [3:0]    bl_we;
    logic [31:0]   bl_wdata, ram_rdata;
    logic          bl_tx_valid, tx_ready, rx_strobe;
    logic [7:0]    bl_tx_byte, rx_byte;

    ram #(.WORDS(RAM_WORDS), .INIT_FILE(INIT_FILE)) u_ram (
        .clk(clk),
        .a_addr(imem_addr[AW+1:2]), .a_rdata(imem_rdata),
        .b_addr (bl_hold ? bl_addr  : dmem_addr[AW+1:2]),
        .b_we   (bl_hold ? bl_we    : ((dmem_we && is_ram) ? dmem_wstrb : 4'b0000)),
        .b_wdata(bl_hold ? bl_wdata : dmem_wdata),
        .b_rdata(ram_rdata)
    );

    bootloader #(.CLK_HZ(CLK_HZ), .ADDR_BITS(AW)) u_bl (
        .clk(clk), .rst(rst),
        .rx_strobe(rx_strobe), .rx_byte(rx_byte),
        .tx_ready(tx_ready), .tx_valid(bl_tx_valid), .tx_byte(bl_tx_byte),
        .hold_cpu(bl_hold), .mem_addr(bl_addr), .mem_we(bl_we), .mem_wdata(bl_wdata)
    );

    // ---------------- peripherals ----------------
    logic [31:0] rd_uart, rd_gpio, rd_timer, rd_lcd, rd_sonar, rd_buzz, rd_seg, rd_irq;
    logic        us_tick, irq_rx, irq_btn, irq_sonar;
    logic [3:0]  a4;
    assign a4 = dmem_addr[3:0];

    uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst),
        .sel(io_sel[0]), .we(dmem_we), .re(dmem_re), .addr(a4), .wdata(dmem_wdata), .rdata(rd_uart),
        .rx(uart_rx), .tx(uart_tx),
        .bl_tx_valid(bl_tx_valid), .bl_tx_byte(bl_tx_byte),
        .tx_ready(tx_ready), .rx_strobe(rx_strobe), .rx_byte(rx_byte),
        .irq_rx(irq_rx)
    );

    gpio #(.N_LED(N_LED), .N_BTN(N_BTN)) u_gpio (
        .clk(clk), .rst(cpu_rst), .us_tick(us_tick),
        .sel(io_sel[1]), .we(dmem_we), .addr(a4), .wdata(dmem_wdata), .rdata(rd_gpio),
        .leds(leds), .buttons_raw(buttons), .irq_btn(irq_btn)
    );

    timer #(.CLK_HZ(CLK_HZ)) u_timer (
        .clk(clk), .rst(cpu_rst),
        .sel(io_sel[2]), .we(dmem_we), .addr(a4), .wdata(dmem_wdata), .rdata(rd_timer),
        .mtime(mtime), .us_tick(us_tick), .irq_timer(irq_timer)
    );

    lcd1602 #(.INIT_US(LCD_INIT_US)) u_lcd (
        .clk(clk), .rst(rst), .us_tick(us_tick),
        .sel(io_sel[3]), .we(dmem_we), .addr(a4), .wdata(dmem_wdata), .rdata(rd_lcd),
        .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_d(lcd_d)
    );

    sonar u_sonar (
        .clk(clk), .rst(cpu_rst), .us_tick(us_tick),
        .sel(io_sel[4]), .we(dmem_we), .re(dmem_re), .addr(a4), .wdata(dmem_wdata), .rdata(rd_sonar),
        .trig(sonar_trig), .echo(sonar_echo), .irq_done(irq_sonar)
    );

    buzzer u_buzz (
        .clk(clk), .rst(cpu_rst), .us_tick(us_tick),
        .sel(io_sel[5]), .we(dmem_we), .addr(a4), .wdata(dmem_wdata), .rdata(rd_buzz),
        .buzz(buzz)
    );

    sevenseg u_seg (
        .clk(clk), .rst(cpu_rst), .us_tick(us_tick),
        .sel(io_sel[6]), .we(dmem_we), .addr(a4), .wdata(dmem_wdata), .rdata(rd_seg),
        .seg(seg), .dig(dig)
    );

    // tiny interrupt controller: bit0 uart rx, bit1 button, bit2 sonar
    logic [2:0] irq_raw, irq_en;
    assign irq_raw = {irq_sonar, irq_btn, irq_rx};
    always_ff @(posedge clk) begin
        if (cpu_rst)                                  irq_en <= 3'b0;
        else if (io_sel[7] && dmem_we && a4[3:2] == 2'd1) irq_en <= dmem_wdata[2:0];
        rd_irq <= a4[2] ? {29'b0, irq_en} : {29'b0, irq_raw};
    end
    assign irq_ext = |(irq_raw & irq_en);

    // ---------------- read data mux (WB) ----------------
    logic       rsel_ram;
    logic [3:0] rsel_dev;
    always_ff @(posedge clk) begin
        rsel_ram <= is_ram;
        rsel_dev <= dev;
    end

    always_comb begin
        if (rsel_ram) dmem_rdata = ram_rdata;
        else begin
            case (rsel_dev)
                4'd0:    dmem_rdata = rd_uart;
                4'd1:    dmem_rdata = rd_gpio;
                4'd2:    dmem_rdata = rd_timer;
                4'd3:    dmem_rdata = rd_lcd;
                4'd4:    dmem_rdata = rd_sonar;
                4'd5:    dmem_rdata = rd_buzz;
                4'd6:    dmem_rdata = rd_seg;
                4'd7:    dmem_rdata = rd_irq;
                default: dmem_rdata = 32'b0;
            endcase
        end
    end
endmodule
