// ============================================
// 64-point Radix-2 DIT FFT (Q8.8 twiddle)
// - Data  : signed 16-bit
// - Twiddle: signed 16-bit Q8.8
// - Multi-cycle implementation (synthesizable)
// ============================================
`timescale 1ns/1ps

module fft_r2dit_64 (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,      // 高脈波開始一筆 64-pt FFT

    input  wire signed [15:0]   in_real,
    input  wire signed [15:0]   in_imag,

    output reg                  fft_out_vld,
    output reg  signed [15:0]   out_real,
    output reg  signed [15:0]   out_imag,
    output reg                  done        // 一筆 64-pt FFT 完成時拉高一個 clk
);

    // -----------------------------
    // 參數 / 常數
    // -----------------------------
    parameter N    = 64;
    parameter LOGN = 6;

    // 狀態機
    parameter S_IDLE  = 2'd0;
    parameter S_LOAD  = 2'd1;
    parameter S_FFT   = 2'd2;
    parameter S_OUT   = 2'd3;

    reg [1:0] state;

    // 內部記憶體 (64-point complex buffer)
    reg signed [15:0] mem_real [0:N-1];
    reg signed [15:0] mem_imag [0:N-1];

    // 讀寫 index
    reg [5:0] load_idx;
    reg [5:0] out_idx;

    // FFT 迴圈計數器
    reg [2:0] stage;      // 0..5
    reg [5:0] j;          // 0..(half-1)
    reg [5:0] group;      // 0..(groups-1)

    reg [5:0] len;        // 2,4,8,...,64
    reg [5:0] half;       // 1,2,4,...,32

    wire [5:0] step;      // N/len = 1 << (LOGN-1-stage)
    wire [5:0] groups;    // same as step
    wire [5:0] last_group;
    assign step       = 6'd1 << (LOGN-1-stage);
    assign groups     = step;
    assign last_group = groups - 1'b1;

    // butterfly index
    reg [5:0] a_idx, b_idx;

    // 暫存資料
    reg signed [15:0] xr0, xi0, xr1, xi1;
    reg signed [15:0] t_re, t_im;
    reg signed [15:0] w_re, w_im;

    reg [5:0] tw_idx;

    // 複數乘法暫存 (32-bit)
    reg signed [31:0] mult_re;
    reg signed [31:0] mult_im;

    // ============================
    // Twiddle ROM: W_64^k (Q8.8)
    // k 0..63, 但只存 0..31，>31 用 +32 變號
    // ============================
    task get_twiddle;
        input  [5:0] k_in;
        output signed [15:0] w_r;
        output signed [15:0] w_i;
        reg [5:0] idx;
        reg       neg;
    begin
        if (k_in[5] == 1'b1) begin
            // k >= 32 -> k = k-32, 之後整體變號
            idx = k_in - 6'd32;
            neg = 1'b1;
        end else begin
            idx = k_in;
            neg = 1'b0;
        end

        // Q8.8 twiddles, cos/sin * 256
        case (idx)
            6'd0 : begin w_r = 16'sd256;  w_i = 16'sd0;    end
            6'd1 : begin w_r = 16'sd255;  w_i = -16'sd25;  end
            6'd2 : begin w_r = 16'sd251;  w_i = -16'sd50;  end
            6'd3 : begin w_r = 16'sd245;  w_i = -16'sd74;  end
            6'd4 : begin w_r = 16'sd237;  w_i = -16'sd98;  end
            6'd5 : begin w_r = 16'sd226;  w_i = -16'sd121; end
            6'd6 : begin w_r = 16'sd213;  w_i = -16'sd142; end
            6'd7 : begin w_r = 16'sd198;  w_i = -16'sd162; end
            6'd8 : begin w_r = 16'sd181;  w_i = -16'sd181; end
            6'd9 : begin w_r = 16'sd162;  w_i = -16'sd198; end
            6'd10: begin w_r = 16'sd142;  w_i = -16'sd213; end
            6'd11: begin w_r = 16'sd121;  w_i = -16'sd226; end
            6'd12: begin w_r = 16'sd98;   w_i = -16'sd237; end
            6'd13: begin w_r = 16'sd74;   w_i = -16'sd245; end
            6'd14: begin w_r = 16'sd50;   w_i = -16'sd251; end
            6'd15: begin w_r = 16'sd25;   w_i = -16'sd255; end
            6'd16: begin w_r = 16'sd0;    w_i = -16'sd256; end
            6'd17: begin w_r = -16'sd25;  w_i = -16'sd255; end
            6'd18: begin w_r = -16'sd50;  w_i = -16'sd251; end
            6'd19: begin w_r = -16'sd74;  w_i = -16'sd245; end
            6'd20: begin w_r = -16'sd98;  w_i = -16'sd237; end
            6'd21: begin w_r = -16'sd121; w_i = -16'sd226; end
            6'd22: begin w_r = -16'sd142; w_i = -16'sd213; end
            6'd23: begin w_r = -16'sd162; w_i = -16'sd198; end
            6'd24: begin w_r = -16'sd181; w_i = -16'sd181; end
            6'd25: begin w_r = -16'sd198; w_i = -16'sd162; end
            6'd26: begin w_r = -16'sd213; w_i = -16'sd142; end
            6'd27: begin w_r = -16'sd226; w_i = -16'sd121; end
            6'd28: begin w_r = -16'sd237; w_i = -16'sd98;  end
            6'd29: begin w_r = -16'sd245; w_i = -16'sd74;  end
            6'd30: begin w_r = -16'sd251; w_i = -16'sd50;  end
            6'd31: begin w_r = -16'sd255; w_i = -16'sd25;  end
            default: begin w_r = 16'sd256; w_i = 16'sd0;   end
        endcase

        if (neg) begin
            w_r = -w_r;
            w_i = -w_i;
        end
    end
    endtask

    // ============================
    // 主狀態機
    // ============================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            load_idx    <= 6'd0;
            out_idx     <= 6'd0;
            stage       <= 3'd0;
            j           <= 6'd0;
            group       <= 6'd0;
            len         <= 6'd2;
            half        <= 6'd1;
            fft_out_vld <= 1'b0;
            out_real    <= 16'sd0;
            out_imag    <= 16'sd0;
            done        <= 1'b0;
        end else begin
            done        <= 1'b0;   // default
            fft_out_vld <= 1'b0;   // default

            case (state)
                // --------------------
                // IDLE: 等 start
                // --------------------
                S_IDLE: begin
                    if (start) begin
                        state    <= S_LOAD;
                        load_idx <= 6'd0;
                    end
                end

                // --------------------
                // LOAD: 連續 64 clk 讀入
                // --------------------
                S_LOAD: begin
                    mem_real[load_idx] <= in_real;
                    mem_imag[load_idx] <= in_imag;
                    if (load_idx == (N-1)) begin
                        // 讀完 64 筆，準備跑 FFT
                        state <= S_FFT;
                        stage <= 3'd0;
                        len   <= 6'd2;
                        half  <= 6'd1;
                        j     <= 6'd0;
                        group <= 6'd0;
                    end else begin
                        load_idx <= load_idx + 6'd1;
                    end
                end

                // --------------------
                // F F T 計算，每 clk 做一個 butterfly
                // --------------------
                S_FFT: begin
                    // 計算 index
                    a_idx = (group * len) + j;
                    b_idx = a_idx + half;

                    // 讀出資料
                    xr0 = mem_real[a_idx];
                    xi0 = mem_imag[a_idx];
                    xr1 = mem_real[b_idx];
                    xi1 = mem_imag[b_idx];

                    // 取得 twiddle
                    tw_idx = j * step;     // step = N/len
                    get_twiddle(tw_idx, w_re, w_im);

                    // 複數乘法 (Q8.8)
                    mult_re = xr1 * w_re - xi1 * w_im;
                    mult_im = xr1 * w_im + xi1 * w_re;
                    t_re    = mult_re >>> 8;
                    t_im    = mult_im >>> 8;

                    // butterfly: 寫回 mem
                    mem_real[a_idx] <= xr0 + t_re;
                    mem_imag[a_idx] <= xi0 + t_im;
                    mem_real[b_idx] <= xr0 - t_re;
                    mem_imag[b_idx] <= xi0 - t_im;

                    // 更新 j / group / stage
                    if (j == (half - 1)) begin
                        j <= 6'd0;
                        if (group == last_group) begin
                            group <= 6'd0;
                            // 這個 stage 做完
                            if (stage == (LOGN-1)) begin
                                // 所有 stage 完成 -> 進 OUTPUT
                                state   <= S_OUT;
                                out_idx <= 6'd0;
                            end else begin
                                stage <= stage + 3'd1;
                                len   <= len << 1;   // *2
                                half  <= half << 1;  // *2
                            end
                        end else begin
                            group <= group + 6'd1;
                        end
                    end else begin
                        j <= j + 6'd1;
                    end
                end

                // --------------------
                // OUTPUT: 依序吐出 64 筆
                // --------------------
                S_OUT: begin
                    fft_out_vld <= 1'b1;
                    out_real    <= mem_real[out_idx];
                    out_imag    <= mem_imag[out_idx];

                    if (out_idx == (N-1)) begin
                        done    <= 1'b1;
                        state   <= S_IDLE;
                    end
                    out_idx <= out_idx + 6'd1;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
