// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// SVA properties for fir_core. Stripped on synth via `ifndef SYNTHESIS.
//
// Properties:
//   p_tvalid_stable   : when TVALID is high and TREADY is low, TVALID
//                       must stay high (AXIS rule).
//   p_tdata_stable    : when TVALID is high and TREADY is low, TDATA
//                       must not change (AXIS rule).
//   p_tready_no_x     : TREADY is never X.
//   p_output_bounded  : when TUSER (saturation) is high, TDATA must be
//                       at one of the rails.
//   p_no_phantom_out  : an output beat must be preceded by at least one
//                       accepted input beat (no spurious outputs).
//   p_one_in_one_out  : count of accepted inputs equals count of
//                       accepted outputs plus pending in-flight (<= 2).

module fir_assertions #(
  parameter int DATA_WIDTH = 16
) (
  input logic                            clk_i,
  input logic                            rst_ni,
  input logic                            s_tvalid_i,
  input logic                            s_tready_i,
  input logic signed [DATA_WIDTH-1:0]    s_tdata_i,
  input logic                            m_tvalid_i,
  input logic                            m_tready_i,
  input logic signed [DATA_WIDTH-1:0]    m_tdata_i,
  input logic                            m_tuser_i
);
`ifndef SYNTHESIS

  localparam logic signed [DATA_WIDTH-1:0] MAX_POS =
      {1'b0, {(DATA_WIDTH-1){1'b1}}};
  localparam logic signed [DATA_WIDTH-1:0] MIN_NEG =
      {1'b1, {(DATA_WIDTH-1){1'b0}}};

  // 1. TVALID stable: once asserted with TREADY low, TVALID stays.
  property p_tvalid_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (m_tvalid_i && !m_tready_i) |=> m_tvalid_i;
  endproperty
  a_tvalid_stable: assert property (p_tvalid_stable)
    else $error("fir: m_tvalid dropped before tready handshake");

  // 2. TDATA stable: once a beat is offered, data may not change until
  //    accepted (AXIS specification).
  property p_tdata_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (m_tvalid_i && !m_tready_i) |=> $stable(m_tdata_i);
  endproperty
  a_tdata_stable: assert property (p_tdata_stable)
    else $error("fir: m_tdata changed during stalled beat");

  // 3. TREADY is never X.
  property p_tready_no_x;
    @(posedge clk_i) disable iff (!rst_ni)
      !$isunknown(s_tready_i);
  endproperty
  a_tready_no_x: assert property (p_tready_no_x)
    else $error("fir: s_tready is X");

  // 4. Saturation flag implies the output is at one of the rails.
  property p_output_bounded;
    @(posedge clk_i) disable iff (!rst_ni)
      (m_tvalid_i && m_tuser_i) |->
      ((m_tdata_i == MAX_POS) || (m_tdata_i == MIN_NEG));
  endproperty
  a_output_bounded: assert property (p_output_bounded)
    else $error("fir: tuser asserted but tdata=%0d not at rail", m_tdata_i);

  // 5. No phantom outputs: count beats. Output beats must never exceed
  //    accepted inputs (latency + buffering bounded by a small constant).
  int in_count_q;
  int out_count_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      in_count_q  <= 0;
      out_count_q <= 0;
    end else begin
      if (s_tvalid_i && s_tready_i)  in_count_q  <= in_count_q  + 1;
      if (m_tvalid_i && m_tready_i)  out_count_q <= out_count_q + 1;
    end
  end

  property p_no_phantom_out;
    @(posedge clk_i) disable iff (!rst_ni)
      (out_count_q <= in_count_q);
  endproperty
  a_no_phantom_out: assert property (p_no_phantom_out)
    else $error("fir: out_count(%0d) > in_count(%0d)",
                out_count_q, in_count_q);

  // 6. Bounded in-flight: at most 2 accepted inputs may be unmatched
  //    by an accepted output (one in the pipe, one in the output reg).
  property p_inflight_bounded;
    @(posedge clk_i) disable iff (!rst_ni)
      ((in_count_q - out_count_q) <= 2);
  endproperty
  a_inflight_bounded: assert property (p_inflight_bounded)
    else $error("fir: too many in-flight (%0d)",
                in_count_q - out_count_q);

`endif
endmodule
