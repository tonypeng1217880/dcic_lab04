// top_rx.v
// sync_cp_fixed_core + fft_r2dit_64 接起來
// 功能：用同步找到 d_peak，再從 d_peak+16 取 64 點給 FFT (介面跟 tb_fft_r2dit_64 一樣)
`timescale 1ns/1ps

module top_rx #(
    parameter N   = 64,
    parameter G   = 16,
    parameter LEN = 800
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,          // trigger 整個 RX flow（給 sync 用）

    input  wire             sample_valid,   // 800 筆 input samples
    input  wire signed [15:0] sample_real,
    input  wire signed [15:0] sample_imag,

    // 直接接出 FFT 的輸出
    output wire             fft_out_vld,
    output wire signed [15:0] fft_out_real,
    output wire signed [15:0] fft_out_imag,
    output wire             done_all        // 整個流程完成（FFT done）
);

    // ========== 1. 自己存 800 筆 sample 給 FFT 用 ==========
    localparam ADDR_W = 10; // 0..799

    reg signed [15:0] mem_real_top [0:LEN-1];
    reg signed [15:0] mem_imag_top [0:LEN-1];
    reg [ADDR_W-1:0]  wr_addr_top;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr_top <= 0;
        end else begin
            if (start) begin
                wr_addr_top <= 0;
            end
            if (sample_valid) begin
                mem_real_top[wr_addr_top] <= sample_real;
                mem_imag_top[wr_addr_top] <= sample_imag;
                if (wr_addr_top != LEN-1)
                    wr_addr_top <= wr_addr_top + 1'b1;
            end
        end
    end

    // ========== 2. 同步核心 ==========
    wire        sync_gamma_valid;
    wire [9:0]  sync_d_out;
    wire [63:0] sync_gamma_out;
    wire        sync_done;

    sync_cp_fixed_core #(
        .N(64),
        .G(16),
        .M_SYM(3),
        .LEN(800),
        .SHIFT_PHI(8),
        .SHIFT_P(8),
        .SCALE(16)
    ) u_sync (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),        // 跟整體 start 同步
        .sample_valid(sample_valid),
        .sample_real(sample_real),
        .sample_imag(sample_imag),
        .gamma_valid(sync_gamma_valid),
        .d_out      (sync_d_out),
        .gamma_out  (sync_gamma_out),
        .done       (sync_done)
    );

    // 抓第一組 peak (d = 0~79)
    reg [63:0] best_gamma;
    reg [9:0]  d_peak;
    reg        found_peak;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            best_gamma <= 0;
            d_peak     <= 0;
            found_peak <= 0;
        end else if (!found_peak) begin
            if (sync_gamma_valid && (sync_d_out < 80)) begin
                if (sync_gamma_out > best_gamma) begin
                    best_gamma <= sync_gamma_out;
                    d_peak     <= sync_d_out;
                end
            end
            if (sync_gamma_valid && (sync_d_out == 79)) begin
                found_peak <= 1;
            end
        end
    end

    // ========== 3. 接 FFT：介面照 tb_fft_r2dit_64 ==========
    // fft_r2dit_64(
    //   .clk, .rst_n,
    //   .start,       // 拉一個 cycle
    //   .in_real, .in_imag,   // 連續 64 筆
    //   .fft_out_vld, .out_real, .out_imag, .done
    // )

    reg               fft_start;
    reg  signed [15:0] fft_in_real;
    reg  signed [15:0] fft_in_imag;

    wire              fft_done;

    fft_r2dit_64 u_fft (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (fft_start),
        .in_real    (fft_in_real),
        .in_imag    (fft_in_imag),
        .fft_out_vld(fft_out_vld),
        .out_real   (fft_out_real),
        .out_imag   (fft_out_imag),
        .done       (fft_done)
    );

    assign done_all = fft_done;  // 整個流程完成就看 FFT done

    // ========== 4. 控制：等 sync 完 + peak 出來，再送 64 點進 FFT ==========
    localparam ST_IDLE      = 2'd0;
    localparam ST_WAIT_SYNC = 2'd1;
    localparam ST_START_FFT = 2'd2;
    localparam ST_FEED_FFT  = 2'd3;

    reg [1:0]         state;
    reg [ADDR_W-1:0]  rd_addr;
    reg [6:0]         fft_cnt;   // 0..63

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            fft_start   <= 1'b0;
            fft_in_real <= 16'sd0;
            fft_in_imag <= 16'sd0;
            rd_addr     <= {ADDR_W{1'b0}};
            fft_cnt     <= 7'd0;
        end else begin
            case (state)
            ST_IDLE: begin
                fft_start   <= 1'b0;
                fft_in_real <= 16'sd0;
                fft_in_imag <= 16'sd0;
                fft_cnt     <= 7'd0;
                if (start) begin
                    state <= ST_WAIT_SYNC;
                end
            end

            ST_WAIT_SYNC: begin
                fft_start <= 1'b0;
                if (sync_done && found_peak) begin
                    // 真正 OFDM symbol 開頭 = d_peak + G
                    rd_addr <= d_peak + G;
                    fft_cnt <= 7'd0;
                    state   <= ST_START_FFT;
                end
            end

            ST_START_FFT: begin
                // 模仿 tb_fft_r2dit_64：先拉 start 一個 cycle，
                // 下一個 state 才開始送 64 筆資料
                fft_start <= 1'b1;
                state     <= ST_FEED_FFT;
            end

            ST_FEED_FFT: begin
                fft_start   <= 1'b0;

                // 送 64 筆 input: mem_real_top[rd_addr + 0..63]
                fft_in_real <= mem_real_top[rd_addr];
                fft_in_imag <= mem_imag_top[rd_addr];

                rd_addr <= rd_addr + 1'b1;
                fft_cnt <= fft_cnt + 1'b1;

                if (fft_cnt == 7'd63) begin
                    // 已送完 64 點，之後就讓 FFT 自己跑到 done=1
                    state <= ST_IDLE;  // 或者你也可以加 ST_DONE 狀態
                end
            end

            default: begin
                state <= ST_IDLE;
            end
            endcase
        end
    end
    // --------------------
    // 5. 加入 QPSK DEMAPPER
    // --------------------
    wire [1:0] qpsk_bits;
    wire       qpsk_bits_vld;

    qpsk_demap #(
        .WORD_LENGTH(16)
    ) u_qpsk_demap (
        .clk          (clk),
        .rst_n        (rst_n),
        .fft_out_vld  (fft_out_vld),
        .fft_out_real (fft_out_real),
        .fft_out_imag (fft_out_imag),
        .out_qpsk     (qpsk_bits),
        .out_vld      (qpsk_bits_vld)
    );

endmodule
