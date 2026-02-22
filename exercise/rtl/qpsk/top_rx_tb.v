`timescale 1ns/1ps

module top_rx_tb;

    // ===== 參數 =====
    localparam integer LEN   = 800;
    localparam integer NFFT  = 64;

    // ===== DUT 介面 =====
    reg  clk;
    reg  rst_n;
    reg  start;
    reg  sample_valid;
    reg  signed [15:0] sample_real;
    reg  signed [15:0] sample_imag;

    wire        fft_valid;
    wire signed [15:0] fft_real;
    wire signed [15:0] fft_imag;
    wire        done_all;

    // ===== 輸入 buffer =====
    integer r_real [0:LEN-1];
    integer r_imag [0:LEN-1];

    // 這些全部搬到 module 這裡宣告
    integer i;
    integer f_real, f_imag;
    integer code;
    integer fft_real_f, fft_imag_f;
    integer fft_count;

    // 新增：demap 輸出檔
    integer bits_f;

    // ===== 產生 clock =====
    initial begin
        clk = 0;
        forever #10 clk = ~clk; // 50 MHz
    end

    // ===== 實例化 top_rx =====
    top_rx #(
        .N  (64),
        .G  (16),
        .LEN(800)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .sample_valid(sample_valid),
        .sample_real (sample_real),
        .sample_imag (sample_imag),
        .fft_out_vld (fft_valid),
        .fft_out_real(fft_real),
        .fft_out_imag(fft_imag),
        .done_all    (done_all)
    );

    // ===== 實例化 QPSK demapper（接在 FFT 後） =====
    wire [1:0] qpsk_bits;
    wire       qpsk_bits_vld;

    qpsk_demap #(
        .WORD_LENGTH(16)
    ) u_qpsk_demap (
        .clk          (clk),
        .rst_n        (rst_n),
        .fft_out_vld  (fft_valid),
        .fft_out_real (fft_real),
        .fft_out_imag (fft_imag),
        .out_qpsk     (qpsk_bits),
        .out_vld      (qpsk_bits_vld)
    );

    // ===== Testbench 主流程 =====
    initial begin
        // 初始化
        rst_n        = 1'b0;
        start        = 1'b0;
        sample_valid = 1'b0;
        sample_real  = 16'sd0;
        sample_imag  = 16'sd0;
        fft_count    = 0;

        // reset
        #20;
        rst_n = 1'b1;

        // 讀檔
        f_real = $fopen("rx_real_QPSK.txt", "r");
        f_imag = $fopen("rx_imag_QPSK.txt", "r");
        if (f_real == 0 || f_imag == 0) begin
            $display("[TB ERROR] cannot open rx_real_QPSK.txt or rx_imag_QPSK.txt");
            $finish;
        end

        for (i = 0; i < LEN; i = i + 1) begin
            code = $fscanf(f_real, "%d\n", r_real[i]);
            code = $fscanf(f_imag, "%d\n", r_imag[i]);
        end
        $fclose(f_real);
        $fclose(f_imag);
        $display("[TB] Loaded %0d samples.", LEN);

        // 開啟 FFT 輸出檔
        fft_real_f = $fopen("fft0_real_verilog.txt", "w");
        fft_imag_f = $fopen("fft0_imag_verilog.txt", "w");
        if (fft_real_f == 0 || fft_imag_f == 0) begin
            $display("[TB ERROR] cannot open FFT output txt.");
            $finish;
        end

        // 開啟 QPSK bits 輸出檔（要跟 C++ 比對）
        bits_f = $fopen("qpsk_bits_verilog.txt", "w");
        if (bits_f == 0) begin
            $display("[TB ERROR] cannot open qpsk_bits_verilog.txt");
            $finish;
        end

        // 發 start pulse
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // 把 800 筆 sample 丟給 top_rx
        for (i = 0; i < LEN; i = i + 1) begin
            @(posedge clk);
            sample_valid <= 1'b1;
            sample_real  <= r_real[i];
            sample_imag  <= r_imag[i];
        end

        // 再一拍收尾
        @(posedge clk);
        sample_valid <= 1'b0;
        sample_real  <= 16'sd0;
        sample_imag  <= 16'sd0;

        // 等待 FFT 輸出 64 個點
        while (fft_count < NFFT) begin
            @(posedge clk);
            if (fft_valid) begin
                $fdisplay(fft_real_f, "%0d", fft_real);
                $fdisplay(fft_imag_f, "%0d", fft_imag);
                fft_count = fft_count + 1;
            end
        end

        $fclose(fft_real_f);
        $fclose(fft_imag_f);
        $fclose(bits_f);

        $display("[TB] Captured %0d FFT outputs to fft0_real_verilog.txt / fft0_imag_verilog.txt", fft_count);
        $display("[TB] Dumped QPSK bits to qpsk_bits_verilog.txt");

        // 多等幾拍再結束
        repeat (10) @(posedge clk);
        $finish;
    end

    // 在 qpsk_bits_vld = 1 那拍，把 bits 寫進 txt
    always @(posedge clk) begin
        if (qpsk_bits_vld) begin
            // 格式：bit1 bit2  -> 跟 C++ "qpsk_bits_cpp_sync.txt" 一樣
            $fdisplay(bits_f, "%0d %0d", qpsk_bits[1], qpsk_bits[0]);
        end
    end

    // (選擇性) 波形
    initial begin
        $dumpfile("top_rx_tb.vcd");
        $dumpvars(0, top_rx_tb);
    end

endmodule
