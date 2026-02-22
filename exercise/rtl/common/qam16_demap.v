// 16-QAM Demapper
// Gray mapping
// I/Q levels: +3 → 00 , +1 → 01 , -1 → 11 , -3 → 10
// Output bits: {I_MSB, I_LSB, Q_MSB, Q_LSB}

module qam16_demap #(
    parameter WORD_LENGTH = 16,
    parameter THRESHOLD   = 8192   // 分界值，可調整
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // FFT input
    input  wire                         fft_out_vld,
    input  wire signed [WORD_LENGTH-1:0] fft_out_real,
    input  wire signed [WORD_LENGTH-1:0] fft_out_imag,

    // Output bits
    output reg  [3:0]                   out_16qam,   // {I_MSB,I_LSB,Q_MSB,Q_LSB}
    output reg                          out_vld
);

    // ----------- intermediate bits -----------
    reg I_MSB, I_LSB;
    reg Q_MSB, Q_LSB;

    // =============================
    //  combinational demap logic
    // =============================
    always @(*) begin
        // ===== Real part =====
        if (fft_out_real >= 0) begin
            I_MSB = 1'b0;  
            I_LSB = (fft_out_real > THRESHOLD) ? 1'b0 : 1'b1;  
        end else begin
            I_MSB = 1'b1;  
            I_LSB = (-(fft_out_real) > THRESHOLD) ? 1'b1 : 1'b0;  
        end

        // ===== Imag part =====
        if (fft_out_imag >= 0) begin
            Q_MSB = 1'b0;
            Q_LSB = (fft_out_imag > THRESHOLD) ? 1'b0 : 1'b1;
        end else begin
            Q_MSB = 1'b1;
            Q_LSB = (-(fft_out_imag) > THRESHOLD) ? 1'b1 : 1'b0;
        end
    end

    // =============================
    //  register outputs (1-cycle latency)
    // =============================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_16qam <= 4'b0000;
            out_vld   <= 1'b0;
        end else begin
            out_vld <= fft_out_vld;
            if (fft_out_vld)
                out_16qam <= {I_MSB, I_LSB, Q_MSB, Q_LSB};
        end
    end

endmodule
