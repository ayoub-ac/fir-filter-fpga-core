// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Top-level testbench wrapper for fir_core. Stimulus from sim_main.cpp.
//
// Two parallel instances are run side by side:
//   * u_dut16 : N_TAPS = 16 (low-pass)
//   * u_dut32 : N_TAPS = 32 (longer low-pass)
// They share clock and reset; each gets its own AXIS handshake and
// coefficient bank from the C++ harness.

module fir_tb #(
  parameter int DATA_WIDTH  = 16,
  parameter int COEFF_WIDTH = 16
) (
  input  logic                            clk_i,
  input  logic                            rst_ni,

  // Coefficient banks (flat packed: tap k = bits k*W +: W)
  input  logic [16*COEFF_WIDTH-1:0]       coeff16_i,
  input  logic [32*COEFF_WIDTH-1:0]       coeff32_i,

  // 16-tap AXIS
  input  logic signed [DATA_WIDTH-1:0]    s16_tdata_i,
  input  logic                            s16_tvalid_i,
  output logic                            s16_tready_o,
  output logic signed [DATA_WIDTH-1:0]    m16_tdata_o,
  output logic                            m16_tvalid_o,
  input  logic                            m16_tready_i,
  output logic                            m16_tuser_o,

  // 32-tap AXIS
  input  logic signed [DATA_WIDTH-1:0]    s32_tdata_i,
  input  logic                            s32_tvalid_i,
  output logic                            s32_tready_o,
  output logic signed [DATA_WIDTH-1:0]    m32_tdata_o,
  output logic                            m32_tvalid_o,
  input  logic                            m32_tready_i,
  output logic                            m32_tuser_o
);

  // ---------------- 16-tap ----------------
  fir_core #(
    .N_TAPS      (16),
    .DATA_WIDTH  (DATA_WIDTH),
    .COEFF_WIDTH (COEFF_WIDTH)
  ) u_dut16 (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .coeff_i         (coeff16_i),
    .s_axis_tdata_i  (s16_tdata_i),
    .s_axis_tvalid_i (s16_tvalid_i),
    .s_axis_tready_o (s16_tready_o),
    .m_axis_tdata_o  (m16_tdata_o),
    .m_axis_tvalid_o (m16_tvalid_o),
    .m_axis_tready_i (m16_tready_i),
    .m_axis_tuser_o  (m16_tuser_o)
  );

  fir_assertions #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_assert16 (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_tvalid_i (s16_tvalid_i),
    .s_tready_i (s16_tready_o),
    .s_tdata_i  (s16_tdata_i),
    .m_tvalid_i (m16_tvalid_o),
    .m_tready_i (m16_tready_i),
    .m_tdata_i  (m16_tdata_o),
    .m_tuser_i  (m16_tuser_o)
  );

  // ---------------- 32-tap ----------------
  fir_core #(
    .N_TAPS      (32),
    .DATA_WIDTH  (DATA_WIDTH),
    .COEFF_WIDTH (COEFF_WIDTH)
  ) u_dut32 (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .coeff_i         (coeff32_i),
    .s_axis_tdata_i  (s32_tdata_i),
    .s_axis_tvalid_i (s32_tvalid_i),
    .s_axis_tready_o (s32_tready_o),
    .m_axis_tdata_o  (m32_tdata_o),
    .m_axis_tvalid_o (m32_tvalid_o),
    .m_axis_tready_i (m32_tready_i),
    .m_axis_tuser_o  (m32_tuser_o)
  );

  fir_assertions #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_assert32 (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_tvalid_i (s32_tvalid_i),
    .s_tready_i (s32_tready_o),
    .s_tdata_i  (s32_tdata_i),
    .m_tvalid_i (m32_tvalid_o),
    .m_tready_i (m32_tready_i),
    .m_tdata_i  (m32_tdata_o),
    .m_tuser_i  (m32_tuser_o)
  );

  // ---------------- Coverage ----------------
  fir_cov u_cov (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .s16_valid_i (s16_tvalid_i),
    .s16_ready_i (s16_tready_o),
    .m16_valid_i (m16_tvalid_o),
    .m16_ready_i (m16_tready_i),
    .m16_tuser_i (m16_tuser_o),
    .m16_tdata_i (m16_tdata_o),
    .s32_valid_i (s32_tvalid_i),
    .s32_ready_i (s32_tready_o),
    .m32_valid_i (m32_tvalid_o),
    .m32_ready_i (m32_tready_i),
    .m32_tuser_i (m32_tuser_o),
    .m32_tdata_i (m32_tdata_o)
  );

endmodule
