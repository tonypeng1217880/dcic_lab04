// ================================================
// CP-based Time Synchronization (fixed-point)
// - 精簡 Phi/P bit-width（PHI_W = 40）
// - 使用 multi-cycle divider（合成用 DW_div_seq）
// - RTL simulation 用行為版除法器，方便比對 C++
// - Gamma 計算公式：gamma = ( (|Phi|^2 << SCALE) / (P^2 + 1) )
// ================================================
`timescale 1ns/1ps

module sync_cp_fixed_core #(
    parameter N          = 64,
    parameter G          = 16,
    parameter M_SYM      = 3,
    parameter LEN        = 800,
    parameter SHIFT_PHI  = 8,
    parameter SHIFT_P    = 8,
    parameter SCALE      = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,

    input  wire                  sample_valid,
    input  wire signed [15:0]    sample_real,
    input  wire signed [15:0]    sample_imag,

    output reg                   gamma_valid,
    output reg [9:0]             d_out,
    output reg [63:0]            gamma_out,
    output reg                   done
);

    // -----------------------------------------
    // Parameters
    // -----------------------------------------
    localparam SPAN   = N + G;                   // 80
    localparam MAX_D  = LEN - (SPAN*M_SYM);      // 560
    localparam D_W    = 10;

    // Phi_r / Phi_i / P_acc bit width
    localparam PHI_W  = 40;

    // -----------------------------------------
    // Memory for samples
    // -----------------------------------------
    reg signed [15:0] mem_real [0:LEN-1];
    reg signed [15:0] mem_imag [0:LEN-1];

    reg [D_W-1:0] wr_addr;

    // -----------------------------------------
    // FSM states
    // -----------------------------------------
    localparam [2:0]
        S_IDLE      = 3'd0,
        S_LOAD      = 3'd1,
        S_PREP_D    = 3'd2,
        S_ACCUM     = 3'd3,
        S_DIV_START = 3'd4,
        S_DIV_WAIT  = 3'd5,
        S_SCALE     = 3'd6,
        S_DONE      = 3'd7;

    reg [2:0] state;

    reg [D_W-1:0] d;    // 0..MAX_D-1
    reg [1:0]     m;    // 0..M_SYM-1
    reg [4:0]     k;    // 0..G-1

    // -----------------------------------------
    // Accumulators (40-bit)
    // -----------------------------------------
    reg  signed [PHI_W-1:0] Phi_r;
    reg  signed [PHI_W-1:0] Phi_i;
    reg  signed [PHI_W-1:0] P_acc;

    // -----------------------------------------
    // Address generation
    // -----------------------------------------
    wire [D_W-1:0] addr_cp = d + m*SPAN + k;
    wire [D_W-1:0] addr_dt = d + m*SPAN + N + k;

    wire signed [15:0] ar = mem_real[addr_cp];
    wire signed [15:0] ai = mem_imag[addr_cp];
    wire signed [15:0] br = mem_real[addr_dt];
    wire signed [15:0] bi = mem_imag[addr_dt];

    // -----------------------------------------
    // Scaling and |Phi|^2, P^2
    // -----------------------------------------
    wire signed [PHI_W-1:0] pr_w = Phi_r >>> SHIFT_PHI;
    wire signed [PHI_W-1:0] pi_w = Phi_i >>> SHIFT_PHI;
    wire signed [PHI_W-1:0] Ps_w = P_acc >>> SHIFT_P;

    // 40 x 40 -> 80 bits
    wire [79:0] pr_sq = pr_w * pr_w;
    wire [79:0] pi_sq = pi_w * pi_w;
    wire [79:0] Ps_sq = Ps_w * Ps_w;

    // |Phi|^2, P^2 + 1
    wire [80:0] num_full = pr_sq + pi_sq;
    wire [80:0] den_full = Ps_sq + 81'd1;  // 保證不為 0

    // 截成 64 bits，供 divider 使用
    wire [63:0] num_w = num_full[63:0];
    wire [63:0] den_w = den_full[63:0];

    // -----------------------------------------
    // Multi-cycle divider I/O
    // div_a = (num_w << SCALE), div_b = den_w
    // -----------------------------------------
    reg  [63:0] div_a;
    reg  [63:0] div_b;
    reg         div_start;
    wire        div_done;
    wire [63:0] div_q;

    //--------------------------------------------------------
    // Divider module (Simulation vs Synthesis)
    //--------------------------------------------------------
`ifdef SYNTHESIS
    // ===================================================
    // Synthesis version — DesignWare DW_div_seq
    // ===================================================
    DW_div_seq #(
        .a_width(64),
        .b_width(64),
        .tc_mode(0),     // 0 = unsigned
        .rst_mode(0),    // active-low reset
        .num_cyc(64)     // 64 cycles to complete
    ) U_DIV (
        .clk     (clk),
        .rst_n   (rst_n),
        .hold    (1'b0),
        .start   (div_start),
        .a       (div_a),
        .b       (div_b),
        .complete(div_done),
        .quotient(div_q),
        .remainder()
    );
`else
    // ===================================================
    // Simulation version — 行為模型
    // - 內部仍然使用 "/" 方便 RTL debug 和對 C++ 比對
    // - 用 div_cnt 模擬 64-cycle 延遲（只是形式上，方便跟 FSM 對齊）
    // ===================================================
    reg [6:0] div_cnt  = 7'd0;
    reg       div_busy = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_busy <= 1'b0;
            div_cnt  <= 7'd0;
        end else begin
            if (div_start && !div_busy) begin
                div_busy <= 1'b1;
                div_cnt  <= 7'd64;    // 模擬 64 個 clock
            end else if (div_busy) begin
                if (div_cnt != 0)
                    div_cnt <= div_cnt - 1'b1;
                else
                    div_busy <= 1'b0;
            end
        end
    end

    assign div_done = (div_busy == 1'b0);
    assign div_q    = (div_b != 0) ? (div_a / div_b) : 64'd0;
`endif

    // ============================================
    // Main FSM
    // ============================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            wr_addr     <= 0;
            d           <= 0;
            m           <= 0;
            k           <= 0;
            Phi_r       <= 0;
            Phi_i       <= 0;
            P_acc       <= 0;
            gamma_valid <= 1'b0;
            gamma_out   <= 64'd0;
            d_out       <= 10'd0;
            done        <= 1'b0;
            div_start   <= 1'b0;
        end
        else begin
            // default outputs 每拍先清掉
            gamma_valid <= 1'b0;
            done        <= 1'b0;
            div_start   <= 1'b0;

            case (state)

            // ------------------------------
            S_IDLE: begin
                if (start) begin
                    wr_addr <= 0;
                    state   <= S_LOAD;
                end
            end

            // ------------------------------
            // 讀入 LEN 筆樣本
            S_LOAD: begin
                if (sample_valid) begin
                    mem_real[wr_addr] <= sample_real;
                    mem_imag[wr_addr] <= sample_imag;
                    if (wr_addr == LEN-1) begin
                        d     <= 0;
                        state <= S_PREP_D;
                    end
                    else begin
                        wr_addr <= wr_addr + 1'b1;
                    end
                end
            end

            // ------------------------------
            // 初始化當前 d 的累加器
            S_PREP_D: begin
                Phi_r <= 0;
                Phi_i <= 0;
                P_acc <= 0;
                m     <= 0;
                k     <= 0;
                state <= S_ACCUM;
            end

            // ------------------------------
            // 累加 Phi_r, Phi_i, P_acc
            // 一拍處理一組 (m,k)
            S_ACCUM: begin
                // Phi += a * conj(b)
                Phi_r <= Phi_r + (ar*br + ai*bi);
                Phi_i <= Phi_i + (ai*br - ar*bi);
                // P_acc += |b|^2
                P_acc <= P_acc + (br*br + bi*bi);

                if (k == G-1) begin
                    if (m == M_SYM-1) begin
                        // 所有 (m,k) 完成 → 進入除法
                        state <= S_DIV_START;
                    end
                    else begin
                        m <= m + 1'b1;
                        k <= 0;
                    end
                end
                else begin
                    k <= k + 1'b1;
                end
            end

            // ------------------------------
            // 啟動 multi-cycle divider
            S_DIV_START: begin
                // 先做 (num_w << SCALE) 再除以 den_w
                div_a   <= (num_w << SCALE);
                div_b   <= (den_w == 0) ? 64'd1 : den_w;  // 理論上 den_w 不會是 0
                div_start <= 1'b1;      // 只打一拍的 start
                state     <= S_DIV_WAIT;
            end

            // ------------------------------
            // 等待除法器完成
            S_DIV_WAIT: begin
                if (div_done) begin
                    gamma_out <= div_q; // 除法結果即為 Gamma[d]
                    state     <= S_SCALE;
                end
            end

            // ------------------------------
            // 輸出 Gamma[d]，打一拍 valid
            S_SCALE: begin
                gamma_valid <= 1'b1;
                d_out       <= d;

                if (d == MAX_D-1) begin
                    state <= S_DONE;
                end
                else begin
                    d     <= d + 1'b1;
                    state <= S_PREP_D;
                end
            end

            // ------------------------------
            // 全部 d 完成
            S_DONE: begin
                done  <= 1'b1;
                state <= S_DONE;    // 停在 DONE，等外面 reset
            end

            endcase
        end
    end

endmodule
