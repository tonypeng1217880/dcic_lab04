// top_rx.v
// sync_cp_fixed_core + fft_r2dit_64 + 16QAM demapper
// 功能：做同步 → 抽取 64 點 → FFT → 16QAM 解調
`timescale 1ns/1ps

module top_rx #(
    parameter N   = 64,
    parameter G   = 16,
    parameter LEN = 800
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,          // trigger 整個 RX flow（給 sync 用）

    input  wire               sample_valid,   // 800 筆 input samples
    input  wire signed [15:0] sample_real,
    input  wire signed [15:0] sample_imag,

    // FFT 輸出
    output wire               fft_out_vld,
    output wire signed [15:0] fft_out_real,
    output wire signed [15:0] fft_out_imag,

    // 16-QAM 解調輸出
    output wire [3:0]         out_16qam,
    output wire               out_16qam_vld,

    output wire               done_all        // 整個流程完成（FFT done）
);

    // ========== 1. 自己存 800 筆 sample 給 FFT 用 ==========

    localparam ADDR_W = 10;

    reg signed [15:0] mem_real_top [0:LEN-1];
    reg signed [15:0] mem_imag_top [0:LEN-1];
    reg [ADDR_W-1:0]  wr_addr_top;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr_top <= 0;
        end else begin
            if (start)
                wr_addr_top <= 0;

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
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .sample_valid(sample_valid),
        .sample_real (sample_real),
        .sample_imag (sample_imag),
        .gamma_valid (sync_gamma_valid),
        .d_out       (sync_d_out),
        .gamma_out   (sync_gamma_out),
        .done        (sync_done)
    );

    // 找 peak (0~79)
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
            if (sync_gamma_valid && (sync_d_out == 79))
                found_peak <= 1;
        end
    end

    // ========== 3. FFT ==========
    reg               fft_start;
    reg  signed [15:0] fft_in_real;
    reg  signed [15:0] fft_in_imag;
    wire              fft_done;

    fft_r2dit_64 u_fft (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (fft_start),
        .in_real     (fft_in_real),
        .in_imag     (fft_in_imag),
        .fft_out_vld (fft_out_vld),
        .out_real    (fft_out_real),
        .out_imag    (fft_out_imag),
        .done        (fft_done)
    );

    assign done_all = fft_done;

    // ====== 控制 ======

    localparam ST_IDLE      = 2'd0;
    localparam ST_WAIT_SYNC = 2'd1;
    localparam ST_START_FFT = 2'd2;
    localparam ST_FEED_FFT  = 2'd3;

    reg [1:0]        state;
    reg [ADDR_W-1:0] rd_addr;
    reg [6:0]        fft_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            fft_start   <= 0;
            fft_in_real <= 0;
            fft_in_imag <= 0;
            rd_addr     <= 0;
            fft_cnt     <= 0;
        end else begin
            case (state)
            ST_IDLE: begin
                fft_start <= 0;
                fft_cnt   <= 0;
                if (start)
                    state <= ST_WAIT_SYNC;
            end

            ST_WAIT_SYNC: begin
                if (sync_done && found_peak) begin
                    rd_addr <= d_peak + G;
                    fft_cnt <= 0;
                    state   <= ST_START_FFT;
                end
            end

            ST_START_FFT: begin
                fft_start <= 1;
                state     <= ST_FEED_FFT;
            end

            ST_FEED_FFT: begin
                fft_start <= 0;

                fft_in_real <= mem_real_top[rd_addr];
                fft_in_imag <= mem_imag_top[rd_addr];

                rd_addr <= rd_addr + 1'b1;
                fft_cnt <= fft_cnt + 1'b1;

                if (fft_cnt == 63)
                    state <= ST_IDLE;
            end

            default:
                state <= ST_IDLE;
            endcase
        end
    end

    // ========== 4. 16-QAM DEMAPPER ==========

    wire [3:0] qam16_bits;
    wire       qam16_bits_vld;

    qam16_demap #(
        .WORD_LENGTH(16),
        .THRESHOLD  (16'sd8192)   // 先用 8192，可依 FFT 實際幅度調整
    ) u_qam16_demap (
        .clk          (clk),
        .rst_n        (rst_n),
        .fft_out_vld  (fft_out_vld),
        .fft_out_real (fft_out_real),
        .fft_out_imag (fft_out_imag),
        .out_16qam    (qam16_bits),
        .out_vld      (qam16_bits_vld)
    );

    assign out_16qam     = qam16_bits;
    assign out_16qam_vld = qam16_bits_vld;

endmodule
