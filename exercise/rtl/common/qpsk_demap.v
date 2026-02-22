// qpsk_demap.v
// Fully compatible with C++ demapper

module qpsk_demap #(
    parameter WORD_LENGTH = 16
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // FFT 輸入
    input  wire                         fft_out_vld,
    input  wire signed [WORD_LENGTH-1:0] fft_out_real,
    input  wire signed [WORD_LENGTH-1:0] fft_out_imag,

    // QPSK 輸出：bit1 = MSB, bit2 = LSB
    output reg  [1:0]                    out_qpsk,
    output reg                           out_vld
);

    reg bit1, bit2;

    // 和 C++ 完全一致：只看 sign
    always @(*) begin
        bit1 = (fft_out_real >= 0) ? 1'b0 : 1'b1;
        bit2 = (fft_out_imag >= 0) ? 1'b0 : 1'b1;
    end

    // 註冊 output 使得與 fft_out_vld 同步
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_qpsk <= 2'b00;
            out_vld  <= 1'b0;
        end else begin
            out_vld <= fft_out_vld;
            if (fft_out_vld)
                out_qpsk <= {bit1, bit2};  // bit1 = MSB
        end
    end

endmodule
