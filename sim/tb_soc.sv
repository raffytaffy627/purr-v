// tb_soc.sv - runs a program on the whole SoC in Icarus Verilog
//
// plusargs:
//   +hex=build/foo.hex   program to load into RAM
//   +trace               print every retired instruction (for diffing vs the ISS)
//   +max_cycles=N        give up after N cycles (default 5M)
//   +sonar_cm=N          pretend something is N cm in front of the HC-SR04
//   +btn_at=N            "press" button 0 at cycle N (for 10 ms)
//   +quiet               don't echo UART output
//   +load=build/foo.bin  after boot, send foo.bin through the UART bootloader
//                        (exactly what tools/flash.py does on the real board)
//
// the program ends the sim by writing its exit code to 0x1000_F000
// (0 = pass). UART output is decoded straight off the tx pin and the LCD
// model prints the 16x2 screen whenever it changes :3

`timescale 1ns/1ps

module tb_soc;
    localparam int CLK_HZ = 8_000_000;
    localparam int BAUD   = 1_000_000;
    localparam int BIT_T  = CLK_HZ / BAUD;       // clocks per UART bit

    logic clk = 0, rst = 1;
    always #62.5 clk = ~clk;                      // 8 MHz

    logic       uart_tx, uart_rx = 1'b1;
    logic [7:0] leds;
    logic [3:0] buttons = 4'b0;
    logic       lcd_rs, lcd_e;
    logic [3:0] lcd_d;
    logic       trig, echo = 1'b0, buzz;
    logic [7:0] seg;
    logic [3:0] dig;

    purrv_soc #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .LCD_INIT_US(200)
    ) dut (
        .clk(clk), .rst(rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .leds(leds), .buttons(buttons),
        .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_d(lcd_d),
        .sonar_trig(trig), .sonar_echo(echo),
        .buzz(buzz), .seg(seg), .dig(dig)
    );

    // ---------------- run control ----------------
    longint cycle = 0;
    longint max_cycles = 5_000_000;
    bit     trace = 0, quiet = 0;

    initial begin
        if ($value$plusargs("max_cycles=%d", max_cycles)) ;
        trace = $test$plusargs("trace");
        quiet = $test$plusargs("quiet");
        repeat (5) @(posedge clk);
        rst = 0;
    end

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle == max_cycles) begin
            $display("\n[tb] TIMEOUT after %0d cycles :(", cycle);
            $finish;
        end
    end

    // exit code write (let the pipeline drain a couple cycles so the trace is complete)
    int     exit_code = -1;
    int     drain = 0;
    always @(posedge clk) begin
        if (!rst && exit_code < 0 && dut.u_core.dmem_we && dut.u_core.dmem_addr == 32'h1000_F000)
            exit_code = dut.u_core.dmem_wdata;
        if (exit_code >= 0) begin
            drain++;
            if (drain == 3) begin
                $display("\n[tb] exit code %0d after %0d cycles, %0d instrs retired",
                         exit_code, cycle, dut.u_core.u_csr.minstret);
                if (exit_code == 0) $display("[tb] PASS :3");
                else                $display("[tb] FAIL :(");
                $finish;
            end
        end
    end

    // retire trace: "pc instr rd=val" or "pc instr" for no write
    always @(posedge clk) begin
        if (trace && !rst && dut.u_core.trace_valid) begin
            if (dut.u_core.trace_we)
                $display("T %08h %08h x%0d=%08h", dut.u_core.trace_pc, dut.u_core.trace_instr,
                         dut.u_core.trace_rd, dut.u_core.trace_wdata);
            else
                $display("T %08h %08h", dut.u_core.trace_pc, dut.u_core.trace_instr);
        end
        if (trace && !rst && dut.u_core.dmem_we)
            $display("S %08h %08h %1h", dut.u_core.dmem_addr, dut.u_core.dmem_wdata, dut.u_core.dmem_wstrb);
    end

    // ---------------- UART decoder ----------------
    initial begin : uart_mon
        logic [7:0] b;
        forever begin
            @(negedge uart_tx);
            repeat (BIT_T / 2) @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                repeat (BIT_T) @(posedge clk);
                b[i] = uart_tx;
            end
            repeat (BIT_T) @(posedge clk);
            if (!quiet && b != 8'h0D) $write("%c", b);
            $fflush();
        end
    end

    // ---------------- HD44780 model ----------------
    // just enough to follow 4-bit writes: DDRAM, cursor address, clear
    logic [7:0] ddram [0:127];
    logic [6:0] ac = 0;
    logic       nib_hi = 1;
    logic [3:0] hi;
    logic       four_bit = 0;
    int         init_nibs = 0;
    logic       dirty = 0;

    initial for (int i = 0; i < 128; i++) ddram[i] = " ";

    logic cg_mode = 0;          // writing custom chars (CGRAM) instead of the screen

    task automatic lcd_exec(input logic rs, input logic [7:0] v);
        if (rs && cg_mode) begin
            // custom char bitmap row, not shown on screen
        end else if (rs) begin
            ddram[ac] = v;
            ac = ac + 1;
            dirty = 1;
        end else if (v == 8'h01) begin
            for (int i = 0; i < 128; i++) ddram[i] = " ";
            ac = 0;
            cg_mode = 0;
            dirty = 1;
        end else if (v == 8'h02) begin
            ac = 0;
        end else if (v[7]) begin
            ac = v[6:0];
            cg_mode = 0;
        end else if (v[6]) begin
            cg_mode = 1;
        end
    endtask

    always @(negedge lcd_e) begin
        if (rst) begin
            // ignore the X->0 edge at time zero
        end else if (!four_bit) begin
            // the first 4 nibbles are the 8-bit-mode wake-up dance
            init_nibs++;
            if (init_nibs == 4) four_bit = 1;
        end else if (nib_hi) begin
            hi = lcd_d;
            nib_hi = 0;
        end else begin
            lcd_exec(lcd_rs, {hi, lcd_d});
            nib_hi = 1;
        end
    end

    // custom CGRAM chars 0-7 and the solid block (0xFF) are not printable,
    // so show them as ASCII stand-ins: 0-3 -> D d # *, 0xFF -> =
    function automatic logic [7:0] lcd_glyph(input logic [7:0] c);
        case (c)
            8'd0:    lcd_glyph = "D";
            8'd1:    lcd_glyph = "d";
            8'd2:    lcd_glyph = "#";
            8'd3:    lcd_glyph = "*";
            8'hFF:   lcd_glyph = "=";
            default: lcd_glyph = (c < 8) ? "?" : c;
        endcase
    endfunction

    // print the screen when it changes (and things have settled for a bit)
    int settle = 0;
    always @(posedge clk) begin
        if (dirty) begin
            settle++;
            if (settle > 20000) begin
                $write("\n+----------------+\n|");
                for (int i = 0; i < 16; i++) $write("%c", lcd_glyph(ddram[i]));
                $write("|\n|");
                for (int i = 0; i < 16; i++) $write("%c", lcd_glyph(ddram[8'h40 + i]));
                $write("|\n+----------------+\n");
                dirty = 0;
                settle = 0;
            end
        end
    end

    // ---------------- HC-SR04 model ----------------
    int sonar_cm = 0;
    initial if ($value$plusargs("sonar_cm=%d", sonar_cm)) ;
    always @(negedge trig) begin
        if (sonar_cm > 0) begin
            repeat (CLK_HZ / 1_000_000 * 200) @(posedge clk);     // sensor thinks for ~200 µs
            echo = 1;
            repeat (CLK_HZ / 1_000_000 * 58 * sonar_cm) @(posedge clk);
            echo = 0;
        end
    end

    // ---------------- button press ----------------
    longint btn_at = -1;
    initial if ($value$plusargs("btn_at=%d", btn_at)) ;
    always @(posedge clk) begin
        if (cycle == btn_at)                              buttons[0] <= 1'b1;
        if (cycle == btn_at + CLK_HZ / 100)               buttons[0] <= 1'b0;
    end

    // ---------------- UART bootloader driver ----------------
    task automatic uart_send(input logic [7:0] b);
        uart_rx = 1'b0;
        repeat (BIT_T) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            uart_rx = b[i];
            repeat (BIT_T) @(posedge clk);
        end
        uart_rx = 1'b1;
        repeat (BIT_T) @(posedge clk);
    endtask

    initial begin : loader
        string      path;
        int         fd, c, n;
        logic [7:0] data [0:16383];
        logic [7:0] sum;
        if ($value$plusargs("load=%s", path)) begin
            fd = $fopen(path, "rb");
            if (fd == 0) begin
                $display("[tb] can't open %s", path);
                $finish;
            end
            n = 0;
            c = $fgetc(fd);
            while (c != -1) begin
                data[n] = c[7:0];
                n++;
                c = $fgetc(fd);
            end
            $fclose(fd);
            repeat (2000) @(posedge clk);
            $display("[tb] flashing %0d bytes over UART...", n);
            uart_send("P"); uart_send("U"); uart_send("R"); uart_send("R");
            uart_send(n[7:0]); uart_send(n[15:8]); uart_send(n[23:16]); uart_send(n[31:24]);
            sum = 0;
            for (int i = 0; i < n; i++) begin
                uart_send(data[i]);
                sum = sum + data[i];
            end
            uart_send(sum);
        end
    end

    // ---------------- waves ----------------
    initial if ($test$plusargs("vcd")) begin
        $dumpfile("build/wave.vcd");
        $dumpvars(0, tb_soc);
    end
endmodule
