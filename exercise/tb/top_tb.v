`timescale 1ns/1ns
`define CYCLE_TIME 10

module top_tb;

    //========================
    // PARAMETERS
    //========================
    parameter word_length        = 16;
    parameter depth              = 80;
    parameter cp_length          = 16;

    parameter CYCLE              = `CYCLE_TIME;
    parameter PATTERN_COUNT      = 1;    // 一次要測幾組 pattern
    parameter POINTS_PER_PATTERN = 80;   // 每個 OFDM symbol 的取樣點數 (CP16 + data64)
    parameter OFDM_NUM           = 10;   // 每組 pattern 有幾個 OFDM symbol

    //========================
    // DUT I/O
    //========================
    reg  clk;
    reg  rst_n;
    reg  signed [word_length-1 : 0] r_real;
    reg  signed [word_length-1 : 0] r_imag;

    wire [1:0] out_qpsk;
    wire [3:0] out_16qam;
    wire       fft_out_vld;

    // 實部 / 虛部分開存（共 10*80 = 800 筆）
    reg signed [15:0] real_mem [0:(OFDM_NUM * POINTS_PER_PATTERN * PATTERN_COUNT) - 1];
    reg signed [15:0] imag_mem [0:(OFDM_NUM * POINTS_PER_PATTERN * PATTERN_COUNT) - 1];

    //========================
    // DUT
    //========================
    top #(
        .word_length(word_length),
        .depth      (depth),
        .cp_length  (cp_length)
    ) uut (
        .clk        (clk),
        .rst_n      (rst_n),
        .r_real     (r_real),
        .r_imag     (r_imag),
        .out_qpsk   (out_qpsk),
        .out_16qam  (out_16qam),
        .fft_out_vld(fft_out_vld)
    );

    //========================
    // 抓 internal 訊號來看
    //========================
    // 1) FFT output
    wire signed [word_length-1:0] fft_out_real_tb;
    wire signed [word_length-1:0] fft_out_imag_tb;
    assign fft_out_real_tb = uut.fft_out_real;
    assign fft_out_imag_tb = uut.fft_out_imag;

    // 2) sync output
    wire signed [word_length-1:0] sync_out_real_tb;
    wire signed [word_length-1:0] sync_out_imag_tb;
    assign sync_out_real_tb = uut.sync_out_real;
    assign sync_out_imag_tb = uut.sync_out_imag;
    // 2-1) sync output valid（for FFT input dump）
    wire sync_out_vld_tb;
    assign sync_out_vld_tb = uut.sync_out_vld;

    // 3) FFT bin index 計數器
    integer fft_idx;

    //========================
    // CLOCK
    //========================
    initial begin
        clk     = 1'b0;
        forever #(CYCLE/2) clk = ~clk;   // 10ns period
    end

    //========================
    // READ INPUT FILES
    //========================
    initial begin
        // QPSK：改檔名就能換成 16QAM
        $readmemh("rx_real_QPSK.txt", real_mem);
        $readmemh("rx_imag_QPSK.txt", imag_mem);
    end

    //========================
    // RESET TASK
    //========================
    task reset; begin
        rst_n    <= 1'b0;
        r_real   <= 0;
        r_imag   <= 0;
        fft_idx  <= 0;          // 同步把 FFT index 清掉
        repeat(3) @(posedge clk);   // 保持 reset 幾拍
        rst_n    <= 1'b1;
        repeat(1) @(posedge clk);   // 放開 reset 後再等一拍
    end endtask

    //========================
    // 產生輸入波形
    //========================
    task GenerateInputWave(input integer pattern_idx);
        integer n;
        integer k;
        integer base;
        begin
            for (k = 0; k < OFDM_NUM; k = k + 1) begin
                // 每個 OFDM symbol 的起始 index
                base = pattern_idx * OFDM_NUM * POINTS_PER_PATTERN
                     + k          * POINTS_PER_PATTERN;

                // 連續送 80 筆 (CP16 + data64)
                for (n = 0; n < POINTS_PER_PATTERN; n = n + 1) begin
                    r_real <= real_mem[base + n];
                    r_imag <= imag_mem[base + n];
                    @(posedge clk);
                end
            end

            // 資料送完，送 0 當 idle
            r_real <= 0;
            r_imag <= 0;
            @(posedge clk);
        end
    endtask

    //========================
    // MAIN
    //========================
    integer i;
    initial begin
        // 初始值
        rst_n    = 1'b0;
        r_real   = 0;
        r_imag   = 0;
        fft_idx  = 0;

        // 依序跑每個 pattern
        for (i = 0; i < PATTERN_COUNT; i = i + 1) begin
            reset();
            GenerateInputWave(i);
        end

        // 等一段時間讓 pipeline 把最後幾個 symbol 吐完
        repeat (2000) @(posedge clk);
        $finish;
    end

    //========================
    // MONITOR
    //========================
    always @(posedge clk) begin
        integer sym_idx;
        integer bin_idx;

        // (1) 看 FFT 輸出：加上 sym / k index 方便跟 C++ 對比
        if (fft_out_vld) begin
            sym_idx = fft_idx / 64;   // 第幾個 OFDM symbol
            bin_idx = fft_idx % 64;   // FFT bin index k

            $display("FFT | t=%0t | sym=%0d | k=%0d | I=%d | Q=%d | out_qpsk=%b | out_16qam=%b",
                     $time,
                     sym_idx,
                     bin_idx,
                     fft_out_real_tb,
                     fft_out_imag_tb,
                     out_qpsk,
                     out_16qam);

            fft_idx = fft_idx + 1;
        end

        // (2) 可以順便看一下一開始餵進 DUT 的 r_real/r_imag（前幾百 ns）
        if ($time < 2000) begin
            $display("IN  | t=%0t | r_real=%d | r_imag=%d",
                     $time,
                     r_real,
                     r_imag);
        end
    end
    //=============================================================
    // 【TB 專用】：Dump FFT 的輸入 (time-domain 前 64 點)
    //=============================================================
    integer fin_re, fin_im;
    integer fin_cnt;

    initial begin
        fin_re  = $fopen("fft_in_real_verilog.txt", "w");
        fin_im  = $fopen("fft_in_imag_verilog.txt", "w");
        fin_cnt = 0;
    end

    always @(posedge clk) begin
        if (sync_out_vld_tb && fin_cnt < 64) begin
            $fwrite(fin_re, "%0d\n", sync_out_real_tb);
            $fwrite(fin_im, "%0d\n", sync_out_imag_tb);
            fin_cnt = fin_cnt + 1;

            if (fin_cnt == 64) begin
                $display("[TB] FFT input dump done (64 samples).");
                $fclose(fin_re);
                $fclose(fin_im);
            end
        end
    end
    //========================
    // FFT OUTPUT → TXT DUMP
    //========================
    integer f_re, f_im;
    integer dump_cnt;

    initial begin
        f_re      = $fopen("fft0_real_verilog.txt", "w");
        f_im      = $fopen("fft0_imag_verilog.txt", "w");
        dump_cnt  = 0;
    end

    always @(posedge clk) begin
        // 只抓前 64 個 FFT 輸出（sym=0, k=0..63）
        if (fft_out_vld && dump_cnt < 64) begin
            // 注意：這裡用的是你上面抓的 internal：fft_out_real_tb / fft_out_imag_tb
            $fwrite(f_re, "%0d\n", fft_out_real_tb);
            $fwrite(f_im, "%0d\n", fft_out_imag_tb);

            dump_cnt = dump_cnt + 1;

            if (dump_cnt == 64) begin
                $display("[TB] FFT dump done (first symbol 64 bins).");
                $fclose(f_re);
                $fclose(f_im);
            end
        end
    end

    //========================
    // VCD DUMP
    //========================
    initial begin
        $dumpfile("top.vcd");
        $dumpvars(0, top_tb);
    end

endmodule
