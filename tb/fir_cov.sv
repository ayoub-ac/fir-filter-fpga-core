// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage collector for fir_core. The C++ harness reads the
// sticky bins at end-of-test.
//
// Bins:
//   c_in16_handshake       : a beat was accepted on the 16-tap input.
//   c_in32_handshake       : a beat was accepted on the 32-tap input.
//   c_out16_handshake      : a beat was accepted on the 16-tap output.
//   c_out32_handshake      : a beat was accepted on the 32-tap output.
//   c_backpressure_in      : input was throttled (TVALID & !TREADY).
//   c_backpressure_out     : output was throttled (TVALID & !TREADY).
//   c_saturated_high       : a saturated output beat at MAX_POS.
//   c_saturated_low        : a saturated output beat at MIN_NEG.

module fir_cov (
  input logic                   clk_i,
  input logic                   rst_ni,
  input logic                   s16_valid_i,
  input logic                   s16_ready_i,
  input logic                   m16_valid_i,
  input logic                   m16_ready_i,
  input logic                   m16_tuser_i,
  input logic signed [15:0]     m16_tdata_i,
  input logic                   s32_valid_i,
  input logic                   s32_ready_i,
  input logic                   m32_valid_i,
  input logic                   m32_ready_i,
  input logic                   m32_tuser_i,
  input logic signed [15:0]     m32_tdata_i
);

  logic c_in16_handshake     /*verilator public*/;
  logic c_in32_handshake     /*verilator public*/;
  logic c_out16_handshake    /*verilator public*/;
  logic c_out32_handshake    /*verilator public*/;
  logic c_backpressure_in    /*verilator public*/;
  logic c_backpressure_out   /*verilator public*/;
  logic c_saturated_high     /*verilator public*/;
  logic c_saturated_low      /*verilator public*/;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      // Sticky: do not clear on reset (we want cumulative across the
      // entire regression). The initial block below sets them to 0.
    end else begin
      if (s16_valid_i && s16_ready_i)  c_in16_handshake   <= 1'b1;
      if (s32_valid_i && s32_ready_i)  c_in32_handshake   <= 1'b1;
      if (m16_valid_i && m16_ready_i)  c_out16_handshake  <= 1'b1;
      if (m32_valid_i && m32_ready_i)  c_out32_handshake  <= 1'b1;

      if ((s16_valid_i && !s16_ready_i) || (s32_valid_i && !s32_ready_i))
                                       c_backpressure_in  <= 1'b1;
      if ((m16_valid_i && !m16_ready_i) || (m32_valid_i && !m32_ready_i))
                                       c_backpressure_out <= 1'b1;

      // High rail: saturation flag and tdata > 0.
      if (m16_valid_i && m16_tuser_i && (m16_tdata_i > 0))
                                       c_saturated_high   <= 1'b1;
      if (m32_valid_i && m32_tuser_i && (m32_tdata_i > 0))
                                       c_saturated_high   <= 1'b1;
      // Low rail: saturation flag and tdata < 0.
      if (m16_valid_i && m16_tuser_i && (m16_tdata_i < 0))
                                       c_saturated_low    <= 1'b1;
      if (m32_valid_i && m32_tuser_i && (m32_tdata_i < 0))
                                       c_saturated_low    <= 1'b1;
    end
  end

  initial begin
    c_in16_handshake    = 1'b0;
    c_in32_handshake    = 1'b0;
    c_out16_handshake   = 1'b0;
    c_out32_handshake   = 1'b0;
    c_backpressure_in   = 1'b0;
    c_backpressure_out  = 1'b0;
    c_saturated_high    = 1'b0;
    c_saturated_low     = 1'b0;
  end

endmodule
